# RIFT.ware Helm Chart

![RIFT Logo](https://riftio.com/wp-content/uploads/2018/10/RIFT-Color-medium-e1538404700614.png)


[RIFT.ware](https://riftio.com) is the orchestration and automation solution that makes the transition from physical networks to software-based networks possible.

# Installation Notes

RIFT.ware requires [Helm 3](https://helm.sh/) for installation.

Deploy RIFT.ware in a separate namespace if using Nodeport for the pods.

## Important Values

For the RIFT.ware installation to work correctly the following values should be specified correctly in the values.yaml (-f option) file or using the --set override when installing a Helm Chart:

### haproxy-ingress.service.type

Kubernetes service type for access into RIFT.ware system.
All external access towards RIFT.ware happens through the HAProxy ingress controller. The HAProxy Ingress service can be configured in:

1. `LoadBalancer`
When installed in `LoadBalancer` mode, the external access can be done either using the `externalAddress`(See below) or via the external LoadBalancer IP. `externalAddress` if configured is given more preference than LoadBalancer IP.

2. `NodePort`
When installed in `NodePort` mode, HAProxy Ingress service is assigned a port number greater than 30000. This port can then be used for accessing RIFT.ware services.

Default Value: `NodePort`.

### externalAddress

This is a hostname or IP address of launchapd that is externally accessible. In a k8s cluster any node in the cluster can be set to this value. However once set, the same address must be used for accessing RW.UI. RW.REST and other services continue to be accessed using other node names.

### global.ingress.proxyPort

If RIFT.ware needs to be run and accessed behind a proxy/loadbalancer (in front of RIFT.ware ingress proxy), use the proxyPort to specify the port on the external proxy/loadbalancer, which will forward the traffic on that port to RIFT.ware HAProxy ingress controller.

### global.ingress.nodePort

If the cluster allows specifing the port to be allocated on the service, nodePort can be used for the same.

### namespace.name

Namespace in which the RIFT.ware will be installed. Defaults to 'rift-lp'. To share multiple RIFT.ware installations in the same k8s cluster, this namespace should be changed (will also require a differnt nfs mount).

### launchpad.image.repository

The docker image for RIFT.ware. Version is specified in the Chart.yaml:appVersion.

Defaults to `rt.cloud.dzsi.local/docker/launchpad/dzs`

### storage.nfs.mountPath

Path to the nfs mount. The nfs server is specified using storage.nfs.server parameter. To disable nfs and use the k8s cluster's default storage class, set storage.nfs to null (this should be default value).

To run mutliple launchpads on the same k8s cluster one must specify a mount path not used by other RIFT.ware services.

### storage.manual.mountPath

Path to the local storage on the worker node.

If you are using this type of storage, make sure all the pods for RIFT.ware are installed on the same node by using the nodeSelector fields.

To run mutliple launchpads on the same k8s cluster one must specify a mount path not used by other RIFT.ware services. Also specify a different namespace for each

## Installation on RedHat OpenShift

When using [RedHat OpenShift](https://www.openshift.com), pre-create the namespace for deploying the RIFT.ware and assign the service account used for deploying RIFT.ware with 'anyuid' scc (security context constraint) privileges. The scc can be assigned to the default service account in the current namespace using:

`oc adm policy add-scc-to-user anyuid -z default`

## Accessing RIFT.ware services

# Service Type - NodePort

By default RIFT.ware is installed as a service usign k8s NodePort option. This would mean that the RIFT.ware servies can be accessed externally only using the NodePort ports (ports >30000 assigned by k8s) and not the default ports. To get the service ports execute the following command:

`kubectl get service -n <namespace.name-in-values.yaml>`

To access the UI, check which port 8443 is mapped to and use it as `https://<externalAddress-in-values.yaml>:<mapped-port>`

# Service Type - LoadBalancer

When RIFT.ware is installed in LoadBalancer mode, k8s controllers allocate a Load Balancer with external access, that routes messages only to the RIFT.ware service. RIFT.ware service can be accessed using the IP address allocated for the Load Balancer. This Load Balancer external IP can be obtained by using the following command:

`kubectl get service -n <namespace.name-in-values.yaml>`

The EXTERNAL-IP column specifies the address assigned to the Load Balancer. RIFT.ware can be accessed using the external-ip address or an FQDN pointing to it.

In this mode the externalAddress in the values.yaml file is optional. If this address is not specified, the helm chart automatically takes the EXTERNAL-IP for the LP service. To access RIFT.ware UI use the following URL - https://<EXTENAL-IP|FQDN>:8443.
