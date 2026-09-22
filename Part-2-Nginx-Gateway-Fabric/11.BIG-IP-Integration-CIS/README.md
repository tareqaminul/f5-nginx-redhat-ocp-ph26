# Lab 11: GatewayLink — Fronting a Gateway with F5 BIG-IP

In many cases, external load balancers, such as, F5 BIG-IP fronts the Kubernetes/OpenShift Clusters. The NGINX Gateway Fabric CRD `ExternalLoadBalancer` declares the
external load balancer, and F5 Container Ingress Services (CIS) provisions the BIG-IP virtual
server that fronts the data plane Service — no NodePort exposed to clients, no cloud LoadBalancer.

By the end of this lab, external clients reach `cafe.example.com/coffee` through a BIG-IP virtual server
whose pool members are the NGINX data plane pods, with the real client IP preserved end to end, all
declared from Kubernetes.

![GatewayLink flow: an ExternalLoadBalancer targets a Gateway and an NginxProxy sets the data plane to NodePort with PROXY protocol; NGF emits an IngressLink that F5 CIS compiles into an AS3 declaration, provisioning a BIG-IP virtual server whose pool members are the NGINX data plane Service](image/topology-flow.svg)

*Blue = Gateway API / NGF resources · Amber = NGINX data plane · Teal = F5 CIS controller · Green = resulting traffic path.*

---

## Table of contents

