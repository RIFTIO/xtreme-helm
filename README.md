# xtreme-helm
Helm chart for installing Xtreme NFVO or AEO

PLEASE NOTE that this helm chart is useless unless you have a token for accessing 
the ZHONE Inc container image repository currently hosted on dockerhub. 

files in this dir
* README.md this file
* repos.yaml -- values to use public repos
* storage.yaml -- values to use the non-default storage class
* values-aeo.yaml -- values to get the latest build
* xtreme/ the helm chart

You must have a token in order to download container images from the Zhone docker-hub repository  
Once you have it, do

    token="<paste your token here"
    namespace="demo"  # you can change this, but you will also have to set this in the values
    kubectl create ns $namespace
    kubectl create ns aeo-$namespace
    kubectl -n $namespace create secret docker-registry dzs-secret --docker-server=docker.io --docker-username=dzscloudadmin --docker-password="$token"
    kubectl -n aeo-$namespace create secret docker-registry dzs-secret --docker-server=docker.io --docker-username=dzscloudadmin --docker-password="$token"

typical install line

    helm install xtreme ./xtreme -f storage.yaml -f repos.yaml -f values-aeo.yaml 

startup

The pods in primary namespace are highly interdependent, so initial startup can be slow. Once all the pods
in the primary namespace are up, the pods in the aeo- namespace can start. Many of these will have crashed at
least once due to the timeouts during init. These will restart on their own, so just be patient. 
