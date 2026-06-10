# OpenShift helpers

This directory contains OpenShift-specific resources 

| File | Purpose |
|---|---|
| `scc.yaml` | SecurityContextConstraints + binding so NGINX Ingress Controller pods can run (fixed UID 101 + `NET_BIND_SERVICE`). Without this the controller pod is never created on OpenShift. |

## Typical bring-up order on OpenShift

1. Install the **F5 NGINX Ingress Operator** from OperatorHub.
2. Create the controller namespace and the registry pull secret:
   ```bash
   oc new-project nginx-ingress
   oc create secret docker-registry regcred \
     --docker-server=private-registry.nginx.com \
     --docker-username=<JWT> --docker-password=none -n nginx-ingress
   ```
3. Apply the SCC **before** creating the `NginxIngress` CR:
   ```bash
   oc apply -f openshift/scc.yaml
   ```
4. Create the `NginxIngress` CR (NGINX Plus, UBI image, `serviceAccount.imagePullSecretName: regcred`).
5. Proceed with the examples/use-cases — all `oc` commands now work as written.
