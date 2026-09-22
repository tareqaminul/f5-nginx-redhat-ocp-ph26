#!/usr/bin/env bash
# Order matters: delete the ExternalLoadBalancer FIRST and let CIS remove the
# virtual server, otherwise a stale VIP can be left on the device.
NS=${NS:-gatewaylink-demo}
oc -n $NS delete -f 4.externalloadbalancer.yaml --ignore-not-found
echo "waiting for CIS to remove the virtual server..."; sleep 30
oc -n $NS get ingresslinks.cis.f5.com || true          # expect: no resources
oc -n $NS delete -f 3.routes.yaml -f 2.gateway.yaml -f 1.nginxproxy.yaml -f 0.apps.yaml --ignore-not-found
