# xtreme-helm
Helm chart for installing Xtreme NFVO or AEO

This is release 13.6.0. It is an AEO release. Please pick a different branch or 
tag if you want NFVO. 

PLEASE NOTE that this helm chart is useless unless you have a token for accessing 
the Zhone Inc container image repository currently hosted on dockerhub
or you are inside the Zhone lab.

files in this dir
* README.md this file
* alias.yaml -- values to force xtreme to use a FQDN instead of an IP address. When running on a single node
                system behind singleIP address (as is done with k3s) then you may need this file. The values in 
                this file need to bo coordinated with your company's DNS system.
* repos.yaml -- values to use public repos -- you will need this unless you are in the Zhone lab
* storage.yaml -- values to use the non-default storage class
* values-aeo.yaml -- values to get the latest AEO build
* values-nfvo.yaml -- values to get the latest NFVO build
* ports.yaml -- values to force all services to use unique ports on a single IP (needed for k3s)
* install_xtreme -- a script for running the install. Use ./install_xtreme --help 
* xtreme/ the helm chart

## Changes since 13.6.0
* there are two new options '--dev' and '--prod'. --dev is for working in the Zhone lab. --prod is for everyone else. 
* when installing into k3s, the additional yaml values files are automatically included 
* secrets are now created by helm, not via kubectl 
* New option to set resource constraints

## Changes Since 13.4.0
* added a check that the script has proper access to the cluster 
* some kafka related upgrade fixes 

CHANGES 
* 13.5.0 (NFVO) -- there are new values for controlling the installation of the AI subchart. See values-nfvo.yaml.

## INSTALLATION 

Unless you are in the Zhone lab, you must have a token in order to download container 
images from the Zhone docker-hub repository. Place
this token in a file called dockerhub-token.
If you are running inside the Zhone lab and using the Zhone registry (by not using repos.yaml), then you can create a dummy dockerhub-token file as
the contents will not matter, e.g. 

```bash
echo foo >dockerhub-token
```

check your storage class (kubectl get storageclases) and update storage.yaml

run:

```bash
./install-xtreme
```

If you are in the Zhone lab, use '--prod'

The installer will detect when the target is k3s, but you will have to customize alias.yaml first.

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

### official branches in this repo
* main -- production AEO --- currently 13.6.0 
* release_13.5 -- NFVO -- all of the 13.5.x releases will be tagged on this branch
* release_13.6 -- exists for creating updates to 13.6, e,g, 13.6.1 

### official tags -- This align with the versions that existed when the product was officially released
* v13.6.0 -- latest AEO release
* v13.5.0 -- latest NFVO release
* v13.4.0 -- deprecated. Please use branch release_13.4.1 for AEO  
* v13.3.2 -- deprecated. Please use v13.5.0 

### Development Branches -- bitbucket only. Do not push to github 
* release_26.06 --  the next AEO release.

Zhone Engineers -- the HEAD of main was hard reset as part of releasing 13.6.0 because main had some in-progress work.
So you may need to hard reset your workspaces. The in-progress work is now part of branch release_26.06 and will 
be included in the next release.   
