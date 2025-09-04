# Copyright 2020-2021 RIFT Inc
# Copyright 2021-2022 DZS Inc

import asyncio
import gi
import json
import logging
import os
import requests
import rift
import shlex
import shutil
import subprocess
import sys

from rift.tasklets.rwlicmgr.triallicense import install_trial_license
from rift.export_import.rw_import_checker import ImportChecker
from rift.vcs.upgrade import PreUpgradeRunner
from rift.vcs.upgrade import RwVersion

gi.require_version('rwlib', '1.0')
from gi.repository import (
    rwlib,
)
from rift.rwlib.k8s import (
    ConfigMap,
    ServiceInfo,
)
from kubernetes.client.rest import ApiException


logging.basicConfig(level=logging.INFO)


class ServiceData(object):
    """Per service information fetched from the service info json
    """
    def __init__(self):
        """
        """
        self.name = None
        self.service_type = None
        self.node_ports = list()
        self.cluster_ip = None
        self.external_ip = None  # Loadbalancer IP

        # Used by only haproxy ingress
        self.https_proxy_port = None
        self.redis_proxy_port = None
        self.mongo_proxy_port = None


class SDConfig(object):
    """Creates the required configuration from the service information
    JSON data obtained from kubernetes cluster.
    """
    DEFAULT_HTTPS_PORT = 443
    DEFAULT_REDIS_PORT = 8014
    DEFAULT_MONGO_PORT = 8006

    def __init__(self, json_str):
        """Constructor.

        Arguments:
            json_str: The service information obtained from k8s cluster.
        """
        self._json_str = json_str

        # RIFT.ware services
        self._rw_services = dict()
        self._populate_service_map()

        self._external_addr = None  # The external address if set in values
        self._external_ip = None  # The Loadbalancer IP of HAProxy when configured as LB

    def _populate_service_map(self):
        """
        """
        self._rw_services["launchpad"] = ServiceData()
        self._rw_services["grafana"] = ServiceData()
        self._rw_services["prometheus"] = ServiceData()
        self._rw_services["alertmgr"] = ServiceData()
        self._rw_services["nats"] = ServiceData()
        self._rw_services["redis"] = ServiceData()
        self._rw_services["mongo"] = ServiceData()
        self._rw_services["haproxy-ingress"] = ServiceData()
        self._rw_services["haproxy-metrics"] = ServiceData()
        self._rw_services["loki"] = ServiceData()

    def parse(self):
        """Parse the json string and populate per service ServiceData object.
        """
        sd_json = json.loads(self._json_str)

        for item in sd_json['items']:
            metadata = item["metadata"]
            spec = item["spec"]
            status = item["status"]

            service_type = spec["type"]
            service_name = metadata["name"]

            logging.info("Found service {} of type {}".format(service_name, service_type))

            prefix = ""
            for svc in self._rw_services.keys():
                if svc in service_name:
                    prefix = svc
                    break
            else:
                logging.error("Unknown service found: {}".format(service_name))
                continue

            self._rw_services[prefix].name = prefix
            self._rw_services[prefix].service_type = service_type
            self._rw_services[prefix].cluster_ip = spec["clusterIP"]

            node_ports = list()
            if service_type in ["LoadBalancer", "NodePort"]:
                for port in spec["ports"]:
                    node_ports.append((port["name"], port["port"], port["nodePort"]))

            self._rw_services[prefix].node_ports = node_ports

            if service_type == "LoadBalancer":
                self._rw_services[prefix].external_ip = status["loadBalancer"]["ingress"][0]["ip"]

            # If haproxy-ingress, fill out proxy port details from the annotation
            # The annotation for proxy port starts with "rw-proxy-" prefix followed
            # by the ingress port name.
            if prefix == "haproxy-ingress":
                if "annotations" in metadata:
                    annotations = metadata["annotations"]
                    for ann in annotations.keys():
                        if ann.find("rw-proxy") == 0:
                            port = ann.split('-')[-1]
                            logging.info("Proxy port found {}".format(ann))
                            if port == "https":
                                self._rw_services["haproxy-ingress"].https_proxy_port = annotations[ann]
                            elif port == "mongo":
                                self._rw_services["haproxy-ingress"].mongo_proxy_port = annotations[ann]
                            elif port == "redis":
                                self._rw_services["haproxy-ingress"].redis_proxy_port = annotations[ann]

        logging.info("Parse completed successfully")

    def validate_external_access_setup(self):
        """RIFT.ware can be configured to setup with and without
        a proxy. When a proxy is used there is only one LB service required.
        We do not want any of the backend services to be in LoadBalancer mode.

        When a proxy is not used, each service may or maynot have its own LB.
        """
        logging.info("Validating external access config")

        if not self._rw_services["haproxy-ingress"].service_type:
            logging.error("Service type for HA Proxy ingress not found")
            raise Exception("HAProxy ingress not found")

        # Check if haproxy was found during service discovery
        if self._rw_services["haproxy-ingress"].service_type == "LoadBalancer":
            self._external_ip = self._rw_services["haproxy-ingress"].external_ip
            self._external_addr = os.getenv("RIFT_EXTERNAL_ADDRESS", None)
        else:
            self._external_ip = None
            # In NodePort mode we need to check if any external address is set
            self._external_addr = os.getenv("RIFT_EXTERNAL_ADDRESS", None)
            if not self._external_addr:
                logging.error("External address not set for Proxy NodePort configuration")
                raise Exception("External address not set")

        # If external address is already setup, use that
        ext_addr = rwlib.getenv("RIFT_EXTERNAL_ADDRESS")
        if ext_addr:
            self._external_addr = ext_addr

        # Iterate other services to check their service type
        for svc_name in self._rw_services:
            svc = self._rw_services[svc_name]
            if svc.service_type == "LoadBalancer" and svc.name != "haproxy-ingress":
                logging.error("Found service {} in LoadBalancer mode even with proxy setup".format(svc.name))

    def set_rift_external_address(self):
        """set RW.Env variable RIFT_EXTERNAL_ADDRESS.

        Precedence:
         1. External address if configured.
         2. Loadbalancer external IP.
        """
        # read the current extenal address
        current_ext_address = rwlib.getenv('RIFT_EXTERNAL_ADDRESS')
        # to use the fqdn used by the proxy
        ext_address_from_install = os.getenv("RIFT_DSOPROXY_ADDRESS", None)
        # read the external address that is configured during installation
        if not ext_address_from_install:
            ext_address_from_install = os.getenv("RIFT_EXTERNAL_ADDRESS", None)
        # in case no external address is configured get the Loadbalancer ip
        if not ext_address_from_install:
            ext_address_from_install = self._external_ip

        if not ext_address_from_install:
            logging.error("No external address is found")
            raise Exception("No external address is found")

        # if the current external address and external address configured are different need to update env
        if current_ext_address != ext_address_from_install:
            rwlib.setenv('RIFT_EXTERNAL_ADDRESS', ext_address_from_install)
            ext_addr = rwlib.getenv("RIFT_EXTERNAL_ADDRESS")
            if ext_addr:
                self._external_addr = ext_addr
        else:
            return

    def create_config_files(self, lp_namespace):
        """Create config files for LP to read and configure itself accordingly
        """
        # The config files which needs to be updated for AEO pods
        aeo_config_files = list()
        aeo_namespace = os.getenv("RW_AEO_NAMESPACE")

        for svc_name in self._rw_services:
            svc = self._rw_services[svc_name]
            if not svc.name:
                logging.warning("Service name not found for {}".format(svc_name))
                continue

            file_prefix = svc.name.replace('-', '_') + "_"
            if svc.name == "launchpad":
                file_prefix = ""

            file_name = "/config/{}service_type".format(file_prefix)
            with open(file_name, 'w') as fd:
                fd.write(svc.service_type)
                aeo_config_files.append(file_name)

            # Since external access would solely be via proxy
            # we do not need a node_port map for each service.
            if svc_name == "haproxy-ingress":
                file_name = "/config/{}port_map".format(file_prefix)

                https_port = self.DEFAULT_HTTPS_PORT
                redis_port = self.DEFAULT_REDIS_PORT
                mongo_port = self.DEFAULT_MONGO_PORT

                # if node port, then set to that
                if svc.service_type == "NodePort":
                    for np in svc.node_ports:
                        if np[0] == "https":
                            https_port = np[2]
                        elif np[0] == "redis":
                            redis_port = np[2]
                        elif np[0] == "mongo":
                            mongo_port = np[2]

                # If proxy port is set, then use that
                if svc.https_proxy_port:
                    https_port = svc.https_proxy_port
                if svc.redis_proxy_port:
                    redis_port = svc.redis_proxy_port
                if svc.mongo_proxy_port:
                    mongo_port = svc.mongo_proxy_port

                with open(file_name, 'w') as fd:
                    fd.write("https {}\n".format(https_port))
                    fd.write("redis {}\n".format(redis_port))
                    fd.write("mongo {}\n".format(mongo_port))
                    aeo_config_files.append(file_name)

            file_name = "/config/{}cluster_ip".format(file_prefix)
            with open(file_name, 'w') as fd:
                fd.write(svc.cluster_ip)

        # Set Grafana external access ip
        file_name = "/config/grafana_ip"

        if self._rw_services["haproxy-ingress"].service_type is not None:
            if self._external_addr != "":
                with open(file_name, 'w') as fd:
                    fd.write(self._external_addr)

            elif self._external_ip:
                with open(file_name, 'w') as fd:
                    fd.write(self._external_ip)

        # Update the config maps for other application pods
        cfg_map = ConfigMap()
        kv_dict = dict()

        for cfg_file in aeo_config_files:
            head, tail = os.path.split(cfg_file)
            kv_dict[tail] = open(cfg_file, 'r').read()

        # Add RIFT_EXTERNAL_ADDRESS
        if self._external_addr:
            kv_dict["RIFT_EXTERNAL_ADDRESS"] = self._external_addr
        elif self._external_ip:
            kv_dict["RIFT_EXTERNAL_ADDRESS"] = self._external_ip

        if aeo_namespace:
            api_response = None
            try:
                api_response = cfg_map.create_config_map("sd-config", kv_dict, namespace=aeo_namespace)
                logging.info("Created sd config for AEO pods")
            except ApiException as e:
                if e.body:
                    body = json.loads(e.body)
                    if body["reason"] != "AlreadyExists":
                        logging.error("ConfigMap ApiException for AEO. Error: {}".format(error=body))
                    else:
                        cfg_map.replace_config_map("sd-config", kv_dict, namespace=aeo_namespace)
                        logging.info("Replaced AEO sd config")
                else:
                    raise e

        if aeo_namespace != lp_namespace:
            # LP and aeo namespace are differnet, LP pods may also require sd-config
            api_response = None
            try:
                api_response = cfg_map.create_config_map("sd-config", kv_dict, namespace=lp_namespace)
                logging.info("Created sd config for LP pods")
            except ApiException as e:
                if e.body:
                    body = json.loads(e.body)
                    if body["reason"] != "AlreadyExists":
                        logging.error("ConfigMap ApiException for LP. Error: {}".format(error=body))
                    else:
                        cfg_map.replace_config_map("sd-config", kv_dict, namespace=lp_namespace)
                        logging.info("Replaced LP sd config")
                else:
                    raise e