- [What you will learn](#what-you-will-learn)
- [How GatewayLink works in NGINX Gateway Fabric](#how-gatewaylink-works-in-nginx-gateway-fabric)
- [Prerequisites](#prerequisites)
  - [Enable the feature flag in the right order](#-enable-the-feature-flag-in-the-right-order)
  - [Part A — Prepare the BIG-IP](#part-a--prepare-the-big-ip)
  - [Part B — Install the F5 IPAM Controller](#part-b--install-the-f5-ipam-controller-optional)
  - [Part C — Install F5 Container Ingress Services](#part-c--install-f5-container-ingress-services)
  - [Part D — Enable the NGF flag](#part-d--enable-the-ngf-flag)
- [Lab environment notes](#lab-environment-notes)
- [Step 1 — Deploy the sample application](#step-1--deploy-the-sample-application)
- [Step 2 — Configure the data plane](#step-2--configure-the-data-plane)
- [Step 3 — Create the Gateway](#step-3--create-the-gateway)
- [Step 4 — Publish the route](#step-4--publish-the-route)
- [Step 5 — Declare the ExternalLoadBalancer](#step-5--declare-the-externalloadbalancer)
- [Step 6 — Verify the BIG-IP virtual server](#step-6--verify-the-big-ip-virtual-server)
- [Validation rules, confirmed](#validation-rules-confirmed)
- [Troubleshooting](#troubleshooting)
- [Optional configuration](#optional-configuration)
- [Going further — multi-cluster load balancing](#going-further--multi-cluster-load-balancing)
- [Cleanup](#cleanup)

---

## What you will learn

- How NGF delegates external load balancer provisioning instead of implementing it — the division of labor between NGF, CIS, the IPAM controller, and AS3
- Why the `NginxProxy` in this lab is **not optional**, and the two distinct failures you get without it
- Why `ExternalLoadBalancer` maps strictly one-to-one with a Gateway, and what happens when two target the same one
- The `virtualServerAddress` vs. `ipamLabel` choice — static addressing vs. delegated IPAM
- Why `partition` is immutable once set, and why `Common` is rejected
- How PROXY protocol preserves the client IP across a full-proxy BIG-IP, and why it silently fails when only half of it is configured

---

## How GatewayLink works in NGINX Gateway Fabric

NGF never talks to BIG-IP. It writes an intermediate resource that F5 CIS already knows how to consume, and
CIS does the device programming:

```
  ExternalLoadBalancer      NGF Controller        F5 IPAM        F5 CIS            BIG-IP
         |                        |                  |             |                  |
         |  1. applied            |                  |             |                  |
         |----------------------->|                  |             |                  |
         |                        |  2. emits IngressLink           |                  |
         |                        |    (named after the DATA        |                  |
         |                        |     PLANE SERVICE)              |                  |
         |                        |-------------------------------->|                  |
         |                        |                  |             |                  |
         |                        |   3. allocates address          |                  |
         |                        |      (only if ipamLabel set)    |                  |
         |                        |<---------------->|             |                  |
         |                        |                  |             |                  |
         |                        |                  |  4. reads node IPs + NodePorts, |
         |                        |                  |     compiles an AS3 declaration |
         |                        |                  |             |----------------->|
         |                        |                  |             |  create VS + pool |
         |                        |                  |             |                  |
         |  5. Accepted condition on the ExternalLoadBalancer       |                  |
         |<-----------------------|                  |             |                  |
```

Steps 4 repeats whenever endpoints or the IngressLink spec change, which is what keeps the BIG-IP pool in
sync as data plane pods come and go.

**The IngressLink is named after the data plane Service, not after your `ExternalLoadBalancer`.** A Gateway
called `gateway` produces a Service called `gateway-nginx`, so the IngressLink is `gateway-nginx` — even
though the `ExternalLoadBalancer` in this lab is called `gateway-bigip-link`. Every verification command
below uses the Service-derived name.

**One Gateway yields exactly one data plane Service, so it gets exactly one external load balancer.** If
two `ExternalLoadBalancer` resources reference the same Gateway, the **oldest is accepted and the rest are
rejected** with `Accepted=False`, `Reason: Conflicted` — deterministic, not first-writer-wins-at-random,
which matters when GitOps reapplies resources in arbitrary order.

**CIS pool members come from the data plane Service, selected by label.** NGF sets the IngressLink's
`selector` internally and it cannot be overridden — including through `additionalIngressLinkSpec`, the
escape hatch — because overriding it would sever the link between the virtual server and the Gateway it is
supposed to front.

---

## Prerequisites

| Requirement | Version / notes |
|---|---|
| Kubernetes cluster | With network reachability from the cluster to the BIG-IP management interface, and from the BIG-IP to the cluster nodes |
| NGINX Gateway Fabric | **2.7.0+** — `ExternalLoadBalancer` was introduced in 2.7.0 |
| F5 BIG-IP | **17.1.0.3 or later**, with admin credentials |
| BIG-IP AS3 extension | Installed on the device — CIS programs BIG-IP exclusively through AS3 declarations |
| BIG-IP partition | Must exist before first apply, and must **not** be `Common` |
| **F5 Container Ingress Services** | **Install this BEFORE enabling the NGF flag** — see the ordering warning |
| F5 IPAM Controller | **0.1.13** — only needed if you use `ipamLabel` instead of a static address |
| NGF installed with `nginxGateway.externalLoadBalancer.enable=true` | Off by default. **Do not enable it until the CIS CRDs exist.** |
| `kubectl`, `helm`, `curl`, `python3` | `python3` only for pretty-printing iControl REST output |

### ⚠️ Enable the feature flag in the right order

`nginxGateway.externalLoadBalancer.enable=true` makes the NGF **control plane** start a watch on
`IngressLink.cis.f5.com/v1` — a CRD owned by F5 Container Ingress Services, not by NGF. If that CRD is
absent, the informer cache never syncs and the controller **terminates after roughly 60 seconds**:

```
failed to start control loop: failed to wait for provisioner-IngressLink caches to sync
kind source: *unstructured.Unstructured[cis.f5.com/v1 IngressLink]:
timed out waiting for cache to be synced
```

The pod then enters `CrashLoopBackOff` and restarts indefinitely.

This is **not** scoped to this lab. A crashing control plane stops reconciling *every* Gateway in the
cluster — unrelated Gateways keep serving traffic from their existing data plane config, but no new config
is pushed and no status is updated. Enabling this flag speculatively, "to have it ready", takes out the
whole control plane on any cluster without CIS.

**Correct order: A → B → C → D below.** Work through them in order; each is collapsed, expand as you go.

---

<details>
<summary><b>Part A — Prepare the BIG-IP</b> (AS3, partition, PROXY protocol iRule)</summary>

<br>

Set the connection details once. Everything in Parts A–C uses them.

```shell
export BIGIP_ADDRESS="192.0.2.10:443"          # <-- your BIG-IP management address:port
export BIGIP_USERNAME="admin"
export BIGIP_PASSWORD="<your-password>"
export BIGIP_PARTITION="k8s"
export IPAM_ADDRESS_RANGE="192.0.2.100-192.0.2.110"   # only needed for Part B
```

> Exporting a password puts it in your shell history. In a shared or recorded lab environment, read it
> with `read -rs BIGIP_PASSWORD` instead.

**A1. Install the AS3 extension.** CIS configures BIG-IP *only* through AS3 declarations, so without it
nothing this lab does reaches the device. Follow F5's documentation to download and install the AS3 RPM.

Confirm it is serving — a 404 here is the single most common cause of a `CrashLoopBackOff` in CIS later:

```shell
curl -sku "$BIGIP_USERNAME:$BIGIP_PASSWORD" \
  "https://$BIGIP_ADDRESS/mgmt/shared/appsvcs/info" | python3 -m json.tool
```

```
{
    "version": "3.52.0",
    "release": "5",
    "schemaCurrent": "3.52.0",
    "schemaMinimum": "3.0.0"
}
```

**A2. Create the partition.** CIS owns everything inside it, so give it a dedicated one — this is what
makes the integration safely reversible. `Common` is rejected by the CRD precisely to stop CIS from taking
ownership of shared device configuration.

```shell
curl -sku "$BIGIP_USERNAME:$BIGIP_PASSWORD" -X POST \
  "https://$BIGIP_ADDRESS/mgmt/tm/auth/partition" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"$BIGIP_PARTITION\"}"
```

Verify:

```shell
curl -sku "$BIGIP_USERNAME:$BIGIP_PASSWORD" \
  "https://$BIGIP_ADDRESS/mgmt/tm/auth/partition" | grep -o "\"name\":\"[^\"]*\""
```

**A3. Create the PROXY protocol iRule.** BIG-IP is a full proxy — it opens its own TCP connection to
NGINX, so by default NGINX sees the BIG-IP self-IP as the client for every single request. This iRule
prepends a PROXY protocol v1 header carrying the original client address:

```shell
curl -sku "$BIGIP_USERNAME:$BIGIP_PASSWORD" -X POST "https://$BIGIP_ADDRESS/mgmt/tm/ltm/rule" \
  -H "Content-Type: application/json" -d '{
    "name": "Proxy_Protocol_iRule",
    "apiAnonymous": "when SERVER_CONNECTED {\n  TCP::respond \"PROXY TCP[IP::version] [IP::client_addr] [clientside {IP::local_addr}] [TCP::client_port] [clientside {TCP::local_port}]\\r\\n\"\n}"
  }'
```

Verify it exists:

```shell
curl -sku "$BIGIP_USERNAME:$BIGIP_PASSWORD" \
  "https://$BIGIP_ADDRESS/mgmt/tm/ltm/rule/~Common~Proxy_Protocol_iRule" | python3 -m json.tool | head -5
```

> **This is only half of the setup.** The matching `rewriteClientIP` block in `1.nginxproxy.yaml` is the
> other half. Configure either one alone and there is **no error anywhere** — requests succeed, and the
> access log quietly shows an internal address. See the troubleshooting table.

</details>

<details>
<summary><b>Part B — Install the F5 IPAM Controller</b> (optional — only for <code>ipamLabel</code>)</summary>

<br>

Skip this entirely if you are using a static `virtualServerAddress`, which is what
`4.externalloadbalancer.yaml` does by default. Install it when you want a pool of addresses allocated on
demand instead of an IP hardcoded in a manifest.

**B1. Install the IPAM CRD:**

```shell
kubectl apply -f - <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: ipams.fic.f5.com
spec:
  group: fic.f5.com
  names:
    kind: IPAM
    listKind: IPAMList
    plural: ipams
    singular: ipam
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      subresources:
        status: {}
      schema:
        openAPIV3Schema:
          type: object
          x-kubernetes-preserve-unknown-fields: true
          properties:
            spec:
              type: object
              x-kubernetes-preserve-unknown-fields: true
            status:
              type: object
              x-kubernetes-preserve-unknown-fields: true
EOF
```

**B2. Install the controller.** The key setting is `args.ip_range`, a map of **pool name → address range**.
The pool name on the left is what an `ExternalLoadBalancer` later references as `ipamLabel`:

```shell
helm repo add f5-ipam-stable https://f5networks.github.io/f5-ipam-controller/helm-charts/stable --force-update
helm repo update

helm install f5-ipam-controller f5-ipam-stable/f5-ipam-controller \
  --namespace kube-system \
  --set image.version=0.1.13 \
  --set namespace=kube-system \
  --set rbac.create=true \
  --set serviceAccount.create=true \
  --set args.log_level=DEBUG \
  --set pvc.create=true \
  --set pvc.storage=100Mi \
  --set-string 'args.ip_range=\{"production":"'"$IPAM_ADDRESS_RANGE"'"\}' \
  --wait
```

> The `--set-string` value is genuinely awkward: the braces are escaped so Helm treats the JSON map as a
> string rather than parsing it as a list, and the quoting alternates so `$IPAM_ADDRESS_RANGE` still
> expands. Copy it as-is and change only the variable.

**B3. Verify** the pool registered — this is the value you must match with `ipamLabel`:

```shell
kubectl logs -n kube-system -l app=f5-ipam-controller --tail=20 | grep -i "ip_range\|provider"
```

`pvc.create=true` matters: the controller persists its allocations, so a restart does not hand out an
address that is already in use.

</details>

<details>
<summary><b>Part C — Install F5 Container Ingress Services</b> (this creates the <code>IngressLink</code> CRD)</summary>

<br>

**C1. Install the CIS custom resource definitions first.** This step is what creates
`ingresslinks.cis.f5.com` — the CRD NGF's watch depends on, and therefore the gate on Part D:

```shell
kubectl apply -f https://raw.githubusercontent.com/F5Networks/k8s-bigip-ctlr/master/docs/config_examples/customResourceDefinitions/incubator/customresourcedefinitions.yml
```

Confirm — do not continue until this returns a row:

```shell
kubectl get crd ingresslinks.cis.f5.com
```

```
NAME                        CREATED AT
ingresslinks.cis.f5.com     2026-09-06T11:02:44Z
```

**C2. Install the controller:**

```shell
helm repo add f5-stable https://f5networks.github.io/charts/stable
helm repo update

helm install f5-cis f5-stable/f5-bigip-ctlr -n kube-system \
  --set bigip_secret.create=true \
  --set bigip_secret.username="$BIGIP_USERNAME" \
  --set bigip_secret.password="$BIGIP_PASSWORD" \
  --set rbac.create=true \
  --set serviceAccount.create=true \
  --set namespace=kube-system \
  --set args.bigip_url="$BIGIP_ADDRESS" \
  --set args.bigip_partition="$BIGIP_PARTITION" \
  --set args.pool_member_type=nodeport \
  --set args.custom_resource_mode=true \
  --set args.insecure=true \
  --set args.log_level=DEBUG \
  --set args.log-as3-response=true \
  --set args.ipam=true
```

Three of those arguments decide whether this lab works at all:

| Argument | Why it matters here |
|---|---|
| `args.pool_member_type=nodeport` | Pool members are built from node IP + nodePort. This is why `1.nginxproxy.yaml` sets the data plane Service to `NodePort`. **Mismatch these two and the BIG-IP pool comes out empty.** |
| `args.custom_resource_mode=true` | Makes CIS watch `IngressLink` and the other `cis.f5.com` CRDs. Without it CIS runs in Ingress mode and ignores everything NGF emits. |
| `args.ipam=true` | Required only for `ipamLabel`. Harmless when using a static address. |

`args.insecure=true` skips verification of the BIG-IP's management certificate. Fine for a lab; replace it
with a trusted CA bundle anywhere else.

**C3. Verify CIS reached the device.** A successful `authn/login` is the check that credentials, address,
and reachability are all correct:

```shell
kubectl logs -n kube-system deploy/f5-cis-f5-bigip-ctlr | grep -E "authn/login|AS3"
kubectl get pods -n kube-system -l app=f5-cis-f5-bigip-ctlr
```

If the pod is in `CrashLoopBackOff` with `[ERROR] AS3 RPM is not installed on BIGIP`, revisit step A1 —
CIS returns this on a 404 from the AS3 endpoint. Restart the pod after fixing it:

```shell
kubectl delete pod -n kube-system -l app=f5-cis-f5-bigip-ctlr
```

</details>

<details>
<summary><b>Part D — Enable the NGF flag</b> (only after Part C succeeds)</summary>

<br>

**D1. Re-confirm the gate.** This must return a row before you go any further:

```shell
kubectl get crd ingresslinks.cis.f5.com
kubectl get pods -n kube-system -l app=f5-cis-f5-bigip-ctlr
```

**D2. Enable the flag:**

```shell
helm upgrade ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --version 2.7.0 --reuse-values \
  --set nginxGateway.externalLoadBalancer.enable=true \
  -n nginx-gateway --wait
```

**D3. Confirm the flag actually rendered.** Helm silently ignores values a chart does not define, so a
chart older than 2.7.0 renders a Deployment with no flag and no error:

```shell
kubectl get deploy -n nginx-gateway ngf-nginx-gateway-fabric \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="nginx-gateway")].args}' | tr ',' '\n'
```

You should see `--external-load-balancer` in the list.

**D4. Confirm the control plane is stable — and wait.** `--wait` returns as soon as the pod is `Ready`,
but the cache-sync failure takes about 60 seconds. A pod reading `Running` immediately after the upgrade
proves nothing. Watch the restart count for two full minutes:

```shell
kubectl get pods -n nginx-gateway -w \
  -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount'
```

```
NAME                                       READY   RESTARTS
ngf-nginx-gateway-fabric-cf68b7fcb-xlx8h   true    0
```

`RESTARTS` climbing off `0` means the watch failed — roll straight back:

```shell
helm upgrade ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --version 2.7.0 --reuse-values \
  --set nginxGateway.externalLoadBalancer.enable=false \
  -n nginx-gateway --wait
```

</details>

---

## Lab environment notes

Replace both placeholders in `4.externalloadbalancer.yaml` before applying. They are deliberately written
so the CRD **rejects them** rather than letting a half-configured resource through:

| Placeholder | Notes |
|---|---|
| `<BIGIP_VIRTUAL_SERVER_IP>` | A free IP the BIG-IP can serve. Delete this line and uncomment `ipamLabel` instead if the IPAM controller from Part B should allocate it. |
| `<BIGIP_PARTITION>` | Must already exist on the BIG-IP (Part A2) **and match the `args.bigip_partition` CIS was installed with** (Part C2). `Common` is rejected by the CRD. |

One setting in `1.nginxproxy.yaml` is safe for a lab and wrong for production: `trustedAddresses` is
`0.0.0.0/0`, which trusts a PROXY protocol header from any source — a client-IP spoofing path. Narrow it to
the subnet the BIG-IP sends traffic from.

---

## Step 1 — Deploy the sample application

```shell
cd ~/NGINX-Gateway-Fabric-Lab/labs/labs-on-test/lab.t.2.gatewaylink-bigip
kubectl apply -f 0.apps.yaml
```

**Verify** — two replicas `Running` (two pool members makes the BIG-IP pool more interesting):

```shell
kubectl get pods -l app=coffee
```

```
NAME                      READY   STATUS    RESTARTS   AGE
coffee-654ddf664b-9zx2q   1/1     Running   0          6s
coffee-654ddf664b-lm4tv   1/1     Running   0          6s
```

---

## Step 2 — Configure the data plane

This is the step most easily skipped, and skipping it produces a virtual server that exists but does not
work. `1.nginxproxy.yaml` sets three things the BIG-IP integration depends on: a `NodePort` Service (so CIS
can build pool members), an exposed readiness probe (so CIS can health check them), and PROXY protocol
client IP rewriting (so the real client address survives the full proxy).

```shell
kubectl apply -f 1.nginxproxy.yaml
```

**Verify**:

```shell
kubectl get nginxproxy gatewaylink-proxy
```

```
NAME                AGE
gatewaylink-proxy   2s
```

Nothing takes effect yet — an `NginxProxy` does nothing until a Gateway references it, which is the next
step.

---

## Step 3 — Create the Gateway

```shell
kubectl apply -f 2.gateway.yaml
```

**Verify** the Gateway is programmed **and** that the `NginxProxy` was actually applied — the Service type
is the observable proof that `parametersRef` resolved:

```shell
kubectl get gateway gateway
kubectl get svc gateway-nginx
```

```
NAME      CLASS   ADDRESS          PROGRAMMED   AGE
gateway   nginx   10.104.194.212   True         18s

NAME            TYPE       CLUSTER-IP       EXTERNAL-IP   PORT(S)        AGE
gateway-nginx   NodePort   10.104.194.212   <none>        80:31274/TCP   18s
```

> `TYPE` showing `ClusterIP` instead of `NodePort` means the `parametersRef` did not resolve — most often a
> name typo, or the `NginxProxy` sitting in a different namespace from the Gateway. Fix it before
> continuing; CIS would otherwise build an empty pool.

Confirm the PROXY protocol side landed in the generated config too:

```shell
POD=$(kubectl get pod -l gateway.networking.k8s.io/gateway-name=gateway -o name | head -1)
kubectl exec ${POD#pod/} -c nginx -- grep -E "set_real_ip_from|proxy_protocol" /etc/nginx/conf.d/http.conf
```

```
set_real_ip_from 0.0.0.0/0;
real_ip_header proxy_protocol;
listen 80 proxy_protocol default_server;
```

---

## Step 4 — Publish the route

```shell
kubectl apply -f 3.routes.yaml
```

**Verify**:

```shell
kubectl get httproute coffee
```

```
NAME     HOSTNAMES              AGE
coffee   ["cafe.example.com"]   3s
```

---

## Step 5 — Declare the ExternalLoadBalancer

```shell
kubectl apply -f 4.externalloadbalancer.yaml
```

**Verify** — accepted. Note that the status is nested under `Controllers`, one entry per controller that
processed the resource, not a bare `Conditions` list:

```shell
kubectl describe externalloadbalancer gateway-bigip-link
```

```
Name:         gateway-bigip-link
Namespace:    default
API Version:  gateway.nginx.org/v1alpha1
Kind:         ExternalLoadBalancer
Spec:
  Gateway Link:
    Host:        cafe.example.com
    I Rules:
      /Common/Proxy_Protocol_iRule
    Partition:               k8s
    Virtual Server Address:  10.10.20.55
    Virtual Server Name:     ngf-gateway-vs
  Target Refs:
    Group:  gateway.networking.k8s.io
    Kind:   Gateway
    Name:   gateway
Status:
  Controllers:
    Controller Name:  gateway.nginx.org/nginx-gateway-controller
    Conditions:
      Last Transition Time:  2026-09-06T11:14:03Z
      Message:               ExternalLoadBalancer is accepted
      Observed Generation:   1
      Reason:                Accepted
      Status:                True
      Type:                  Accepted
Events:                      <none>
```

> `Reason: Conflicted` instead means another `ExternalLoadBalancer` already targets this Gateway. The
> oldest wins; delete it before this one is accepted. `Reason: Invalid` means the resource passed CEL
> validation but failed a check NGF performs itself — the message names the field.

**Then confirm NGF emitted the IngressLink** — remember it is named after the data plane Service:

```shell
kubectl get ingresslink gateway-nginx
kubectl get ingresslink gateway-nginx -o jsonpath='{.spec}' | python3 -m json.tool
```

An IngressLink with **no `status`** has not been processed by CIS yet. Give it up to two minutes before
digging into logs — this is expected, not a failure.

If you used `ipamLabel`, this is where the address appears:

```shell
export ALLOCATED_ADDRESS=$(kubectl get ingresslink gateway-nginx -o jsonpath='{.status.vsAddress}')
echo "$ALLOCATED_ADDRESS"
```

---

## Step 6 — Verify the BIG-IP virtual server

Confirm CIS pushed a declaration and BIG-IP accepted it:

```shell
kubectl logs -n kube-system deploy/f5-cis-f5-bigip-ctlr --tail=50 | grep -E "AS3\]\[POST\]|response:"
```

List what actually exists on the device — the virtual server should be in your partition, not `Common`:

```shell
curl -sku "$BIGIP_USERNAME:$BIGIP_PASSWORD" "https://$BIGIP_ADDRESS/mgmt/tm/ltm/virtual" \
  | python3 -c 'import sys,json
for v in json.load(sys.stdin)["items"]:
    print(v["fullPath"], "->", v.get("rules", "no rules"))'
```

```
/k8s/Shared/ngf-gateway-vs -> ['/Common/Proxy_Protocol_iRule']
```

> No `rules` on the virtual server means the iRule was not attached, and client IPs will be wrong. Check
> the `iRules` entry in `4.externalloadbalancer.yaml` uses the full `/partition/name` path — a bare name is
> rejected by the CRD, but a path pointing at a non-existent iRule is accepted here and fails at the device.

Now reach the application through the BIG-IP VIP rather than a NodePort:

```shell
curl -i --resolve cafe.example.com:80:<BIGIP_VIRTUAL_SERVER_IP> \
  http://cafe.example.com/coffee
```

```
HTTP/1.1 200 OK
Server: nginx
Date: Sun, 06 Sep 2026 11:22:41 GMT
Content-Type: text/plain
Content-Length: 162
Connection: keep-alive

Server address: 10.0.156.109:8080
Server name: coffee-654ddf664b-9zx2q
Date: 06/Sep/2026:11:22:41 +0000
URI: /coffee
Request ID: 4c8e2a19f7b03d6e5a1c9048f2b7e36d
```

**Verify load distribution** — repeated requests should reach both data plane pods, which in turn reach
both coffee pods:

```shell
for i in $(seq 1 10); do
  curl -s --resolve cafe.example.com:80:<BIGIP_VIRTUAL_SERVER_IP> \
    http://cafe.example.com/coffee | grep "Server name"
done | sort | uniq -c
```

**Verify the client IP survived** — this is the payoff for Part A3 plus `1.nginxproxy.yaml`, and the one
check that proves both halves of the PROXY protocol setup are in place:

```shell
POD=$(kubectl get pod -l gateway.networking.k8s.io/gateway-name=gateway -o name | head -1)
kubectl logs ${POD#pod/} -c nginx | grep coffee | tail -1
```

The leading address should be **your workstation's IP**, not a BIG-IP self-IP or a node address. If it is
an internal address, see the troubleshooting table — the request still succeeded, so nothing else will tell
you this is broken.

---

## Validation rules, confirmed

Every rule below was triggered against a live NGF 2.7.0 cluster and the message captured verbatim, so you
can match what you see exactly:

| What you do | What the API server returns |
|---|---|
| Leave `<BIGIP_VIRTUAL_SERVER_IP>` unreplaced | `spec.gatewayLink.virtualServerAddress: Invalid value: "<BIGIP_VIRTUAL_SERVER_IP>": ... should match '^(([0-9]\|[1-9][0-9]\|...` |
| Set `partition: Common` | `spec.gatewayLink: Invalid value: "object": partition cannot be Common` |
| Set both `virtualServerAddress` and `ipamLabel` | `spec.gatewayLink: Invalid value: "object": virtualServerAddress and ipamLabel are mutually exclusive` |
| Set neither | `spec.gatewayLink: Invalid value: "object": one of virtualServerAddress or ipamLabel must be set` |
| Use a bare iRule name (`Proxy_Protocol_iRule`) | `spec.gatewayLink.iRules[0]: Invalid value: "Proxy_Protocol_iRule": ... should match '^\/[a-zA-Z]+...` |
| Change `partition` on an existing resource | `partition cannot be modified; delete the resource and recreate it with the new partition` |

Try them yourself without touching anything real — server-side dry run validates against the live CRDs but
writes nothing:

```shell
kubectl apply --dry-run=server -f 4.externalloadbalancer.yaml
```

---

## Troubleshooting

| Symptom | Cause | Resolution |
|---|---|---|
| **NGF control plane in `CrashLoopBackOff`; logs end with `failed to wait for provisioner-IngressLink caches to sync`** | **`externalLoadBalancer.enable=true` while the `IngressLink` CRD is absent — CIS not installed** | **Install CIS first (Part C), or disable the flag: `helm upgrade ngf ... --reuse-values --set nginxGateway.externalLoadBalancer.enable=false`. Confirmed on NGF 2.7.0.** |
| Control plane looked healthy, then started restarting ~1 min later | Same as above — the cache-sync timeout is not immediate | Check `restartCount`, not just `Running`, when validating this flag |
| **No IngressLink is created at all** | The `--external-load-balancer` flag never rendered — Helm ignores values a chart does not define, so an older chart produces no flag and no error | `kubectl get deploy -n nginx-gateway ngf-nginx-gateway-fabric -o jsonpath='{.spec.template.spec.containers[?(@.name=="nginx-gateway")].args}'` |
| IngressLink exists but has **no `status`** | CIS writes that field; absent means not yet processed | Wait up to two minutes, then `kubectl logs -n kube-system deploy/f5-cis-f5-bigip-ctlr` |
| Looking for an IngressLink named after the `ExternalLoadBalancer` | It is named after the **data plane Service** | `kubectl get ingresslink gateway-nginx`, not `gateway-bigip-link` |
| **The BIG-IP pool is empty** | Service type does not match the CIS `pool_member_type`, or the listener is not programmed | `kubectl get svc gateway-nginx -o jsonpath='{.spec.type}{"\n"}{.spec.ports}'` — must be `NodePort` for `pool_member_type=nodeport`. Also `kubectl describe gateway gateway`: an HTTPS listener with a missing or invalid `certificateRefs` Secret stays unprogrammed, so its port is never exposed on the Service |
| **NGINX logs show an internal address as the client** | Only one half of the PROXY protocol setup is in place, or the header source is untrusted. NGINX checks the trust list against **both** the connection address and the address inside the header, and **discards the header silently** if either fails | Confirm the iRule is attached to the virtual server (Step 6), then `kubectl exec $POD -c nginx -- grep set_real_ip_from /etc/nginx/conf.d/http.conf` and widen/correct `trustedAddresses` in `1.nginxproxy.yaml` |
| **No address allocated** with `ipamLabel` | CIS missing `args.ipam=true`, or the label does not match a pool name | `kubectl logs -n kube-system -l app=f5-ipam-controller --tail=20` — a mismatch reads `[PROV] IPAM LABEL: <label> Not Found`. The label must equal a key in the controller's `ip_range` map |
| **AS3 declaration rejected** | Partition missing, or a referenced BIG-IP object (iRule, SSL profile, monitor) does not exist | `kubectl logs -n kube-system deploy/f5-cis-f5-bigip-ctlr \| grep -E "AS3\]\[POST\]\|response:"` — the BIG-IP response names the offending object |
| CIS pod `CrashLoopBackOff`, logs `[ERROR] AS3 RPM is not installed on BIGIP` | AS3 not installed or not serving (404) | Install AS3 (Part A1), then `kubectl delete pod -n kube-system -l app=f5-cis-f5-bigip-ctlr` |
| **A field you set has no effect and no error** | Kubernetes silently drops fields absent from the CRD schema — a CIS CRD older than the NGF release will not have the newer IngressLink fields | `kubectl get crd ingresslinks.cis.f5.com -o yaml \| grep -A5 <field>`, then `kubectl logs -n nginx-gateway deploy/ngf-nginx-gateway-fabric \| grep "unknown field"`. Also inspect what NGF actually wrote: `kubectl get ingresslink gateway-nginx -o jsonpath='{.spec}' \| python3 -m json.tool` |
| `ExternalLoadBalancer` status `Conflicted` | Another one already targets this Gateway | Delete the older resource; oldest-wins is deterministic |
| Rejected on update: "partition cannot be modified" | Changed `partition` in place | Delete and recreate the resource |
| Data plane Service is `ClusterIP` despite `1.nginxproxy.yaml` | `parametersRef` did not resolve — wrong name, or `NginxProxy` in a different namespace from the Gateway | The `NginxProxy` is resolved from the **Gateway's own namespace**. `kubectl describe gateway gateway` and check the conditions |
| VIP answers but returns 502 | Pool members unhealthy or wrong Service targeted | `kubectl get endpointslices -l kubernetes.io/service-name=gateway-nginx`, and check the readiness probe is exposed |

Useful commands:

```shell
kubectl get externalloadbalancer -o wide
kubectl get ingresslink -A
kubectl logs -n nginx-gateway deploy/ngf-nginx-gateway-fabric -c nginx-gateway --tail=50
kubectl logs -n kube-system deploy/f5-cis-f5-bigip-ctlr --tail=50
kubectl logs -n kube-system -l app=f5-ipam-controller --tail=50
```

---

## Optional configuration

Fields on `spec.gatewayLink` beyond what this lab uses:

| Field | Purpose |
|---|---|
| `ipamLabel` | Delegate IP allocation to the F5 IPAM Controller instead of a static address. Must match a pool name in the controller's `ip_range` map |
| `virtualServerName` | Custom BIG-IP virtual server name instead of a generated one |
| `host` | Hostname for the virtual server |
| `partition` | BIG-IP partition; must exist, cannot be `Common`, **immutable after creation** |
| `bigipRouteDomain` | Route domain ID (0–65535) for the virtual server |
| `iRules` | BIG-IP iRules to attach, each as a full `/partition/name` path |
| `monitors` | Health monitors for the pool — `{name: /Common/http, reference: bigip}`. `reference` currently only accepts `bigip` |
| `tls.reference` | Where SSL profiles come from: `bigip` (already on the device, the default) or `secret` (Kubernetes `kubernetes.io/tls` Secrets) |
| `tls.clientSSLs` | Profiles BIG-IP uses to **terminate** client TLS |
| `tls.serverSSLs` | Profiles BIG-IP uses to **re-encrypt** to NGINX |
| `serviceAddress.icmpEcho` | Whether the VIP answers ping — `enable`, `disable`, or `selective` (follows virtual server state) |
| `serviceAddress.trafficGroup` | BIG-IP traffic group owning the VIP, e.g. `/Common/traffic-group-1` — this is what controls failover in an HA pair |
| `multiCluster` | Load balance across NGINX instances in several clusters — see below |
| `additionalIngressLinkSpec` | **Escape hatch.** Merged verbatim into the generated IngressLink, bypassing schema validation, defaulting, and CEL rules entirely. Modeled fields above take precedence over it, and the `selector` can never be overridden. Use only for IngressLink fields GatewayLink does not model yet |

---

## Going further — multi-cluster load balancing

<details>
<summary><b>One BIG-IP fronting Gateways in two clusters</b> (outline — a lab in its own right)</summary>

<br>

`multiCluster` lets a single BIG-IP virtual server pool members from **several** clusters, each running its
own NGF and Gateway. Only the cluster running CIS sets `multiCluster`; the others just run NGF with a
matching Gateway and Service, and CIS reaches them over a kubeconfig.

The shape of it:

1. **In cluster B (remote):** create a ServiceAccount with a ClusterRole granting read on `nodes`,
   `services`, `endpoints`, `namespaces`, `pods`, `secrets`, `configmaps`, plus `discovery.k8s.io/endpointslices`
   and full access to `cis.f5.com`. Mint a long-lived token and build a kubeconfig from it.
2. **In cluster A (local, runs CIS):** store that kubeconfig as a Secret, and point CIS at it through an
   "extended spec" ConfigMap listing the remote clusters:

   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: extended-spec-config
     namespace: kube-system
     labels:
       f5nr: "true"
   data:
     extendedSpec: |
       mode: default
       externalClustersConfig:
       - clusterName: remote
         secret: kube-system/remote-kubeconfig
   ```

   Then install CIS with `--set args.multi-cluster-mode=standalone`,
   `--set args.local-cluster-name=local`, and
   `--set args.extended-spec-configmap=kube-system/extended-spec-config`.
3. **In both clusters:** install NGF, apply the same `NginxProxy` / Gateway / app / HTTPRoute. Note the
   multicluster guide uses `externalTrafficPolicy: Local` rather than `Cluster`.
4. **In cluster A only:** one `ExternalLoadBalancer` describing the whole thing:

   ```yaml
   gatewayLink:
     virtualServerAddress: "192.0.2.100"
     partition: k8s
     host: cafe.example.com
     tls:
       reference: bigip
       clientSSLs:
         - /Common/clientssl
       serverSSLs:
         - /Common/serverssl
     monitors:
       - name: /Common/http
         reference: bigip
     multiCluster:
       localClusterName: local        # MUST match CIS's --local-cluster-name
       remoteClusters:
         - clusterName: remote        # MUST match a name in the extended spec
   ```

Two constraints that are easy to get wrong: `localClusterName` must equal the CIS `--local-cluster-name`
flag or CIS cannot resolve the local Service, and each `remoteClusters[].clusterName` must match a
`clusterName` in the extended-spec ConfigMap. Each remote entry defaults its `namespace` and `service` to
the **local** Gateway's, so the remote cluster's Gateway must be named identically unless you override
them. `weight` (0–256) shifts the split between clusters.

Full walkthrough, including the TLS termination and re-encryption setup:
[GatewayLink multi-cluster guide](https://github.com/nginx/documentation/blob/main/content/ngf/external-loadbalancers/gateway-link/multicluster.md).

</details>

---

## Cleanup

Delete the `ExternalLoadBalancer` **first** and confirm CIS removed the virtual server before deleting the
Gateway — otherwise a stale VIP can be left configured on the BIG-IP, and with the Gateway gone there is no
longer a resource whose deletion would clean it up.

```shell
kubectl delete -f 4.externalloadbalancer.yaml
```

Confirm the device is clean — the virtual server in your partition should be gone:

```shell
curl -sku "$BIGIP_USERNAME:$BIGIP_PASSWORD" "https://$BIGIP_ADDRESS/mgmt/tm/ltm/virtual" \
  | python3 -m json.tool | grep fullPath
```

Then the rest:

```shell
kubectl delete -f 3.routes.yaml
kubectl delete -f 2.gateway.yaml
kubectl delete -f 1.nginxproxy.yaml
kubectl delete -f 0.apps.yaml
```

To remove the supporting infrastructure as well:

```shell
helm uninstall f5-cis -n kube-system
helm uninstall f5-ipam-controller -n kube-system
```

Leave the NGF flag enabled only if CIS stays installed. If you uninstall CIS, **disable the flag first** —
deleting the `IngressLink` CRD out from under a running NGF control plane reproduces the crash loop from
the prerequisites:

```shell
helm upgrade ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --version 2.7.0 --reuse-values \
  --set nginxGateway.externalLoadBalancer.enable=false \
  -n nginx-gateway --wait
```

---

## Learn More

Most Kubernetes gateways stop at the cluster edge and leave "how does traffic actually arrive" to a cloud
LoadBalancer or a NodePort plus something external. `ExternalLoadBalancer` closes that gap declaratively for
on-prem F5 estates: the BIG-IP VIP becomes part of the same manifest set as the Gateway and HTTPRoute, so a
Git revert reverts the whole path rather than just the in-cluster half. The `partition` immutability rule
and the un-overridable selector are both deliberate guardrails on that — the CRD is designed so a
misconfiguration is rejected at apply time rather than silently reassigning device ownership.

Other directions worth exploring:

- **IPAM-driven addressing** — swap `virtualServerAddress` for `ipamLabel` (Part B) and let the controller allocate from a pool, so no manifest carries a hardcoded IP.
- **BIG-IP TLS offload in front of NGF** — use `tls.clientSSLs` / `tls.serverSSLs` to terminate at the BIG-IP and re-encrypt to the Gateway, versus passing through and terminating at NGINX (lab 4 / lab T10).
- **Multi-cluster** — see the section above; the most genuinely differentiated capability here.
- **Multi-partition tenancy** — one partition per environment or business unit, with `partition` immutability as the guardrail against accidental cross-tenant moves.
- **HA and failover** — set `serviceAddress.trafficGroup` and fail the BIG-IP pair over while traffic runs.
- **Failover testing in-cluster** — drain a data plane pod and watch CIS update the pool members.
- **Comparing to cloud LoadBalancer Services** — run the same Gateway both ways and diff what each provisions.

---

## References

- [GatewayLink quickstart](https://docs.nginx.com/nginx-gateway-fabric/external-loadbalancers/gateway-link/quickstart/) ([source](https://github.com/nginx/documentation/blob/main/content/ngf/external-loadbalancers/gateway-link/quickstart.md))
- [GatewayLink multi-cluster guide](https://github.com/nginx/documentation/blob/main/content/ngf/external-loadbalancers/gateway-link/multicluster.md)
- [NGF 2.7.0 release notes](https://github.com/nginx/nginx-gateway-fabric/releases/tag/v2.7.0)
- [F5 CIS IngressLink CRD definitions](https://github.com/F5Networks/k8s-bigip-ctlr/blob/master/docs/config_examples/customResourceDefinitions/customresourcedefinitions.yml)
- [NGINX Gateway Fabric API reference](https://docs.nginx.com/nginx-gateway-fabric/reference/api/)

---

> **Support:** the code in this repository is community supported and is not supported by F5, Inc. For a complete list of supported projects please reference `SUPPORT.md`.
