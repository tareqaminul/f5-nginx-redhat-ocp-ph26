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
## Verify deployment - for F5 WAF for NGINX / NAP
Check `gateway-nginx` is **3/3 Running**, and the describe confirms the full WAF data plane assembled exactly as designed. 

The three containers, all verified by image digest:
- `nginx` → `nginx-plus-f5waf:2.6.3-ubi` — the Plus data plane with WAF compiled in.
- `waf-enforcer` → `nap/waf-enforcer:5.13.1` — the enforcement engine, listening on `ENFORCER_PORT 50000`.
- `waf-config-mgr` → `nap/waf-config-mgr:5.13.1` — the policy/config manager.

And the plumbing that proves it's wired, not just co-located: the shared `app-protect-bd-config`, `app-protect-config`, `app-protect-bundles`, and `app-protect-lock` volumes are mounted across the nginx + both sidecars — that's the IPC path the enforcer uses to inspect traffic and load bundles. The license mounted at `/etc/nginx/license.jwt` from `gateway-nginx-nplus-license` confirms Plus licensing resolved. Init container ran `--nginx-plus` and completed cleanly. Everything lines up.

If you see any scary-looking line at the bottom:

> Warning Unhealthy 112s (x2 over 113s) Readiness probe failed: ... connect: connection refused

Don't worry about it — read the **timeline**, not just the word "Warning." Those two failures happened at 112–113s ago, which maps to the exact moment `waf-config-mgr` (the last container) was still starting. The readiness probe hits nginx on `:8081/readyz`, and nginx holds readiness until its WAF sidecars are up and the config manager has finished initial sync. So nginx briefly reported "not ready" for ~1 second while the third container booted, the probe retried (`x2`), and then it passed — which is exactly why the pod is now `3/3 Ready` with `ContainersReady: True`. It's a startup-ordering blip during a staggered container launch, fully self-resolved. If it were still failing, you'd see recent events and the pod wouldn't be `3/3`. Both are clean.

## 