def get_service_info(token, namespace):
    """Fires an HTTP GET towards k8s cluster to get the service information.
    """
    url = "https://kubernetes.default.svc/api/v1/namespaces/{}/services".format(namespace)
    headers = {
        "Authorization": "Bearer {}".format(token)
    }
    r = requests.get(url, headers=headers, verify=False)
    if r.status_code != 200:
        logging.error("Error fetching service information({})".format(r.status_code))
        return None

    return r.content


def main():
    """
    """
    env_file_ipaddr = "/usr/rift/var/rift/env.d/RWVM_INTERNAL_IPADDR"
    if os.path.exists(env_file_ipaddr):
        os.remove(env_file_ipaddr)

    with open("/var/run/secrets/kubernetes.io/serviceaccount/token", 'r') as fd:
        token = fd.read().strip()

    with open("/var/run/secrets/kubernetes.io/serviceaccount/namespace", 'r') as fd:
        namespace = fd.read().strip()

    svc_json = get_service_info(token, namespace)
    if not svc_json:
        logging.error("Failed to fetch service information from kubernetes cluster")
        sys.exit(-1)

    # Dump the json data into file for later debugging
    with open("/config/svc_info.json", 'w') as fd:
        fd.write(svc_json.decode("utf-8"))

    s = SDConfig(svc_json)
    s.parse()
    logging.info("Service info parsed successfully")

    s.validate_external_access_setup()
    logging.info("External access setup verified successfully")

    s.set_rift_external_address()
    logging.info("Rift external address setup finished")

    s.create_config_files(namespace)
    logging.info("Service discovery config files are ready")


