### Install Argocd from Helm

```sh
helm repo add argo https://argoproj.github.io/argo-helm
export KUBECONFIG=.kube/config
helm install -n argocd --create-namespace argocd argo/argo-cd --set server.service.type=NodePort --set server.service.nodePortHttps=30443

# Wypisanie hasła dla admin usera
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
```
