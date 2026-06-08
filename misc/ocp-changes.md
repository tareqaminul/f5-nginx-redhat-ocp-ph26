# OCP Changes — OCP-NGINX-WS-PH26

This repository is an OpenShift-adapted fork of [`F5EMEA/oltra`](https://github.com/F5EMEA/oltra). This file lists every change made relative to the upstream repo and — just as importantly — the OpenShift-specific things you still need to do that a find-and-replace cannot handle.

## TL;DR

- All `kubectl` **commands** were rewritten to `oc` (494 occurrences across 64 files), plus 3 lines using the `k` shorthand.
- One string was deliberately **not** changed: the annotation key `kubectl.kubernetes.io/last-applied-configuration` (changing it would corrupt the resource).
- The command swap alone is **not enough to run on OpenShift.** The real work is SecurityContextConstraints (SCC), the missing `setup/` directory, and a few image/service caveats. Those are documented below and **must be reviewed manually**.

---

## 1. Mechanical change: `kubectl` → `oc`

`oc` is a superset of `kubectl`, so every command-line invocation translates 1:1 — same verbs, same flags, same resource names. No semantic change.

The replacement was done with a guarded expression so that `kubectl.kubernetes.io/...` annotation keys were preserved:

```
kubectl(?!\.kubernetes\.io)  ->  oc
```

The `k` shorthand (an alias the UDF lab pre-configures) was converted only when immediately followed by a kubectl verb, to avoid touching unrelated single-letter tokens:

```
k <verb>  ->  oc <verb>     # verb ∈ get|apply|delete|create|exec|describe|logs|...
```

### Preserved on purpose (do not change)

| File | String kept as-is | Why |
|---|---|---|
| `examples/app-protect/argocd/README.md` | `kubectl.kubernetes.io/last-applied-configuration` | This is a Kubernetes annotation key written by the API server, not a command. It is identical on OpenShift; renaming it would break the example output. |

---

## 2. What the command swap does NOT fix (review these manually)

These are the differences that actually matter when moving an NGINX/K8s lab to OpenShift. None of them can be done by text replacement.

### 2a. SecurityContextConstraints (SCC) — the big one

On OpenShift, the default `restricted-v2` SCC blocks the two things NGINX Ingress Controller needs: a fixed `runAsUser` (the image uses UID 101) and the `NET_BIND_SERVICE` capability for binding ports 80/443. Without an SCC granted to the controller's ServiceAccount, the pod is never created and you'll see:

```
unable to validate against any security context constraint:
... runAsUser: Invalid value: 101: must be in the ranges: [...]
```

A ready-to-use SCC and binding are provided in [`openshift/scc.yaml`](openshift/scc.yaml). Apply it and bind it to the `nginx-ingress` ServiceAccount (the name the NGINX operator forces):

```bash
oc apply -f openshift/scc.yaml
oc adm policy add-scc-to-user nginx-ingress-admin -z nginx-ingress -n nginx-ingress
```

If you install NGINX IC via the F5 NGINX Ingress Operator (recommended on OCP), the same SCC is published by F5 at:
`https://raw.githubusercontent.com/nginx/nginx-ingress-helm-operator/main/resources/scc.yaml`

### 2b. The `setup/` directory is NOT in this repo

Almost every lab references files under `~/oltra/setup/` (for example `~/oltra/setup/nginx-ic/...`, `~/oltra/setup/apps/apps.yml`, `~/oltra/setup/cis/...`). **That directory is not part of the upstream repo** — it is provisioned by the F5 UDF lab automation at deploy time. The same is true for this fork.

For an OpenShift run you must supply equivalents yourself:
- **NGINX IC install** — use the F5 NGINX Ingress Operator from OperatorHub (Helm-based, `charts.nginx.org/v1alpha1` `NginxIngress` CR) instead of the raw `setup/nginx-ic` manifests. Set `controller.nginxplus`, the private-registry image, `serviceAccount.imagePullSecretName`, and apply the SCC above.
- **Demo apps** (`setup/apps/*.yml`) — see the image caveat in 2c before applying.
- **CIS / BIG-IP** (`setup/cis`) — UDF-specific; out of scope for a generic OCP cluster.

### 2c. Demo app images that run as root / bind low ports

The labs use stock Docker Hub demo images:

- `nginxdemos/hello` and `nginxdemos/nginx-hello` — listen on port **80** and run as root by default.
- `balabit/syslog-ng:3.35.1` — used as the App Protect log sink; writes to the filesystem and binds 514.

Under `restricted-v2` these may fail with `CreateContainerError` or permission errors. Options, least-privilege first:
1. Use images that listen on a high port and run as an arbitrary UID (e.g. `nginxdemos/nginx-hello` can be fronted by a Service that maps 80→8080 if you switch the container to a non-privileged listener), **or**
2. Grant the demo namespace's default ServiceAccount the `anyuid` SCC (lab convenience, not for production):
   ```bash
   oc adm policy add-scc-to-user anyuid -z default -n <demo-namespace>
   ```

### 2d. Namespace creation verb

`kubectl create namespace <x>` was swapped to `oc create namespace <x>`, which works as-is. The OpenShift-idiomatic alternative is `oc new-project <x>`, which also creates the namespace **and** switches your current context to it. If a lab's later steps assume you are "in" the new namespace, prefer `oc new-project`. This was left as `oc create namespace` to preserve the upstream behavior exactly.

### 2e. Service type `LoadBalancer` (6 manifests) and `NodePort` (2)

These work on OpenShift only if a provider exists. On bare-metal/UDF you need **MetalLB** (or the OCP LB operator) for `LoadBalancer` to get an external IP; otherwise the service stays `<pending>`. If you have no LB, either install MetalLB or test via `oc port-forward`, e.g.:

```bash
oc port-forward -n nginx-ingress svc/<nginx-ingress-controller-svc> 8080:80
curl -H "Host: cafe.example.com" http://localhost:8080/
```

### 2f. Routes vs Ingress (optional)

The labs use Kubernetes `Ingress`/`VirtualServer`, which OpenShift supports natively through NGINX IC — no change required. If you'd rather expose apps with native OpenShift `Route` objects, that is an additive choice, not a necessary conversion. Note: OCP's built-in router may also try to admit an `Ingress`; because these examples set `ingressClassName: nginx`, NGINX remains the handler.

---

## 3. Per-file command-replacement counts

Number of `kubectl` → `oc` replacements per file (the 3 `k`-shorthand lines are in `K8s-fundamentals/Lab1.md` and `tls-passthrough/README.md`, already counted in their file's broader edits):

| File | `kubectl`→`oc` |
|---|---|
| `use-cases/workshops/K8s-fundamentals/Lab1.md` | 24 |
| `use-cases/two-tier-architectures/multi-cluster/README.md` | 22 |
| `examples/cis/crd/VirtualServer/TLS-Termination/README.md` | 22 |
| `use-cases/two-tier-architectures/edge-security/README.md` | 21 |
| `examples/cis/crd/VirtualServer/PolicyCRD/README.md` | 20 |
| `use-cases/two-tier-architectures/gitops/README.md` | 19 |
| `use-cases/two-tier-architectures/multi-tenancy/README.md` | 18 |
| `examples/cis/crd/serviceTypeLB/README.md` | 18 |
| `examples/cis/crd/IngressLink/README.md` | 17 |
| `use-cases/two-tier-architectures/layer-4/README.md` | 13 |
| `examples/cis/ingress/tls/README.md` | 13 |
| `examples/cis/crd/TransportServer/README.md` | 13 |
| `examples/nic/ingress-resources/app-protect-dos/README.md` | 12 |
| `examples/nic/custom-resources/app-protect-dos/README.md` | 11 |
| `examples/app-protect/path-based/README.md` | 11 |
| `examples/nic/custom-resources/cross-namespace-configuration/README.md` | 10 |
| `examples/cis/crd/VirtualServer/Wildcard/README.md` | 10 |
| `examples/app-protect/attacks/README.md` | 10 |
| `examples/nic/ingress-resources/auth-basic/README.md` | 9 |
| `examples/cis/crd/VirtualServer/Basic/README.md` | 9 |
| `examples/nic/ingress-resources/mergeable-ingress/README.md` | 8 |
| `examples/cis/ingress/rewrite/README.md` | 8 |
| `monitoring/app-protect/README.md` | 7 |
| `examples/cis/crd/VirtualServer/HostGroup/README.md` | 7 |
| `examples/cis/crd/ExternalDNS/README.md` | 7 |
| `examples/app-protect/basic/virtualserver/README.md` | 7 |
| `use-cases/workshops/K8s-fundamentals/Lab2.md` | 6 |
| `examples/nic/custom-resources/tls-passthrough/README.md` | 6 |
| `examples/nic/custom-resources/ingress-mtls/README.md` | 6 |
| `examples/nic/custom-resources/egress-mtls/README.md` | 6 |
| `examples/cis/crd/VirtualServer/Rewrite/README.md` | 6 |
| `examples/cis/crd/VirtualServer/IpamLabel/README.md` | 6 |
| `examples/app-protect/basic/ingress/README.md` | 6 |
| `examples/nic/custom-resources/tls/README.md` | 5 |
| `examples/nic/custom-resources/jwt/README.md` | 5 |
| `examples/nic/custom-resources/PENDING/certmanager-PENDING/README.md` | 5 |
| `examples/nic/custom-resources/PENDING/basic-auth-PENDING/README.md` | 5 |
| `examples/cis/crd/VirtualServer/httpTraffic/README.md` | 5 |
| `examples/nic/custom-resources/traffic-splitting/README.md` | 4 |
| `examples/nic/custom-resources/rate-limit/README.md` | 4 |
| `examples/nic/custom-resources/basic/README.md` | 4 |
| `examples/nic/custom-resources/advanced-routing/README.md` | 4 |
| `examples/nic/custom-resources/access-control/README.md` | 4 |
| `examples/cis/ingress/host-routing/README.md` | 4 |
| `examples/cis/ingress/health-monitor/README.md` | 4 |
| `examples/cis/ingress/fanout/README.md` | 4 |
| `examples/cis/ingress/basic-ingress/README.md` | 4 |
| `examples/cis/crd/VirtualServer/IPv6/README.md` | 4 |
| `use-cases/workshops/K8s-fundamentals/Lab3.md` | 3 |
| `use-cases/workshops/K8s-fundamentals/Lab2.1.md` | 3 |
| `monitoring/nginx/README.md` | 3 |
| `monitoring/bigip/README.md` | 3 |
| `examples/nic/ingress-resources/tls/README.md` | 3 |
| `examples/nic/ingress-resources/basic/README.md` | 3 |
| `examples/cis/crd/VirtualServer/Service-address/README.md` | 3 |
| `examples/cis/crd/VirtualServer/HealthMonitor/README.md` | 3 |
| `examples/cis/crd/VirtualServer/CustomPort/README.md` | 3 |
| `examples/app-protect/argocd/README.md` | 3 |
| `examples/nic/ingress-resources/persistence/README.md` | 2 |
| `examples/nic/ingress-resources/path-based/README.md` | 2 |
| `examples/nic/ingress-resources/externalname/README.md` | 2 |
| `examples/cis/ingress/README.md` | 2 |
| `examples/cis/crd/VirtualServer/README.md` | 2 |
| `examples/nic/custom-resources/rewrite/README.md` | 1 |

**Total: 494 `kubectl` → `oc` replacements across 64 files, + 3 `k`-shorthand lines.**

---

## 4. What was left untouched

- All YAML resource specs, CRDs, NGINX `VirtualServer`/`Policy`/`APPolicy` definitions, images, and lab logic are byte-for-byte identical to upstream except for the command swap above.
- Documentation images (`*.png`, `*.gif`) and the `LICENSE` are unchanged.
- Upstream attribution and the original `README.md` body are retained; an OpenShift banner was prepended pointing here.

## 5. Provenance

- Upstream: `https://github.com/F5EMEA/oltra` (branch `main`)
- Adapted: 2026-06-08 — renamed to `OCP-NGINX-WS-PH26`, git history reset to a fresh initial commit.