def _parse_rvr_path(rvr_path):
    """Parse RVR path to get the version
    """
    pos = rvr_path.find("rift-")
    if pos == -1:
        raise Exception("Invalid RVR path format: {}".format(rvr_path))

    return rvr_path[(pos + len("rift-")):]


def _ver_compare(prev_ver, new_ver):
    """Compare previous version with new version

    Returns
       0 when both the versions are equal
       1 when self is greater than other
      -1 when self is lesser than other
    """
    prev_ver_tuple = tuple(prev_ver.split('.'))
    new_ver_tuple = tuple(new_ver.split('.'))

    if len(prev_ver_tuple) not in[4, 5] or len(new_ver_tuple) != 4:
        # Do not do anything special
        return 0

    rw_ver_prev = RwVersion(ver_tuple=prev_ver_tuple)
    rw_ver_new = RwVersion(ver_tuple=new_ver_tuple)

    return rw_ver_prev.compare(rw_ver_new)


def _copy_from_old_version(new_versioned_rvr):
    """Copy the required directories from the old rvr version (currently symlinked)
    to the new RVR version directory as pointed to by `new_versioned_rvr`
    """
    rvr = "/usr/rift/var/rift"

    def copy(dname):
        logging.info("Starting copy of directory {}".format(dname))

        new_dir_path = "{}/{}".format(new_versioned_rvr, dname)
        if os.path.exists(new_dir_path):
            shutil.rmtree(new_dir_path)

        old_dir_path = "{}/{}".format(rvr, dname)
        if not os.path.exists(old_dir_path):
            return

        shutil.copytree(old_dir_path, new_dir_path)

        logging.info("Copy of directory {} finished".format(dname))

    dirs = [
        "persist.riftware", "launchpad", "env.d", "ha_client", "lpmon_client", "glance", "rw.ui",
        "mongo_cert", "version", "log/cfgmgr"]

    for d in dirs:
        copy(d)


