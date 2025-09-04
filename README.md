# xtreme-helm
Helm chart for installing Xtreme NFVO or AEO

files in this dir
* README.md this file
* repos.yaml -- values to use public repos
* storage.yaml -- values to use the non-default storage class
* values-aeo.yaml -- values to get the latest build
* xtreme/ the helm chart

typical install line

    helm install xtreme ./xtreme -f repos.yaml -f repos.yaml -f values-aeo.yaml 
