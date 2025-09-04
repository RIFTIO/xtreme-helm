import os
import sys
import shlex
import subprocess
import logging

import rift.rwpylog
from rift.vcs.upgrade import RwVersion


def get_logger(module_name, log_file, level):
    """
    Create a logger
    """
    # Setup logger
    log = logging.getLogger(module_name)

    # Create Log Formatter
    logging.basicConfig(
        format='%(asctime)s.%(msecs)03d %(levelname)-8s %(message)s',
        level=logging.DEBUG,
        datefmt='%Y-%m-%d %H:%M:%S')

    formatter = logging.Formatter("%(message)s")

    # Create File Handler
    file_handler = logging.FileHandler(log_file)
    file_handler.setLevel(level)
    file_handler.setFormatter(formatter)

    # Add Handlers
    log.addHandler(file_handler)

    return log

def main():

    pylogger = get_logger('rwpreupgrade', "/usr/rift/var/rift/log/rwlogd/upgrade.log", logging.INFO)
    rwpylog = rift.rwpylog.Logger(pylogger=pylogger, log_as_json=True)
    rwpylog.set_default_module("rw-model-upgrade-log")

    upgrade_from = os.getenv("RW_UPGRADE_FROM_VER", None)
    if upgrade_from is None:
        rwpylog.event("rw-model-upgrade-log:model-upgrade-error", message="Missing upgradeFrom version")
        sys.exit(1)

    try:
        rvr = RwVersion.rvr_version()
        upgrade_from_ver = RwVersion(ver_tuple=tuple(upgrade_from.split('.')))

        result = upgrade_from_ver.compare(rvr)
        if result == 0:
            cmd = "python3 /usr/rift/usr/bin/rw_redis_backup.py --rollback-save --save --config --data --disable_redis_sync"
            try:
                subprocess.check_call(shlex.split(cmd))
            except Exception as e:
                rwpylog.event("rw-model-upgrade-log:model-upgrade-error", message="Execption on redis backup", error=str(e))
                sys.exit(1)
        else:
            rwpylog.event("rw-model-upgrade-log:model-upgrade-error", message="upgradeFrom is not matching with running launchpad version", upgrade_from=upgrade_from, launchpad_version=rvr)
            sys.exit(1)
    except Exception as e:
        rwpylog.event("rw-model-upgrade-log:model-upgrade-error", message="Exception on data backup",error=str(e))
        sys.exit(1)

if __name__ == "__main__":
    main()