def _prepare_rollback():
    """Invoke RW.Redis utility to prepare for rollback.
    This involves reloading Redis with backed up RDB data and
    placing the config xml file for reload.
    """
    cmd = "python3 /usr/rift/usr/bin/rw_redis_backup.py --disable_redis_sync --rollback-apply"
    try:
        subprocess.check_call(shlex.split(cmd))
    except Exception as e:
        logging.error("Failed to prepare for rollback. Error: {}".format(e))
        raise e


def prepare_rvr():
    """Create the RVR symlink to the installed version.
    Also copies data from the old version to the new RVR version in case
    of software upgrade.
    """
    install_ver = os.getenv("RIFT_IMAGE_VERSION")
    versioned_dir = "/usr/rift/var/rift-{}".format(install_ver)

    if not os.path.exists(versioned_dir):
        logging.info("{} does not exist. Creating one".format(versioned_dir))
        os.makedirs(versioned_dir, exist_ok=True, mode=0o777)

    # The version which the rvr was pointing to before this
    prev_rvr = None
    rvr_path = "/usr/rift/var/rift"

    if os.path.exists(rvr_path) and not os.path.islink(rvr_path):
        try:
            shutil.rmtree(rvr_path)
        except Exception as e:
            os.remove(rvr_path)

    if os.path.exists(rvr_path):  # This is symlink if True
        prev_rvr = os.path.realpath(rvr_path)
        if not prev_rvr:
            logging.error("RVR inconsistency detected. Symbolic link target does not exist")
            raise Exception("Missing symbolic link target")

        prev_rvr = _parse_rvr_path(prev_rvr)
        ver_cmp_res = _ver_compare(prev_rvr, install_ver)

        if ver_cmp_res == -1:
            logging.info("New install version detected. Previous version: {}. New version: {}".format(prev_rvr, install_ver))
            _copy_from_old_version(versioned_dir)

        elif ver_cmp_res == 1:
            if len(os.listdir(versioned_dir)):
                # Even for helm upgrade to a downgraded version, if RVR is
                # present for the target version, LP will roll back to the
                # target version
                logging.info("Rollback case detected. Previous version: {}. New version: {}".format(prev_rvr, install_ver))
                # Set an environment variable to be used later
                os.environ["PRELAUNCH_ROLLBACK_DETECTED"] = "1"
            else:
                logging.error("Aborting invalid upgrade/rollback detected. Previous version: {}. New version: {}".format(prev_rvr, install_ver))
                raise Exception("Invalid upgrade or rollback detected")

    # Create softlink dir rift to the version
    if os.path.exists(rvr_path):
        logging.info("RVR path exists. Recreating it.")
        os.unlink(rvr_path)

    os.symlink(os.path.basename(versioned_dir), rvr_path, target_is_directory=True)


