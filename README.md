# xtreme-helm
Helm chart for installing Xtreme NFVO or AEO

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


CHANGES 
* 13.5.0 (NFVO) -- there are new values for controlling the installation of the AI subchart. See values-nfvo.yaml.

INSTALLATION 

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

If you are in the Zhone lab, add --values "values-aeo.yaml storage.yaml" (i.e. drop repos.yaml)

When it's done, it will query the status forever until it gets a successful response. This can take 10
minutes or more if your internet link is slow

You can run 

```bash 
kubectl get pods -n <namespace> -w 
```

to watch the startup progress. When all of these pods are up, you can do

```bash
kubectl get pods -n aeo-<namespace> -w
```

to watch it finish up 


notes

* The pods in primary namespace are highly interdependent, so initial startup can be slow. Once all the pods
in the primary namespace are up, the pods in the aeo- namespace can start. Many of these will have crashed at
least once due to the timeouts during init. These will restart on their own, so just be patient. 

* Be consistent when using the --ns option and use it for every command, including --clean 


official branches in this repo

* main -- production 
* zhone -- as delivered by engineering. Deprecated as of 13.4.1
* release_13.5 -- all of the 13.5.x releases will be tagged on this branch
* release_13.4.1 -- latest AEO release

official tags 
* v13.5.0 -- latest NFVO release
* v13.4.0 -- deprecated. Please use branch release_13.4.1 for AEO  
* v13.3.2 -- deprecated. Please use v13.5.0 
