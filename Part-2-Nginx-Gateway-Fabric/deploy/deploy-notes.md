# Deployment Notes

## Secrets

- `nplus-license` (`nginx.com/license`) — your NGINX Plus JWT license. This is what `plus: true` consumes for runtime licensing. 
- `regcred` (`kubernetes.io/dockerconfigjson`) — registry pull credentials. This is your auth for `private-registry.nginx.com`, which is where the Plus + F5 WAF data-plane image and the two WAF sidecar images are pulled from. Keep — you'll reference it as an `imagePullSecret` in the new CR.
- `agent-tls` / `server-tls` (`kubernetes.io/tls`) — the NGF control↔data plane mTLS pair. 
- The three `*-dockercfg-*` secrets are OpenShift's automatic per-ServiceAccount registry tokens (builder/default/deployer SAs). Not NGF-related, system-managed.