if __name__ == "__main__":
    # Setup RVR to the correct version.
    # For upgrade cases it would do additional job of copying files from older version
    # For rollback case, it just updates an environment variable to trigger rollback flow later.
    try:
        prepare_rvr()
    except Exception as e:
        logging.error("Prelaunch script failed in prepare_rvr:  {}".format(str(e)))
        sys.exit(-1)

    # If rollback case, trigger the rollback flow
    # NOTE: The rollback case unlike upgrade doesn't need any pre-rollback
    # hooks as of now, since we have all the required information for recovery
    # already saved inside the versioned rvr.
    env_file = "/usr/rift/var/rift/env.d/RW_NODE_UPGRADE_ROLLBACK"

    # Clear RW_NODE_UPGRADE_ROLLBACK flag if set
    try:
        if os.path.exists(env_file):
            os.remove(env_file)

    except Exception as e:
        logging.error("Prelaunch script failed in env cleanup:  {}".format(str(e)))

    try:
        if os.getenv("PRELAUNCH_ROLLBACK_DETECTED", None):
            logging.info("Preparing for rollback operation")
            _prepare_rollback()

            with open(env_file, 'w') as fd:
                fd.write("ROLLBACK")

    except Exception as e:
        logging.error("Prelaunch script failed in rollback: {}".format(str(e)))
        rwlib.setenv("RW_HA_BOOT_FLAG", "ROLLBACK_FAIL")
        sys.exit(-1)

    # Check for any import operation
    try:
        ImportChecker.check_for_import()
    except Exception as e:
        logging.error("Prelaunch script failed in import checker: {}".format(str(e)))

    # Perform the model data upgrade if required
    try:
        req_dirs = ["/usr/rift/var/rift/log/rwlogd",
                    "/usr/rift/var/rift/env.d",
                    "/usr/rift/var/rift/log/cfgmgr",
                    "/usr/rift/var/rift/cfgmgr/tmp",
                    "/usr/rift/var/rift/persist.riftware"]

        for d in req_dirs:
            os.makedirs(d, exist_ok=True)

        PreUpgradeRunner.check_and_mark_for_upgrade()

    except Exception as e:
        logging.exception("Prelaunch script failed in pre-upgrade: {}".format(str(e)))
        sys.exit(-1)

    # Perform the main SD routine
    try:
        main()
    except Exception as e:
        logging.exception("Prelaunch script failed in SD setup: {}".format(str(e)))
        sys.exit(-1)

    try:
        install_trial_license()
    except Exception as e:
        logging.exception("Prelaunch script failed to install Trial license: {}".format(str(e)))
