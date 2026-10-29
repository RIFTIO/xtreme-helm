# xtreme-helm
Zhone Technologies, Inc helm chart for installing Xtreme NFVO or AEO


# TL;DR
in the Zhone lab 

    ./install_xtreme --dev

In the real world

    echo dckr_pat_xxxdfjklkjklfjk >dockerhub-token  # use the token you got from Zhone
    ./install_xtreme 



# Introduction

This is release 26.07.01 (13.7.0). It is an AEO release. Please pick a different branch or 
tag if you want NFVO. See below.


PLEASE NOTE that this helm chart is useless unless you have a token for accessing 
the Zhone Inc container image repository currently hosted on dockerhub
or you are inside the Zhone lab.

## Pre-requisites 
* the worker nodes must be running linux kernel 5.x or 6.x. 7.x is not supported today
* The cluster must be running k8s 1.30 or later 
* for k3s, there must be 500 GB available in /var/lib/ on the host 
* helm 3.13 is a minimum, 3.20 is recommended. 4.x is not supported. 

## Breaking change for upgrades from 13.6.x or earlier

The defaults for managing storage have flipped. The default used to be that you had to specify --storage if
you did not want to use the default storage clasees. The new default is to include this file. So if you 
did not use --storage for your initial install, you must use --no-storage on the upgrade. 

## files in this dir
* README.md this file
* alias.yaml -- values to force xtreme to use a FQDN instead of an IP address. When running on a single node
                system behind single IP address (as is done with k3s) then you may need this file. The values in 
                this file need to bo coordinated with your company's DNS system.
* repos.yaml -- values to use public repos -- you will need this unless you are in the Zhone lab
* storage.yaml -- values to use the non-default storage class
* ports.yaml -- values to force all services to use unique ports on a single IP (needed when the
                cluster has only one routable IP address, e.g. k3s with its built-in ServiceLB)
* install_xtreme -- a script for running the install. Use ./install_xtreme --help 
* xtreme/ the helm chart
* JenkinsFile -- part of the Zhone CI pipeline
* check-dns.sh -- used by install_xtreme  
* check_upgrade_from -- used by install_xtreme 
* pool-has-multiple-ips.sh -- used by install_xtreme to decide if the load balancer pool holds more than one IP
* delete_orphaned_secrets.sh -- used by install_xtreme
* admin (dir) -- init-cluster.sh, mk-tenant.sh and rm-tenant.sh: the cluster-admin half of a tenant install
                 (see TENANT INSTALL below). admin/generated/ holds per-tenant output including kubeconfigs
                 and is git-ignored
* docker (dir) -- source for some support containers 
* trivy (dir) -- tools for verifying CVEs

note that values-aeo.yaml has moved to xtreme/aeo-values.yaml

## Changes in 26.07.01
The software was not updated. All changes are in the helm chart
* upgrades from earlier releases preserve mongo data 
* the storage class can now be specified for all persistent volumes
* the permissions are set correctly in all persistent volumes 
* imagePullSecrets are now set for all Zhone container images 

## Changes in 13.7.0
* there is a new option --image-puller
* --storage is now the default. --no-storage is the inverse. For upgrades, the script will 
  determine the proper storage settings
* install_xtreme now confirms that storage.yaml is configured correctly 
* All aeo images tags are now controlled by globals.aeoImgTag. just like globals.sdncImgtag 
* alias.yaml and ports.yaml are now enabled by inspecting the cluster's load balancer instead of
  simply detecting k3s: they are only included when all services must share a single IP address
  (e.g. k3s ServiceLB/Klipper, or MetalLB with a single-IP pool). A k3s cluster with a real
  load balancer address pool (e.g. installed via Rancher) no longer gets them by default.
* new tenant install mode: install_xtreme --tenant installs with a namespaced kubeconfig and no
  cluster-admin, after a cluster admin has run admin/init-cluster.sh (once) and admin/mk-tenant.sh
  (per tenant). See TENANT INSTALL below. Backed by a new chart value global.tenantMode which omits
  every cluster-scoped object (ClusterRole, ClusterRoleBinding, IngressClass) from the render.


## Changes in 13.6.1
* Many third-party container images have been upgraded to fix CVEs
* There is a new check that kafka CRDs are up to date
* There is a new check that the upgradeFrom value is correct
* There is a new tool check-dns.sh which confirms that alias.yaml is correct 
* Orphaned secrets are now automatically deleted
* There is no longer a need to create a dummy token file when using option --dev
* If the script detects that the target cluster is running k3s, alias.yaml and ports.yaml are automatically included. 


# INSTALLATION 

Unless you are in the Zhone lab, you must have a token in order to download container 
images from the Zhone docker-hub repository. Place
this token in a file called dockerhub-token.

check your storage class (kubectl get storageclases) and update storage.yaml

If you are installing into a single node cluster that only has 1 public IP address, update alias.yaml

