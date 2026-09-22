# Lab 11: GatewayLink — Fronting a Gateway with F5 BIG-IP in OpenShift

External load balancers such as F5 BIG-IP usually sit in front of an OpenShift cluster. The NGINX Gateway Fabric CRD `ExternalLoadBalancer` declares that load balancer from Kubernetes, and F5 Container Ingress Services (CIS) provisions the BIG-IP virtual server that fronts the data plane Service.

By the end of this lab, external clients reach `cafe.example.com/coffee` through a BIG-IP virtual server whose pool members are the NGINX data plane node ports, with the real client IP preserved end to end, all declared from OpenShift.

![GatewayLink flow: an ExternalLoadBalancer targets a Gateway and an NginxProxy sets the data plane to NodePort with PROXY protocol; NGF emits an IngressLink that F5 CIS compiles into an AS3 declaration, provisioning a BIG-IP virtual server whose pool members are the data plane node ports](image/topology-flow.svg)

*Blue = Gateway API / NGF resources · Amber = NGINX data plane · Teal = F5 controllers · Grey/green = BIG-IP and the resulting traffic path.*

> **Validation note.** Steps and outputs here were run on OpenShift **4.20.13** (OVN-Kubernetes), NGF **2.7.2** (operator 1.5.2), CIS **2.20.4**, FIC **0.1.13**, BIG-IP **17.5.1.3** with AS3 **3.56.0**. Anything not verified there is marked **[unverified]**.

---

## Table of contents

