# Observability for NIC, NAP
- Open Grafana (Bookmarked) in Firefox, available in OCP Provisioner system.
- Explore Data Sources and Dashboards. 

# Observability Lab: NIC, NGF & NAP with Grafana

### What you'll learn

In this lab you'll explore a live observability stack for F5 NGINX on OpenShift. By the end you'll be comfortable navigating Grafana to answer three kinds of questions:

1. **Metrics** — How is my NGINX **Ingress Controller (NIC)** performing? (requests, upstreams, SSL, reloads)
2. **Metrics** — How is my **NGINX Gateway Fabric (NGF)** performing?
3. **Security events** — What is **NGINX App Protect (NAP / F5 WAF)** blocking, and why?

Everything is already deployed and wired. **This is an exploration lab, not a build lab** — you won't install anything. You'll drive Grafana, generate some traffic, and read the results.

---

## Environment at a glance

| Component | Where | What it does |
|---|---|---|
| **NIC** (NGINX Ingress Controller) | `nginx-ingress` ns | Ingress + inline NAP WAF protecting crAPI |
| **NGF** (NGINX Gateway Fabric) | `nginx-gateway` / `default` ns | Gateway API data plane + F5 WAF |
| **crAPI** | `crapi` ns | Intentionally vulnerable demo API (the thing being attacked) |
| **NAP / F5 WAF** | inside NIC & NGF | The WAF engine generating security events |
| **ELK** (Elasticsearch + Logstash) | `elk` ns | Ingests & parses NAP security logs |
| **Prometheus** (OCP User Workload Monitoring) | `openshift-monitoring` | Scrapes NIC & NGF metrics |
| **Grafana** (Grafana Operator) | `grafana` ns | Single pane of glass for all of the above |

**Data flow:**

- *Metrics:* NIC / NGF → Prometheus (Thanos) → Grafana
- *Security events:* NAP → syslog → Logstash → Elasticsearch → Grafana

---

## Part 0 — Open Grafana

1. On the **OCP Provisioner** desktop, open **Firefox**.
2. Use the bookmarked **Grafana** link (or browse to `https://grafana-grafana.apps.ocp.f5-udf.com`).
3. Log in with the lab-provided admin credentials.

You should land on the Grafana **Home** page.

---

## Part 1 — Explore the Data Sources

Data sources are *where Grafana reads from*. Understanding them first makes the dashboards make sense.

1. In the left menu, go to **Connections → Data sources**.
2. You'll see **three** data sources:

| Data source | Type | Reads from | Powers |
|---|---|---|---|
| **Prometheus** | Prometheus | Thanos Querier (OCP monitoring) | NIC & NGF **metrics** dashboards |
| **NAP-logs** | Elasticsearch | `nginx-nap-logs-*` index | NAP **security** dashboards (raw events) |
| **NAP-Decoded** | Elasticsearch | `nginx-nap-decoded-*` index | NAP **per-violation** drill-downs |

3. Click **NAP-logs**, then **Save & test** at the bottom. You should see a green *"data source is working"* — confirming Grafana can reach Elasticsearch.

> **Why two NAP data sources?** `NAP-logs` holds one document per request (good for counts, trends, top-N). `NAP-Decoded` explodes each request into one document *per violation*, so you can analyze individual attack signatures. Some dashboards use one, some use both.

**Checkpoint:** All three data sources test green.

---

## Part 2 — Tour the Dashboard Folders

1. Go to **Dashboards** in the left menu.
2. Notice dashboards are organized into **three folders**, by data plane / function:

   - **NIC - NGINX Ingress Controller** → NIC performance metrics
   - **NGF - NGINX Gateway Fabric** → NGF performance metrics
   - **WAF - NAP Security (NIC + NGF)** → WAF security events (shared by both data planes)

This structure mirrors reality: **metrics are per-data-plane**, but **WAF security events from both NIC and NGF flow into the same dashboards**, where you filter by source.

---

## Part 3 — NIC Metrics (generic ingress observability)

Open **NIC - NGINX Ingress Controller → NGINX Plus Ingress Controller**.

Walk through the sections and find these panels:

- **Environment Metrics** — *NGINX Plus Reload* status, *Last Reload Time*, *Network I/O*. Confirms the data plane is healthy and how recently config changed.
- **Ingress Metrics** — *HTTP Request Volume*, *Ingress Count*, *Ingress State* (UP/DOWN), *Zone Request Volume*, *Zone Error Rates*. This is your "is traffic flowing and is it healthy" view.
- **Upstream Metrics** — *Upstream Success Rate*, *Upstream Error Rate*, upstream UP/DOWN. Health of the backends NIC proxies to.
- **SSL Metrics** — *SSL Performance* (handshakes / failures).

