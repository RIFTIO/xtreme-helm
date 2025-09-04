------------------------------
Explore Application Helm Chart
------------------------------

This helm chart starts explore backend server as individual pods.

Commands:
=========

Goto the parent directory for running the following commands for installation, debug and deletion.

1. debug chart and not install
    helm install explore-app --dry-run --debug explore-application/ 

2. install
    helm install -n explore-ui explore-app explore-application/ --debug

3. debug
    kubectl get all -n explore-ui

4. get ip and port of server
    export NODE_IP=$(kubectl get nodes --namespace explore-ui -o jsonpath="{.items[0].status.addresses[0].address}")
    export NODE_PORT=$(kubectl get svc --namespace explore-ui explore-app -o jsonpath="{.spec.ports[0].nodePort}")
    echo "URLs IP:Port - ${NODE_IP}:$NODE_PORT"

5. check if your helm chart is installed on K8s
    helm list -n explore-ui

6. Delete commands
    helm uninstall -n explore-ui explore-app
    kubectl delete --all pods -n explore-ui
    kubectl delete pod --field-selector=status.phase==Succeeded -n explore-ui
