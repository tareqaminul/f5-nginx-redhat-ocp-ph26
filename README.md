# NGF basics

# NGF for OpenShift

## CRDs






## What `NginxGatewayFabric` is

It's the **operator's umbrella CR** — the single object you create and edit, which the Helm-based operator expands into a full NGF installation. The NGINX Gateway Fabric Operator deploys and manages one or more NGINX Gateway Fabric control planes, which in turn handle the NGINX/NGINX Plus deployments. Each `NginxGatewayFabric` you create = one complete NGF install (one control plane + its config).

Crucially, it **owns and generates** the other two CRDs. You saw this directly in the NginxProxy YAML dump the other day — its `ownerReferences` pointed back at `kind: NginxGatewayFabric`. So the hierarchy is:

```
NginxGatewayFabric              ← you edit THIS (operator/Helm-values layer)
  └─ owns & generates ─┐
       ├─ NginxGateway       → control plane config (logging level)
       └─ NginxProxy         → data plane config (Service, Deployment, NGINX settings)
```

Editing `NginxGateway`/`NginxProxy` directly gets reconciled away — they're outputs, not inputs. The operator CR's `spec.nginxGateway.*` feeds the NginxGateway; its `spec.nginx.*` feeds the NginxProxy.


## NginxGatewayFabric vs NginxGateway vs NginxProxy

| | **NginxGatewayFabric** | NginxGateway | NginxProxy |
|---|---|---|---|
| Role | Operator umbrella / install CR | Control plane config | Data plane config |
| You edit it? | **Yes — this is the input** | No (generated) | No (generated) |
| Group/Version | `gateway.nginx.org/v1alpha1` | `gateway.nginx.org` (confirm) | `gateway.nginx.org/v1alpha2` |
| Owns | NginxGateway + NginxProxy | — | — |
| Typical contents | `spec.nginxGateway.*`, `spec.nginx.*`, `plus`, image, replicas | `logging.level` | `kubernetes.*`, `ipFamily`, `disableHTTP2`, metrics, telemetry |
| Wired up by | OLM / the operator | controller `--nginx-gateway-config-name` | GatewayClass `parametersRef` or a Gateway |
| Count in your cluster | **2** (nginx-gateway, crapi) | 1 per fabric instance | 1 per fabric instance |

`NginxGatewayFabric` is the dial you turn; `NginxGateway` and `NginxProxy` are the readouts it drives, one per plane.


