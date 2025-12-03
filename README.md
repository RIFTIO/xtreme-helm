# xtreme-helm
Helm chart for installing Xtreme NFVO or AEO

PLEASE NOTE that this helm chart is useless unless you have a token for accessing 
the ZHONE Inc container image repository currently hosted on dockerhub
or you are inside the zhone lab.

files in this dir
* README.md this file
* repos.yaml -- values to use public repos
* storage.yaml -- values to use the non-default storage class
* values-aeo.yaml -- values to get the latest build
* kafka.yaml -- values to work around a bug in the kafka message broker
* ports.yaml -- values to force all services to use unique ports on a single IP (needed for k3s)
* install_xtreme -- a script for running the install. Use ./install_xtreme --help 
* xtreme/ the helm chart


INSTALLATION 

unless you are in the zhone lab, you must have a token in order to download container 
images from the Zhone docker-hub repository. Place
this token in a file called dockerhub-token.

check your storage class (kubectl get storageclases) and update storage.yaml

run:
./install-xtreme 

If you are in the dzs lab, add --values "values-aeo.yaml storage.yaml" (i.e. drop repos.yaml)

when it's done, it will query the status forever until it gets a successful response. This can take 10
minutes or more if your internet link is slow

notes

The pods in primary namespace are highly interdependent, so initial startup can be slow. Once all the pods
in the primary namespace are up, the pods in the aeo- namespace can start. Many of these will have crashed at
least once due to the timeouts during init. These will restart on their own, so just be patient. 

branches in this repo

main -- production 
zhone -- as delivered by engineering 