- [What you will learn](#what-you-will-learn)
- [How GatewayLink works](#how-gatewaylink-works)
- [Prerequisites](#prerequisites)
- [OpenShift-specific facts you need before you start](#openshift-specific-facts-you-need-before-you-start)
- [Enable the feature flag in the right order](#-enable-the-feature-flag-in-the-right-order)
- [Part A — Prepare the BIG-IP](#part-a--prepare-the-big-ip)
- [Part B — Install the F5 IPAM Controller](#part-b--install-the-f5-ipam-controller)
- [Part C — Install F5 Container Ingress Services](#part-c--install-f5-container-ingress-services)
- [Part D — Enable the NGF flag](#part-d--enable-the-ngf-flag)
- [Step 1 — Deploy the sample application](#step-1--deploy-the-sample-application)
- [Step 2 — Configure the data plane](#step-2--configure-the-data-plane)
- [Step 3 — Create the Gateway](#step-3--create-the-gateway)
- [Step 4 — Publish the route](#step-4--publish-the-route)
- [Step 5 — Declare the ExternalLoadBalancer](#step-5--declare-the-externalloadbalancer)
- [Step 6 — Verify the BIG-IP virtual server](#step-6--verify-the-big-ip-virtual-server)
- [Validation rules](#validation-rules)
- [Troubleshooting](#troubleshooting)
- [Optional configuration](#optional-configuration)
- [Going further](#going-further)
- [Cleanup](#cleanup)

---

## What you will learn

- How NGF delegates external load balancer provisioning instead of implementing it: who does what between NGF, CIS, the IPAM controller and AS3
- Why the `NginxProxy` in this lab is **not optional**, and the two distinct failures you get without it
- Why `ExternalLoadBalancer` maps one-to-one with a Gateway
- The `virtualServerAddress` vs `ipamLabel` choice: static addressing or delegated IPAM
- How PROXY protocol preserves the client IP across a full-proxy BIG-IP, and why **OVN-Kubernetes SNAT** can still hide it
- Which OpenShift specifics decide whether this works at all: SCCs, Pod Security, the OVN-K gateway mode, dual-stack pool members, and CRD name collisions with NGINX Ingress Controller

---

## How GatewayLink works

NGF never talks to BIG-IP. It writes an intermediate resource that CIS already knows how to consume, and CIS does the device programming:

```
  ExternalLoadBalancer      NGF Controller        F5 IPAM        F5 CIS            BIG-IP
         |                        |                  |             |                  |
         |  1. applied            |                  |             |                  |
         |----------------------->|                  |             |                  |
         |                        |  2. emits IngressLink           |                  |
         |                        |    (named after the DATA        |                  |
         |                        |     PLANE SERVICE)              |                  |
         |                        |-------------------------------->|                  |
         |                        |                  |  3. CIS requests an address     |
         |                        |                  |     (only if ipamLabel is set)  |
         |                        |                  |<----------->|                  |
         |                        |                  |             |  4. node IPs +   |
         |                        |                  |             |     NodePorts →  |
         |                        |                  |             |     AS3 POST     |
         |                        |                  |             |----------------->|
         |  5. Accepted condition on the ExternalLoadBalancer       |  virtual + pool  |
         |<-----------------------|                  |             |                  |
```

Step 4 repeats whenever endpoints or the IngressLink spec change, which keeps the pool in sync as pods come and go.

**The IngressLink is named after the data plane Service.** A Gateway called `gateway` produces a Service called `gateway-nginx`, so the IngressLink is `gateway-nginx`, even though the `ExternalLoadBalancer` here is `gateway-bigip-link`. Every verification command below uses the Service-derived name.

**One Gateway, one data plane Service, one external load balancer.** If two `ExternalLoadBalancer` resources reference the same Gateway, the oldest is accepted and the rest get `Accepted=False`, `Reason: Conflicted`. **[unverified]**

**Pool members come from the data plane Service, selected by label.** NGF sets the IngressLink `selector` internally and it cannot be overridden, not even through `additionalIngressLinkSpec`.

**Note on labels:** CIS normally only processes `cis.f5.com` custom resources labelled `f5cr: "true"`. The IngressLink NGF generates carries **no such label**, and CIS 2.20.4 processes it anyway. Don't add that label by hand and don't expect it in the output.

---

## Prerequisites

| Requirement | Version / notes |
|---|---|
| OpenShift | 4.19–4.22 for NGF 2.7.x. Verified on 4.20.13, OVN-Kubernetes. |
| NGINX Gateway Fabric | **2.7.0+** (`ExternalLoadBalancer` arrived in 2.7.0). NGF operator **1.5.x** for 2.7.x. |
| Gateway API CRDs | Supplied and **owned by OpenShift** (v1.2.1 on 4.20), protected by an admission policy. NGF 2.7.x is compatible with v1.2.1–v1.6.x; newer Gateway API features are simply unavailable. Do not try to upgrade them. |
| F5 BIG-IP | 17.1.0.3 or later, admin credentials. Verified on 17.5.1.3. |
| AS3 | Installed on the device. CIS programs BIG-IP exclusively through AS3. Verified with 3.56.0 (the top of the range tested with CIS 2.20.4). |
| BIG-IP partition | Must exist before the first apply and must **not** be `Common`. |
| F5 CIS | **Install before enabling the NGF flag.** Certified operator "F5 Container Ingress Services" in Ecosystem ›› Software Catalog. |
| F5 IPAM Controller | 0.1.13, only if you use `ipamLabel`. **No operator exists**; deploy it as a Deployment. |
| Tools | `oc`, `curl`, `jq`. BIG-IP work is shown in both the GUI and `tmsh`/iControl REST. |

Command locations: **[oc]** provisioner or workstation with `oc`, **[bigip-sh]** BIG-IP shell, **[bigip-gui]** Configuration Utility, **[ocp-gui]** OpenShift console.

---

## OpenShift-specific facts you need before you start

These cost the most time if you meet them by surprise.

**1. Check whether BIG-IP can reach pods at all.** CIS can use pod IPs (`cluster` mode, with static routes) or node ports (`nodeport` mode). On OVN-K with `routingViaHost: true` and default (`Restricted`) IP forwarding, the pod-direct path **fails**: the SYN reaches the pod, but the reply never leaves the node. This lab uses **NodePort**, which works either way.

```shell
oc get network.operator cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig}{"\n"}'
```

**2. Check whether pods can reach the BIG-IP management address.** On clusters where nodes have a second NIC on the management subnet, pod egress may be blocked under Restricted forwarding, even though the node itself can connect. `oc debug node` runs on the **host** network, so it passes and hides the problem. Test from a real pod:

```shell
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Pod
metadata: {name: curltest, namespace: default}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: c
    image: registry.access.redhat.com/ubi9/ubi-minimal
    command: ["curl","-sk","-m5","-o","/dev/null","-w","pod->bigip http=%{http_code}\n","https://<BIGIP_MGMT>/mgmt/shared/appsvcs/info"]
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
EOF
sleep 20; oc logs curltest; oc delete pod curltest
```

`401` is a pass. `000` means the pod cannot reach it, so point CIS at a **BIG-IP self-IP on the node network** instead, with Port Lockdown set to Allow Custom TCP 443. That is what `args.bigip_url` is set to in `prereq/31-cis-cr.yaml`.

**3. Dual-stack clusters add IPv6 pool members.** On a dual-stack cluster CIS adds each node's IPv6 address as a NodePort pool member too, even without `enable_ipv6`. If the BIG-IP has no IPv6 path, those members are unusable and, without a monitor, they still receive traffic. **Always monitor the pool.**

**4. Pod Security and SCCs.** Sample apps need `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` and `seccompProfile: RuntimeDefault` (included in `0.apps.yaml`). FIC runs as UID 1200, which `restricted-v2` rejects, so it needs `nonroot-v2` (included in `prereq/10-fic.yaml`). A rejected pod produces **no pod at all**: look at the ReplicaSet events, not the Deployment.

**5. Resource-name collisions.** If NGINX Ingress Controller is installed, `VirtualServer`, `TransportServer` and `Policy` exist in both `k8s.nginx.org` and `cis.f5.com`. Always use fully qualified names, for example `oc get virtualservers.cis.f5.com`.

**6. CIS scope.** Give CIS an explicit namespace list, and gate LoadBalancer Services with `load_balancer_class` + `manage_load_balancer_class_only: true`. Otherwise CIS processes every classless LoadBalancer Service in the namespaces it watches, which on a shared cluster means other teams' Services.

---

## ⚠️ Enable the feature flag in the right order

`externalLoadBalancer.enable=true` makes the NGF **control plane** watch `IngressLink.cis.f5.com/v1`, a CRD owned by CIS. If that CRD is absent, the informer never syncs and the controller terminates after roughly 60 seconds: **[unverified on this build; behaviour reported on NGF 2.7.0]**

```
failed to start control loop: failed to wait for provisioner-IngressLink caches to sync
kind source: *unstructured.Unstructured[cis.f5.com/v1 IngressLink]: timed out waiting for cache to be synced
```

A crashing control plane stops reconciling **every** Gateway in the cluster. Existing data planes keep serving, but no new config is pushed and no status is updated.

**Correct order: A → B → C → D.**

---

## Part A — Prepare the BIG-IP

**A0. Base setup, if the device is new.** Two traps seen on 17.5:
- The VLAN interface must be **Untagged** for a flat lab network; tagged means no ARP replies at all. The GUI won't change tagging while a self-IP uses the VLAN, so delete the self-IP, then the VLAN, then recreate both. Also check the interface is **Enabled**.
- Create the CIS user (Administrator, all partitions, no terminal), then **log in once as that user**. BIG-IP 17.5 forces a password change on first login, and until you do, remote REST calls return `401 Password expired` while local calls on the device succeed.

Set connection details once. **[oc]**

```shell
export BIGIP_ADDRESS="10.1.1.5"           # management address
export BIGIP_USERNAME="cis-admin"
read -rs BIGIP_PASSWORD; export BIGIP_PASSWORD
export BIGIP_PARTITION="ocp"
```

**A1. Install AS3.** A fresh BIG-IP has no automation toolchain, and iApps ›› Package Management LX only lists packages that are already installed. Download the RPM from the F5 `f5-appsvcs-extension` releases, then import it in the GUI. If the **Import** button is missing, enable uploads once on the device: **[bigip-sh]** `touch /var/config/rest/iapps/enable`.

Confirm AS3 answers **as the CIS user**:

```shell
curl -sku "$BIGIP_USERNAME:$BIGIP_PASSWORD" "https://$BIGIP_ADDRESS/mgmt/shared/appsvcs/info" | jq .
```

```
{"version":"3.56.0","release":"10","schemaCurrent":"3.56.0","schemaMinimum":"3.0.0"}
```

**A2. Create the partition.** CIS owns everything inside it, which is what makes the integration reversible. `Common` is rejected by the CRD for that reason.

```shell
curl -sku "$BIGIP_USERNAME:$BIGIP_PASSWORD" -X POST "https://$BIGIP_ADDRESS/mgmt/tm/auth/partition" \
  -H "Content-Type: application/json" -d "{\"name\": \"$BIGIP_PARTITION\"}"
```

**A3. Create the PROXY protocol iRule.** BIG-IP is a full proxy, so by default NGINX sees the BIG-IP self-IP as the client. `prereq/Proxy_Protocol_iRule.tcl` holds the verified version. Create it in `/Common`, either in the GUI (Local Traffic ›› iRules ›› Create) or with `tmsh`:

```shell
# [bigip-sh]
tmsh create ltm rule Proxy_Protocol_iRule
# paste the contents of prereq/Proxy_Protocol_iRule.tcl, then:
tmsh save sys config
tmsh list ltm rule /Common/Proxy_Protocol_iRule
```

> **This is only half the setup.** The `rewriteClientIP` block in `1.nginxproxy.yaml` is the other half. With only one side configured there is **no error anywhere**: requests succeed and the access log quietly shows an internal address.

---

## Part B — Install the F5 IPAM Controller

Skip this if you use a static `virtualServerAddress`.

**B1. Plan and prove the address range.** Sweep the candidates from the BIG-IP and check ARP, not just ping, so hosts that drop ICMP are still found:

```shell
# [bigip-sh]
for i in $(seq 101 119); do ping -c1 -W1 10.1.10.$i >/dev/null && echo "IN USE 10.1.10.$i"; done
tmsh show net arp | grep -v incomplete
```

**B2. Apply the CRD and the controller.** There is no FIC operator, so this is a plain Deployment. Edit `storageClassName` and `--ip-range` first.

```shell
oc apply -f prereq/09-fic-crd.yaml
oc apply -f prereq/10-fic.yaml
oc -n kube-system rollout status deploy/f5-ipam-controller
```

**B3. Verify.** The `Added Label` lines are the pool names that `ipamLabel` must match:

```shell
oc -n kube-system logs deploy/f5-ipam-controller | grep -E "Version|Added Label|Provider Initialised|Caches are synced"
oc -n kube-system logs deploy/f5-ipam-controller | grep reflector.go | tail -2      # must be empty
```

```
[INIT] Starting: F5 IPAM Controller - Version: 0.1.13
[DEBUG] Added Label: Dev
[DEBUG] Added Label: Test
[DEBUG] [PROV] Provider Initialised
Caches are synced for F5 IPAMClient Controller
```

`Failed to watch *v1.IPAM` means the CRD is missing. The PVC stays `Pending` until the pod is scheduled if your StorageClass is `WaitForFirstConsumer`; that's expected.

---

## Part C — Install F5 Container Ingress Services

**C1. Install the CIS CRDs.** The operator does **not** install them: its chart has no `crds/` directory, and its bundle owns only `F5BigIpCtlr`. Pin the branch rather than tracking `master`:

```shell
oc apply -f https://raw.githubusercontent.com/F5Networks/k8s-bigip-ctlr/2.20-stable/docs/config_examples/customResourceDefinitions/customresourcedefinitions.yml
oc get crd ingresslinks.cis.f5.com
```

```
NAME                      CREATED AT
ingresslinks.cis.f5.com   2026-09-19T18:41:30Z
```

**C2. Install the operator. [ocp-gui]** Ecosystem ›› Software Catalog ›› **F5 Container Ingress Services** ›› Install: channel `stable`, installed namespace `openshift-operators`, **Update approval: Manual**. Approve the install plan, and wait for **Succeeded**.

**C3. Credentials and the CIS instance.**

```shell
oc -n kube-system create secret generic f5-bigip-ctlr-login \
  --from-literal=username="$BIGIP_USERNAME" --from-literal=password="$BIGIP_PASSWORD"
# edit bigip_url / partition / namespaces / digest first
oc apply -f prereq/31-cis-cr.yaml
oc -n kube-system rollout status deploy/f5-cis-f5-bigip-ctlr
```

Three arguments decide whether this lab works at all:

| Argument | Why |
|---|---|
| `pool_member_type: nodeport` | Pool members are node IP + nodePort. This is why `1.nginxproxy.yaml` sets the Service to NodePort. Mismatch the two and the pool comes out empty. |
| `custom_resource_mode: true` | Makes CIS watch `IngressLink` and the other `cis.f5.com` CRDs. Without it CIS ignores everything NGF emits. **Also note:** this mode is mutually exclusive with `controller-mode=openshift` (native Route support), and IPAM requires this mode. One CIS instance cannot do both; run a second instance with its own partition for Routes. |
| `ipam: true` | Required for `ipamLabel`; harmless with a static address. |

**C4. Verify.** Check what the operator actually rendered, not just what you wrote:

```shell
oc -n kube-system get deploy/f5-cis-f5-bigip-ctlr -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
oc -n kube-system get deploy/f5-cis-f5-bigip-ctlr -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'
oc -n kube-system logs deploy/f5-cis-f5-bigip-ctlr | grep -E "Starting: Container Ingress Services|appsvcs|\[(ERROR|WARNING)\]" | head
```

Expect `Version: v2.20.4`, the AS3 version echoed back from the device, and `Created IPAM Custom Resource` if IPAM is on.

If the pod is Running but the probes report `connection refused`, CIS is stuck in startup: the health endpoint only opens once the BIG-IP login and AS3 check succeed. Read the log; the probe failure is a symptom, not the cause.

---

## Part D — Enable the NGF flag

**D1. Re-confirm the gate:**

```shell
oc get crd ingresslinks.cis.f5.com
oc -n kube-system get pods -l app=f5-bigip-ctlr
```

**D2. Enable it.** With the NGF operator, the flag lives in the `NginxGatewayFabric` resource:

```shell
NGFNS=nginx-gateway
NGFCR=$(oc -n $NGFNS get nginxgatewayfabric -o name | head -1)
oc -n $NGFNS patch $NGFCR --type=merge -p '{"spec":{"nginxGateway":{"externalLoadBalancer":{"enable":true}}}}'
```

**D3. Confirm the flag rendered.** Values a chart doesn't define are ignored silently, so a chart older than 2.7.0 renders no flag and no error:

```shell
oc -n $NGFNS get deploy -l app.kubernetes.io/name=nginx-gateway-fabric \
  -o jsonpath='{.items[0].spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -i external
```

```
"--external-load-balancer"
```

**D4. Confirm the control plane is stable.** Watch the restart count for two minutes; the cache-sync failure takes about 60 seconds, so "Running" straight after the change proves nothing.

```shell
oc -n $NGFNS get pods -w -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount'
```

If restarts climb, set `enable: false` again and go back to Part C.

<details>
<summary><b>Upgrading NGF 2.6.x → 2.7.x on OpenShift (three traps)</b></summary>

<br>

1. **New CRDs are not installed on upgrade.** The operator is Helm-based, and Helm only applies a chart's `crds/` on first install. `ExternalLoadBalancer` and `PayloadProcessor` would simply never appear. Extract the CRDs from the new operator image and apply them **before** approving the upgrade:

   ```shell
   OPIMG=<operator image from the packagemanifest relatedImages>
   rm -rf /tmp/ngf-op && mkdir -p /tmp/ngf-op
   oc image extract --filter-by-os=linux/amd64 "$OPIMG" --path /opt/helm/:/tmp/ngf-op --confirm
   grep -E '^(version|appVersion)' /tmp/ngf-op/helm-charts/nginx-gateway-fabric/Chart.yaml
   oc apply --server-side --force-conflicts -f /tmp/ngf-op/config/crd/bases/
   ```

2. **OLM may offer no upgrade path.** If the Subscription reports `AtLatestKnown` while the catalog lists only a newer CSV, there is no upgrade edge. Delete the Subscription **and** the CSV, then re-subscribe with `startingCSV` set to the new version. The NGF deployments, CRDs and the `NginxGatewayFabric` resource survive, because the CSV doesn't own them. **Never delete the `NginxGatewayFabric` resource**: its finalizer uninstalls NGF.

3. **Per-Gateway pinned images must be bumped with it.** A Gateway whose own `NginxProxy` pins an nginx image tag keeps that tag, while the new control plane renders its own init container and WAF sidecar versions. The mismatch crash-loops the data plane. Bump those tags in the same change.

Also worth knowing: the operator's default memory limit may be too small (128Mi against ~120Mi in use), which shows up as exit 137, lease-renewal timeouts and dozens of restarts. Raise it through the Subscription's `spec.config.resources`.

</details>

---

## Step 1 — Deploy the sample application

```shell
oc new-project gatewaylink-demo
oc apply -f 0.apps.yaml
oc get pods -l app=coffee
```

```
NAME                      READY   STATUS    RESTARTS   AGE
coffee-654ddf664b-9zx2q   1/1     Running   0          6s
coffee-654ddf664b-lm4tv   1/1     Running   0          6s
```

Make sure the namespace isn't enrolled in a service mesh, which would intercept this traffic:

```shell
oc get ns gatewaylink-demo --show-labels    # no istio.io/dataplane-mode, no istio-injection
```

---

## Step 2 — Configure the data plane

Skipping this produces a virtual server that exists but doesn't work. `1.nginxproxy.yaml` sets a NodePort Service (pool members), an exposed readiness probe (health checks) and PROXY protocol rewriting (real client IP).

```shell
oc apply -f 1.nginxproxy.yaml
oc -n gatewaylink-demo get nginxproxy gatewaylink-proxy
```

Nothing takes effect until a Gateway references it, which is the next step.

**About `trustedAddresses`:** NGINX validates the PROXY header against the address the connection comes **from**. With `externalTrafficPolicy: Cluster`, OpenShift SNATs node-port traffic to an OVN-K **join-subnet** address (100.64.0.0/16 by default), not the BIG-IP self-IP. So either trust both (as shipped), or switch to `externalTrafficPolicy: Local` and trust only the BIG-IP `/32`. With `Local`, run at least two replicas, because only nodes hosting a data plane pod answer.

---

## Step 3 — Create the Gateway

```shell
oc apply -f 2.gateway.yaml
oc -n gatewaylink-demo get gateway gateway
oc -n gatewaylink-demo get svc gateway-nginx
```

```
NAME      CLASS   ADDRESS         PROGRAMMED   AGE
gateway   nginx   192.168.1.30    True         18s

NAME            TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)                       AGE
gateway-nginx   NodePort   192.168.1.30   <none>        80:31207/TCP,8081:30322/TCP   18s
```

Two things to check: `TYPE` must be `NodePort` (`ClusterIP` means the `parametersRef` didn't resolve, usually a name typo or the `NginxProxy` in another namespace), and the readiness port 8081 must have its own node port, which is what a proper health monitor targets.

Confirm the PROXY protocol side landed in the generated config:

```shell
POD=$(oc -n gatewaylink-demo get pod -l gateway.networking.k8s.io/gateway-name=gateway -o name | head -1)
oc -n gatewaylink-demo exec ${POD#pod/} -c nginx -- grep -E "set_real_ip_from|proxy_protocol" /etc/nginx/conf.d/http.conf
```

---

## Step 4 — Publish the route

```shell
oc apply -f 3.routes.yaml
oc -n gatewaylink-demo get httproute coffee
```

---

## Step 5 — Declare the ExternalLoadBalancer

Edit `4.externalloadbalancer.yaml` first: `ipamLabel` must match a pool name from Part B (or swap in `virtualServerAddress`), and `partition` must match the CIS partition.

```shell
oc apply -f 4.externalloadbalancer.yaml
oc -n gatewaylink-demo get externalloadbalancers.gateway.nginx.org gateway-bigip-link -o json | jq '.status'
```

```json
{"controllers":[{"conditions":[{"message":"The ExternalLoadBalancer is accepted","reason":"Accepted","status":"True","type":"Accepted"}],
  "controllerName":"gateway.nginx.org/nginx-gateway-controller"}]}
```

The status is nested under `controllers`, one entry per controller, not a bare `conditions` list.

**Then confirm NGF emitted the IngressLink**, named after the data plane Service:

```shell
oc -n gatewaylink-demo get ingresslinks.cis.f5.com \
  -o custom-columns='NAME:.metadata.name,LABEL:.spec.ipamLabel,PARTITION:.spec.partition,ADDRESS:.status.vsAddress,STATUS:.status.status'
```

```
NAME            LABEL   PARTITION   ADDRESS       STATUS
gateway-nginx   Dev     ocp         10.1.10.102   OK
```

An IngressLink with **no status** hasn't been processed by CIS yet. Give it two minutes before digging into logs.

Check both halves of the IPAM handshake: CIS files the request in `spec.hostSpecs`, FIC answers in `status.IPStatus`, through the `/status` subresource:

```shell
./verify.sh
```

```
== IPAM: requests (CIS) vs allocations (FIC)
KEY                          LABEL  IP
gatewaylink-demo/gateway-nginx_il   Dev    10.1.10.102

== Writers on the IPAM resource
{"manager":"k8s-bigip-ctlr","subresource":null}
{"manager":"f5-ipam-controller","subresource":"status"}
```

If `status` stays empty while FIC logs "Updated … with Status", the IPAM CRD is wrong; see `prereq/09-fic-crd.yaml`.

---

## Step 6 — Verify the BIG-IP virtual server

**[bigip-sh]** Objects live under `/<partition>/Shared/…`:

```shell
tmsh -c "cd /ocp; list ltm virtual recursive one-line" | grep -oE 'ltm virtual [^ ]+|destination [^ ]+|rules \{[^}]*\}'
tmsh -c "cd /ocp; show ltm pool recursive members field-fmt" | grep -E 'ltm pool|addr|port|availability-state'
```

```
ltm virtual Shared/ingress_link_crd_10_1_10_102_80
destination 10.1.10.102:http
rules { /Common/Proxy_Protocol_iRule }

ltm pool Shared/gw_link_nginx_80_ngf_test
  addr 10.1.10.6 … 10.1.10.10  port 31207   available
  addr fdbd:…::6 … ::10        port 31207   offline      <- dual-stack: expected, monitored down
```

No `rules` on the virtual means the iRule wasn't attached and client IPs will be wrong. A path pointing at a non-existent iRule is accepted by the CRD but fails at the device.

**Reach the application through the VIP:**

```shell
VIP=$(oc -n gatewaylink-demo get ingresslinks.cis.f5.com gateway-nginx -o jsonpath='{.status.vsAddress}')
curl -i --resolve cafe.example.com:80:$VIP http://cafe.example.com/coffee
for i in $(seq 1 10); do curl -s --resolve cafe.example.com:80:$VIP http://cafe.example.com/coffee | grep "Server name"; done | sort | uniq -c
```

**Verify the client IP survived:**

```shell
POD=$(oc -n gatewaylink-demo get pod -l gateway.networking.k8s.io/gateway-name=gateway -o name | head -1)
oc -n gatewaylink-demo logs ${POD#pod/} -c nginx | grep coffee | tail -1
```

The leading address should be **your workstation's IP**. A `100.64.x.x` address means the PROXY header was discarded because the SNAT source isn't trusted; see Step 2.

**Confirm the node port is not a client entry point:**

```shell
NP=$(oc -n gatewaylink-demo get svc gateway-nginx -o jsonpath='{.spec.ports[0].nodePort}')
curl -s -m5 -o /dev/null -w 'direct nodeport: %{http_code}\n' -H 'Host: cafe.example.com' http://<any-node-ip>:$NP/coffee
```

`000` is the expected result: the listener requires a PROXY header, so only the BIG-IP can talk to it. Node ports exist in this mode, but they aren't usable by clients.

**A caveat on health monitoring.** CIS generates a default monitor whose send string is `GET /nginx-ready HTTP/1.1\r\n` with no `Host` header and no terminating blank line, and with an empty receive string. NGINX answers `400`, and BIG-IP counts that as healthy. So the default monitor proves the node port answers, not that NGINX is ready. Either reference a properly defined BIG-IP monitor through `gatewayLink.monitors`, or override it through `additionalIngressLinkSpec` (both shown in `4.externalloadbalancer.yaml`).

---

## Validation rules

**Confirmed here:**

| What you do | What you get |
|---|---|
| Give `monitors` an inline definition (`type`/`send`/`recv`) | `spec.gatewayLink.monitors[0].name: Required value` and `…reference: Required value`. The field references an existing BIG-IP monitor; it cannot define one. |
| Point `partition` at the CIS partition | Accepted, and the virtual lands in `/<partition>/Shared/` |

**Reported by the CRD's validation rules [unverified here]:**

| What you do | What the API server returns |
|---|---|
| Leave `<BIGIP_VIRTUAL_SERVER_IP>` unreplaced | `spec.gatewayLink.virtualServerAddress: Invalid value … should match '^(([0-9]…` |
| `partition: Common` | `partition cannot be Common` |
| Both `virtualServerAddress` and `ipamLabel` | `virtualServerAddress and ipamLabel are mutually exclusive` |
| Neither | `one of virtualServerAddress or ipamLabel must be set` |
| A bare iRule name | `Invalid value: "Proxy_Protocol_iRule" … should match '^\/[a-zA-Z]+…` |
| Change `partition` in place | `partition cannot be modified; delete the resource and recreate it` |

Try them without touching anything real:

```shell
oc apply --dry-run=server -f 4.externalloadbalancer.yaml
```

---

## Troubleshooting

| Symptom | Cause | Resolution |
|---|---|---|
| NGF control plane crash-loops, `failed to wait for provisioner-IngressLink caches to sync` | The flag is on but the `IngressLink` CRD is absent | Install CIS (Part C) or set `externalLoadBalancer.enable: false` |
| Control plane fine, then restarts about a minute later | The cache-sync timeout isn't immediate | Watch `restartCount`, not just `Running` |
| No IngressLink at all | `--external-load-balancer` never rendered (chart older than 2.7.0), or CIS doesn't watch that namespace | Check the rendered args (D3) and CIS's `--namespace=` list |
| IngressLink exists, no `status` | CIS hasn't processed it yet | Wait 2 minutes, then read the CIS log |
| Looking for an IngressLink named after the ExternalLoadBalancer | It's named after the **data plane Service** | `oc get ingresslinks.cis.f5.com gateway-nginx` |
| BIG-IP pool empty | Service type doesn't match `pool_member_type`, or the listener isn't programmed | `oc get svc gateway-nginx -o jsonpath='{.spec.type}'` must be `NodePort` |
| Pool has twice the members, half offline | Dual-stack nodes; the IPv6 members have no BIG-IP path | Expected. Keep a monitor on every pool. |
| NGINX logs a `100.64.x.x` client | OVN-K SNAT with `externalTrafficPolicy: Cluster`; the header source isn't trusted, and NGINX discards the header silently | Trust the join subnet, or switch to `Local` with ≥2 replicas |
| NGINX logs the BIG-IP self-IP | Only one half of the PROXY setup is in place | Check the iRule is attached (Step 6) and `set_real_ip_from` is in the config |
| CIS pod Running, probes refused, restarts | Startup blocked on the BIG-IP login or AS3 | Read the CIS log: timeouts to the mgmt IP mean pods can't reach it; use the self-IP |
| CIS `[ERROR] AS3 RPM is not installed on BIGIP` | AS3 missing or returning 404 | Part A1, then restart the CIS pod |
| No address with `ipamLabel` | Label doesn't match a pool name, or `ipam: true` missing | Compare with the FIC `Added Label` lines |
| FIC logs "Updated … with Status" but `status` stays `{}` | Wrong IPAM CRD: no status subresource, or `ipStatus` vs `IPStatus` pruning | Use `prereq/09-fic-crd.yaml`; restart FIC, then CIS |
| FIC has no pod at all | UID 1200 rejected by `restricted-v2` | The `nonroot-v2` RoleBinding in `prereq/10-fic.yaml`; check ReplicaSet events |
| IPAM resource missing entirely | CIS creates it at startup, and only if the CRD exists | Order: CRD → FIC → CIS; after any CRD change restart FIC, then CIS |
| `oc get vs` shows unexpected objects | NIC defines the same kinds | Use `virtualservers.cis.f5.com` |
| A field you set has no effect and no error | The API server prunes fields absent from the CRD schema | Compare the CRD schema with what NGF wrote into the IngressLink |
| Data plane Service is `ClusterIP` despite the NginxProxy | `parametersRef` didn't resolve | It resolves from the **Gateway's** namespace; check name and namespace |
| VIP answers but returns 502 | Pool members unhealthy, or the wrong Service is targeted | Check endpoints and the exposed readiness port |

Useful commands:

```shell
oc get externalloadbalancers.gateway.nginx.org -A
oc get ingresslinks.cis.f5.com -A
oc -n nginx-gateway logs deploy/<ngf-control-plane> --tail=50
oc -n kube-system logs deploy/f5-cis-f5-bigip-ctlr --tail=50 | grep -v reflector.go
oc -n kube-system logs deploy/f5-ipam-controller --tail=50 | grep -v reflector.go
```

---

## Optional configuration

Fields on `spec.gatewayLink` beyond what this lab uses:

| Field | Purpose |
|---|---|
| `ipamLabel` | Delegate IP allocation to FIC. Must match a pool name in `ip_range`. |
| `virtualServerName` | Custom BIG-IP virtual server name |
| `host` | Hostname for the virtual server |
| `partition` | Must exist, cannot be `Common`, immutable after creation |
| `bigipRouteDomain` | Route domain ID (0–65535) |
| `iRules` | Full `/partition/name` paths |
| `monitors` | `{name: /Common/http, reference: bigip}`. References only; `reference` accepts `bigip`. |
| `tls.reference` | `bigip` (profiles on the device) or `secret` (Kubernetes TLS Secrets) |
| `tls.clientSSLs` / `tls.serverSSLs` | Terminate client TLS / re-encrypt to NGINX |
| `serviceAddress.icmpEcho` | Whether the VIP answers ping |
| `serviceAddress.trafficGroup` | Traffic group owning the VIP; this is what controls failover in an HA pair |
| `multiCluster` | Pool members from several clusters |
| `additionalIngressLinkSpec` | Escape hatch, merged verbatim, unvalidated. Modeled fields win; the selector can never be overridden. |

---

## Going further

- **Swap the static address for `ipamLabel`**, so no manifest carries a hardcoded IP.
- **A real readiness monitor**: reference a `/Common` monitor whose send string is valid HTTP/1.1 and whose receive string requires `200`.
- **`externalTrafficPolicy: Local` with 2+ replicas**: no SNAT, a tight `/32` trust, and a visible failover test.
- **BIG-IP TLS offload** in front of NGF via `tls.clientSSLs` / `tls.serverSSLs`.
- **WAF behind GatewayLink**: attach a `WAFPolicy` to the Gateway and confirm WAF events carry the real client IP.
- **Multi-cluster**: one BIG-IP pooling members from two clusters, each running its own NGF. `localClusterName` must equal CIS's `--local-cluster-name`, and each `remoteClusters[].clusterName` must match the extended-spec ConfigMap. **[unverified]**
- **Compare with IngressLink for NGINX Ingress Controller**: the same CIS resource, but you write it and maintain its selector by hand.

---

## Cleanup

Delete the `ExternalLoadBalancer` **first** and let CIS remove the virtual server. With the Gateway gone first, there's no resource left whose deletion would clean up the device.

```shell
./cleanup.sh
```

**[bigip-sh]** Confirm the device is clean:

```shell
tmsh -c "cd /ocp; list ltm virtual recursive one-line" | grep -o 'ltm virtual [^ ]*'
```

To remove the supporting infrastructure too:

```shell
oc delete -f prereq/31-cis-cr.yaml          # the operator removes the CIS Deployment
oc delete -f prereq/10-fic.yaml
```

Leave the NGF flag on only if CIS stays installed. If you uninstall CIS, **disable the flag first**; deleting the `IngressLink` CRD under a running control plane reproduces the crash loop from Part D.

---

## Learn more

Most Kubernetes gateways stop at the cluster edge and leave "how does traffic actually arrive" to a cloud LoadBalancer or a node port plus something external. `ExternalLoadBalancer` closes that gap declaratively for on-prem F5 estates: the BIG-IP VIP becomes part of the same manifest set as the Gateway and HTTPRoute, so a Git revert reverts the whole path rather than just the in-cluster half. On OpenShift it also fits the platform's own patterns: certified operators for the controllers, SCCs for the workloads, and no changes to the Gateway API CRDs the cluster owns.

## References

- [GatewayLink quickstart](https://docs.nginx.com/nginx-gateway-fabric/external-loadbalancers/gateway-link/quickstart/)
- [NGF technical specifications (OpenShift compatibility)](https://docs.nginx.com/nginx-gateway-fabric/overview/technical-specifications/)
- [NGF 2.7.0 release notes](https://github.com/nginx/nginx-gateway-fabric/releases/tag/v2.7.0)
- [F5 CIS CRDs (2.20-stable)](https://github.com/F5Networks/k8s-bigip-ctlr/blob/2.20-stable/docs/config_examples/customResourceDefinitions/customresourcedefinitions.yml)
- [F5 CIS configuration parameters](https://clouddocs.f5.com/containers/latest/userguide/config-parameters.html)
- [NGF API reference](https://docs.nginx.com/nginx-gateway-fabric/reference/api/)

---

> **Support:** the code in this repository is community supported and is not supported by F5, Inc. See `SUPPORT.md`.
