# Enforcing JWT authentication

This use case shows how to enforce JWT authentication

`cd` into the lab directory
```code
cd ~/f5-nginx-redhat-ocp-ph26/Part-2-Nginx-Gateway-Fabric/8.auth-jwt
```

Deploy the sample application
```code
oc apply -f 0.coffee.yaml
```

Verify that the pod is in the `Running` state

```code
oc get all
```

Output should be similar to

```code
NAME                          READY   STATUS    RESTARTS   AGE
pod/coffee-654ddf664b-f7hp2   1/1     Running   0          9s

NAME                 TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
service/coffee       ClusterIP   10.99.241.145   <none>        80/TCP    9s
service/kubernetes   ClusterIP   10.96.0.1       <none>        443/TCP   573d

NAME                     READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/coffee   1/1     1            1           9s

NAME                                DESIRED   CURRENT   READY   AGE
replicaset.apps/coffee-654ddf664b   1         1         1       9s
```

Create the gateway object. This deploys the NGINX Gateway Fabric dataplane pod in the current namespace
```code
oc apply -f 1.gateway.yaml
```

Check the NGINX Gateway Fabric dataplane pod status
```code
oc get pods
```

`gateway-nginx-6558bbcfdf-pd2lx` is the NGINX Gateway Fabric dataplane pod
```code
NAME                             READY   STATUS    RESTARTS   AGE
coffee-654ddf664b-f7hp2          1/1     Running   0          2m33s
gateway-nginx-6558bbcfdf-pd2lx   2/2     Running   0          20s
```

Check the gateway
```code
oc get gateway
```

Output should be similar to
```code
NAME      CLASS   ADDRESS          PROGRAMMED   AGE
gateway   nginx   10.101.164.103   True         41s
```

Check the NGINX Gateway Fabric Service
```code
oc get service
```

`gateway-nginx` is the NGINX Gateway Fabric dataplane service
```code
NAME            TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)        AGE
coffee          ClusterIP   10.99.241.145    <none>        80/TCP         3m4s
gateway-nginx   NodePort    10.101.164.103   <none>        80:30968/TCP   52s
kubernetes      ClusterIP   10.96.0.1        <none>        443/TCP        573d
```

Create the JWKS Secret
```code
oc create secret generic jwks-secret --from-file=auth=secret.jwks
```

Create the AuthenticationFilter 
```code
oc apply -f 2.authenticationfilter.yaml
```

Check the AuthenticationFilter
```code
oc describe authenticationfilter jwt-auth-file
```

Output should be similar to
```code
Name:         jwt-auth-file
Namespace:    default
Labels:       <none>
Annotations:  <none>
API Version:  gateway.nginx.org/v1alpha1
Kind:         AuthenticationFilter
Metadata:
  Creation Timestamp:  2026-04-13T14:08:47Z
  Generation:          1
  Resource Version:    109754523
  UID:                 a7445b30-5f54-45dc-8b77-b3c03023caf3
Spec:
  Jwt:
    File:
      Secret Ref:
        Name:   jwks-secret
    Key Cache:  1h
    Realm:      nginx-gateway
    Source:     File
  Type:         JWT
Status:
  Controllers:
    Conditions:
      Last Transition Time:  2026-04-13T14:08:48Z
      Message:               The AuthenticationFilter is accepted
      Observed Generation:   1
      Reason:                Accepted
      Status:                True
      Type:                  Accepted
    Controller Name:         gateway.nginx.org/nginx-gateway-controller
Events:                      <none>
```

Create the HTTP route that references the AuthenticationFilter
```code
oc apply -f 3.httproute.yaml
```

Check the HTTP route
```code
oc get httproute
```

Output should be similar to
```code
NAME     HOSTNAMES              AGE
coffee   ["cafe.example.com"]   3s
```

Get NGINX Gateway Fabric dataplane instance IP and HTTP port
```code
export NGF_IP=`oc get pod -l app.kubernetes.io/instance=ngf -o json|jq '.items[0].status.hostIP' -r`
export HTTP_PORT=`oc get svc gateway-nginx -o jsonpath='{.spec.ports[0].nodePort}'`
```

Check NGINX Gateway Fabric dataplane instance IP and HTTP port
```code
echo -e "NGF address: $NGF_IP\nHTTP port  : $HTTP_PORT"
```

Access the application without providing an authentication token
```code
curl -i --resolve cafe.example.com:$HTTP_PORT:$NGF_IP http://cafe.example.com:$HTTP_PORT
```

Output should be similar to
```code
HTTP/1.1 401 Unauthorized
Server: nginx
Date: Tue, 07 Oct 2025 11:43:46 GMT
Content-Type: text/html
Content-Length: 172
Connection: keep-alive
WWW-Authenticate: Bearer realm="JWT token required"

<html>
<head><title>401 Authorization Required</title></head>
<body>
<center><h1>401 Authorization Required</h1></center>
<hr><center>nginx</center>
</body>
</html>
```

Access the application again sending a valid JWT token
```code
curl -i --resolve cafe.example.com:$HTTP_PORT:$NGF_IP http://cafe.example.com:$HTTP_PORT -H "Authorization: Bearer `cat token.jwt`"
```

Output should be similar to
```code
HTTP/1.1 200 OK
Server: nginx
Date: Tue, 07 Oct 2025 11:45:36 GMT
Content-Type: text/plain
Content-Length: 156
Connection: keep-alive
Expires: Tue, 07 Oct 2025 11:45:35 GMT
Cache-Control: no-cache

Server address: 10.0.156.110:8080
Server name: coffee-56b44d4c55-g9gtj
Date: 07/Oct/2025:11:45:36 +0000
URI: /
Request ID: 5afec06d5432b68456477e806cf8a52e
```

Delete the lab

```code
oc delete -f .
oc delete secret jwks-secret
```