run: ```./install-xtreme```

If you are in the Zhone lab, use option  ```--dev``` to prevent pulling images over the internet

When it's done, install_xtreme will query the status forever until it gets a successful response. This can take 10
minutes or more if your internet link is slow. You can control-c out of the script 
at this point if you want to check status other ways, and restart the script using the
--check option to restart the status checks.  


You can run 

```bash 
kubectl get pods -n <namespace> -w 
```

to watch the startup progress. When all of these pods are up, you can do

```bash
kubectl get pods -n aeo-<namespace> -w
```

to watch it finish up 

## upgrade notes 
* make sure you use the same --ns and --release arguments as your initial install
* * Use ```helm ls``` and look at NAME to get the release
* * Use ```kubectl get pods -A | egrep 'NAME|launchpad``` to figure out the ns (namespace) 
* add --upgrade as an argument 
* the installer will figure out your storage classes

## TENANT INSTALL (no cluster-admin)

Kubernetes will not let a namespaced user create cluster-scoped objects, and xtreme needs a few:
the Strimzi CRDs, 11 ClusterRoles, 7 ClusterRoleBindings and an IngressClass. So the install is split
in two. A cluster admin creates those; each tenant then installs, upgrades and uninstalls everything
else with a kubeconfig that has rights only in its own two namespaces (<ns> and aeo-<ns>).

### Admin: once per cluster

```bash
./admin/init-cluster.sh
```

Applies the Strimzi CRDs and creates the shared ClusterRole xtreme-tenant-readonly (get/list on
nodes, CRDs and storageclasses, which install_xtreme's pre-flight checks need). Idempotent; rerun
after a chart upgrade that changes the CRDs.

### Admin: per tenant

```bash
./admin/mk-tenant.sh [-r <release>] <ns>[:<release>] [<ns>[:<release>] ...]
```

For each namespace this creates <ns> and aeo-<ns>, renders the chart and applies only its
cluster-scoped objects, creates a ServiceAccount xtreme-installer with a Role in both namespaces,
binds it to xtreme-tenant-readonly, and writes admin/generated/<ns>.kubeconfig (token valid one
year). Give that file to the tenant. Rerunning is safe and mints a fresh token.

The release name (per tenant as <ns>:<release>, else -r, else xtreme) MUST be the --release that tenant will use: some charts name
their ServiceAccounts after it and the ClusterRoleBindings are bound to those names. Release names
are per-namespace in helm, so every tenant can use the default. install_xtreme --tenant refuses a
mismatch when run from this checkout.

If the admin kubeconfig goes through the Rancher proxy (server .../k8s/clusters/<id>), the tenant
kubeconfig is pointed at the first control-plane node on port 6443 instead, because the proxy does
not accept ServiceAccount tokens. Set TENANT_SERVER=https://host:6443 if that address is not
reachable from where the tenant runs.

### Tenant

With only that kubeconfig and a checkout of this repo:

```bash
export KUBECONFIG=/path/to/<ns>.kubeconfig
./install_xtreme --dev --ns <ns> --release <release> --tenant --dry-run
./install_xtreme --dev --ns <ns> --release <release> --tenant
```

--tenant implies --skip-crds and global.tenantMode=true, and turns off the single-IP autodetection
(pass --values alias.yaml --values ports.yaml yourself if the cluster needs them). Upgrades work the
same way; the script switches to upgrade when the release already exists.

### Cleanup

```bash
./install_xtreme --ns <ns> --release <release> --tenant --clean   # tenant: release + namespaced leftovers
./admin/rm-tenant.sh <ns> [<ns> ...]                               # admin: cluster RBAC, IngressClass, namespaces
```

rm-tenant.sh leaves the CRDs and xtreme-tenant-readonly in place since other tenants use them, and
skips a namespace if the current kubeconfig points at a different cluster than the one that tenant
was created on. To remove the shared pieces from a cluster with no tenants left:
kubectl delete -f xtreme/crds/ && kubectl delete clusterrole xtreme-tenant-readonly.


## notes

* The pods in primary namespace are highly interdependent, so initial startup can be slow. Once all the pods
in the primary namespace are up, the pods in the aeo- namespace can start. Many of these will have crashed at
least once due to the timeouts during init. These will restart on their own, so just be patient. 

* Be consistent when using the --ns option and use it for every command, including --clean 


official branches in this repo

* main -- production
* release_26.07 -- July 2026 AEO release. This is a work in progress 
* release_13.6 -- AEO release
* release_13.5 -- NFVO release 
* release_13.4.1 -- AEO release

official tags 
* v13.6.1 -- latest AEO GA release 
* v13.6.0 -- GA release -- deprcated, please use v13.6.1
* v13.5.0 -- latest NFVO GA release
* v13.4.0 -- deprecated. Please use v13.6.1  
* v13.3.2 -- deprecated. Please use v13.5.0 