**Try this:** Set the time range (top-right) to **Last 1 hour**. Note the *Ingress State = UP* and the request-volume spike when traffic is sent (you'll generate some in Part 6).

> These are *generic* NGINX metrics — the same signals you'd watch for any ingress workload, independent of WAF.

---

## Part 4 — NGF Metrics (Gateway API observability)

Open **NGF - NGINX Gateway Fabric → NGINX Gateway Fabric**.

This dashboard reads the same Prometheus data source but queries NGF's data-plane metrics (`nginx_*` families exposed by the NGF gateway pod). Look for request totals, response status breakdowns, and connection metrics.

> **NIC vs NGF:** both are NGINX data planes, but NIC implements the *Ingress* API while NGF implements the newer *Gateway* API. The metrics look similar because the underlying engine is NGINX Plus — the dashboards let you compare how each is performing.

---

## Part 5 — NAP / WAF Security Events (the main event)

Open the **WAF - NAP Security (NIC + NGF)** folder. You'll find seven dashboards:

| Dashboard | What it shows | Data source |
|---|---|---|
| **Main Dashboard** | Overview: attack counts, blocked vs alerted, severity, violations, top IPs / URLs / policies, requests-over-time | NAP-logs |
| **NAP - Attack Signatures** | Which signatures fired (e.g. *SQL-INJ expressions like "OR 1=1"*) | NAP-Decoded |
| **NAP - SupportIDs** | Per-request drill-down by Support ID (the ID shown on the "Request Rejected" page) | NAP-logs + NAP-Decoded |
| **Parameter Violations** | Violations tied to request parameters | NAP-logs |
| **Meta Character Violations** | Illegal meta-characters in values | NAP-logs |
| **File Types Violations** | Disallowed file-type requests | NAP-logs |
| **Protocol Violations** | HTTP protocol-level violations | NAP-logs |

Start with **Main Dashboard**. Key panels to understand:

- **Attacks** — total count of WAF events in the window.
- **Blocked vs Alerted** (pie) — *blocked* = request rejected; *alerted* = flagged but allowed. Shows enforcement mode at a glance.
- **Severity** — distribution across Severity-1…5 (5 = critical).
- **Violations** (table) — ranked violation types: `VIOL_ATTACK_SIGNATURE`, `VIOL_PARAMETER_VALUE_METACHAR`, `VIOL_BOT_CLIENT`, `VIOL_RATING_THREAT`, etc.
- **World Map** — geo of client IPs (will be empty in this lab — clients are internal lab IPs with no geolocation; that's expected).

> **Filter by source:** The dashboard filters at the top (*virtualServerName*, *Outcome*, *Severity*, *Device*, *Policy*) let you slice events. Because NIC and NGF NAP events land in the **same** indices, you use these filters to view one data plane vs the other.

---

## Part 6 — Generate live attack traffic

Now make the dashboards move. crAPI is reachable three ways in this lab:

1. **Direct** (unprotected) — `http://10.1.10.9:30080` — no WAF, for contrast.
2. **Through NIC + NAP** (protected) — `http://10.1.10.9:30000` with `Host: crapi.example.com`.
3. *(NGF path — see the manifests folder.)*

From a terminal on the provisioner, run the included script:

```bash
chmod +x manifests/generate-traffic.sh
./manifests/generate-traffic.sh
```

This sends a mix of **legitimate** requests (HTTP 200) and **attacks** — SQL injection, XSS, command injection, path traversal. The attacks return an HTML **"Request Rejected"** page with a **Support ID**.

**Try the contrast yourself:**

```bash
# Attack BLOCKED through the WAF (NIC) — returns "Request Rejected"
curl "http://10.1.10.9:30000/?id=1%27%20OR%201=1" -H "Host: crapi.example.com"

# Same attack DIRECT (no WAF) — crAPI serves the page normally
curl "http://10.1.10.9:30080/?id=1%27%20OR%201=1" -H "Host: crapi.example.com"
```

Wait ~15 seconds (Logstash → Elasticsearch lag), then return to Grafana.

---

## Part 7 — See your attacks appear

1. Open **WAF - NAP Security → Main Dashboard**.
2. Set the time range to **Last 15 minutes** and click **Refresh**.
3. Observe:
   - **Attacks** count jumps.
   - **Blocked vs Alerted** pie populates.
   - **Violations** table lists the types you triggered.
4. Click into **NAP - Attack Signatures** — find the SQL-injection signature names (e.g. *SQL-INJ expressions like "OR 1=1"*).
5. Grab a **Support ID** from one of your `curl` "Request Rejected" responses, open **NAP - SupportIDs**, and search for it — you'll see the full decoded detail of that single blocked request.

> **This is the payoff:** an attacker sees only a cryptic Support ID; you, in Grafana, see exactly which signature fired, on which parameter, from which client, against which policy.

---

## Reflection / discussion

- How do the **generic metrics** (Parts 3–4) differ in purpose from the **security events** (Part 5)? When would you look at each?
- The **same attack** is blocked via NIC but served raw via the direct path. What does that demonstrate about *where* protection lives?
- Why are NIC and NGF WAF events stored in **one** set of indices but their **metrics** kept in separate dashboards?

---

## Files in this bundle

| File | Purpose |
|---|---|
| `README.md` | This guide |
| `manifests/generate-traffic.sh` | Sends clean + malicious traffic at crAPI |
| `manifests/grafana-resources.yaml` | Reference: the datasource/folder/dashboard CRs (already applied) |
| `manifests/logstash.conf` | Reference: the Logstash pipeline parsing NAP logs into ELK |
| `manifests/2.gateway.yaml` | Reference: NGF Gateway (from the F5 NGF WAF lab) |
| `manifests/3.httproute.yaml` | Reference: NGF HTTPRoute |
| `manifests/4.policies.yaml` | Reference: NGF WAF policy definitions (ConfigMap) |
| `manifests/5.bundleserver.yaml` | Reference: NGF WAF bundle server (compiles policies) |

> The `manifests/` files are **reference material** showing how the environment is wired. The only file you *run* in this lab is `generate-traffic.sh`.

---

## Appendix — Quick troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| A NAP panel shows *No data* | Time range too narrow, or no recent traffic | Widen to *Last 24 hours*; re-run `generate-traffic.sh` |
| A panel shows a red triangle | Datasource not resolving | **Connections → Data sources →** open it → **Save & test** |
| *World Map* empty | Internal client IPs have no geolocation | Expected in this lab — not an error |
| Attack returns the crAPI page instead of "Request Rejected" | You hit the **direct** `:30080` path, not the WAF `:30000` path | Use `:30000` with `Host: crapi.example.com` |
