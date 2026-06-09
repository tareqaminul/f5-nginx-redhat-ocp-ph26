# Deployment Notes

## Secrets

- `nplus-license` (`nginx.com/license`) — your NGINX Plus JWT license. This is what `plus: true` consumes for runtime licensing. 
- `regcred` (`kubernetes.io/dockerconfigjson`) — registry pull credentials. This is your auth for `private-registry.nginx.com`, which is where the Plus + F5 WAF data-plane image and the two WAF sidecar images are pulled from. Keep — you'll reference it as an `imagePullSecret` in the new CR.
- `agent-tls` / `server-tls` (`kubernetes.io/tls`) — the NGF control↔data plane mTLS pair. 
- The three `*-dockercfg-*` secrets are OpenShift's automatic per-ServiceAccount registry tokens (builder/default/deployer SAs). Not NGF-related, system-managed.

### Images and Tags
```sh
# create and JWT env var
JWT=$(oc get secret nplus-license -n nginx-gateway -o jsonpath='{.data.license\.jwt}' | base64 -d)
# sanity check it's non-empty (don't echo the whole token)
echo "${#JWT} chars"
or
JWT="$(cat nginx-one-eval.jwt)"

# The WAF data plane image (what your CR will pull)
curl -s -u "${JWT}:" \
  "https://private-registry.nginx.com/v2/nginx-gateway-fabric/nginx-plus-f5waf/tags/list" | jq

# The plain Plus data plane (no WAF), for comparison
curl -s -u "${JWT}:" \
  "https://private-registry.nginx.com/v2/nginx-gateway-fabric/nginx-plus/tags/list" | jq

# Two more registry queries worth running, because the WAF integration pulls three images total (the data plane + two sidecars), and all three need to be pullable with the same regcred:

# The two WAF sidecars the chart injects when waf.enable=true
curl -s -u "${JWT}:" \
  "https://private-registry.nginx.com/v2/nap/waf-enforcer/tags/list" | jq

curl -s -u "${JWT}:" \
  "https://private-registry.nginx.com/v2/nap/waf-config-mgr/tags/list" | jq
```
