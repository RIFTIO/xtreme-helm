# xtreme-helm
Zhone Technologies, Inc helm chart for installing Xtreme NFVO or AEO

This is release 26.07 (13.7.0). It is an AEO release. Please pick a different branch or 
tag if you want NFVO. See below.


PLEASE NOTE that this helm chart is useless unless you have a token for accessing 
the Zhone Inc container image repository currently hosted on dockerhub
or you are inside the Zhone lab.

## files in this dir
* README.md this file
* alias.yaml -- values to force xtreme to use a FQDN instead of an IP address. When running on a single node
                system behind single IP address (as is done with k3s) then you may need this file. The values in 
                this file need to bo coordinated with your company's DNS system. You can run the tool 
               ```check-dns.sh``` to confirm that this file is correct 
* repos.yaml -- values to use public repos -- you will need this unless you are in the Zhone lab
* storage.yaml -- values to use the non-default storage class
* ports.yaml -- values to force all services to use unique ports on a single IP (needed for k3s)
* install_xtreme -- a script for running the install. Use ./install_xtreme --help 
* xtreme/ the helm chart
* JenkinsFile -- part of the Zhone CI pipeline
* check-dns.sh -- a tool to verify that the FQDN configured in alias.yaml is correct 
* check_upgrade_from -- used by install_xtreme 
* delete_orphaned_secrets.sh -- used by install_xtreme
* docker (dir) -- source for some support containers 
* trivy (dir) -- tools for verifying CVEs

note that values-aeo.yaml has moved to xtreme/aeo-values.yaml

## Changes in 13.7.0
* there is a new option --image-puller


## Changes in 13.6.1
* Many third-party container images have been upgraded to fix CVEs
* There is a new check that kafka CRDs are up to date
* There is a new check that the upgradeFrom value is correct
* There is a new tool check-dns.sh which confirms that alias.yaml is correct 
* Orphaned secrets are now automatically deleted
* There is no longer a need to create a dummy token file when using option --dev
* If the script detects that the target cluster is running k3s, alias.yaml and ports.yaml are automatically included. 


## INSTALLATION 

Unless you are in the Zhone lab, you must have a token in order to download container 
images from the Zhone docker-hub repository. Place
this token in a file called dockerhub-token.

check your storage class (kubectl get storageclases) and update storage.yaml

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
