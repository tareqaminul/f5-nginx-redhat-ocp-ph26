# Intro

## LAB Readiness
This Blueprint will give you a default Openshift environment without CIS, Aspen Mesh or NGINX, but it is ready to get them added.

***BIG-IP 1NIC mode is no longer needed*** Please note that the cluster built in this blueprint uses the internal network 10.1.10.0/24 so it is possible to use BIG-IP with more than one interface.In previous versions of this blueprint it was needed to use BIG-IP in 1nic mode.

# Additional Openshift setup:

- Ansible
- OpenEBS storage provider
- Image registry. 
- Setup of a CA (in /usr/share/nginx/html/installations/CA/easy-ca/bd.f5.com)
- Setup of DNS wildcard zones for OCP default Ingress (*.apps.ocp.f5-udf.com) and AM Ingress gateway (*.am.ocp.f5-udf.com)

This Openshift cluster has 3 masters and 2 workers (masters are scheduleable too). 

If you want any enhancement or you find that something doesn't work please contact me.

# Using the Deployment

The node that is used as jumphost is named ocp-provider, it is used for both CLI and UI.

## Using the CLI

SSH into ocp-provider with login name cloud-user. From there you can run the oc and kubectl tools.

The first time that you boot the deployment, apply the following procedure until you see that all the nodes are in Ready state:

```
oc config use-context default/api-ocp-f5-udf-com:6443/recovery

while date ; do
  oc get nodes
  oc get co | egrep 'VERSION|4.[0-9]+.[0-9]+[[:space:]]+False'
  oc get csr --no-headers | grep Pending | awk '{print $1}' | xargs --no-run-if-empty oc  adm certificate approve
  sleep 5
done
```
And wait until the output settles. At some point all nodes should be Ready and no cluster operator should be shown in False in the AVAILABLE column

In subsequent boots just use the f5admin account as shown next after 5-10 mins, or check with oc get co until all cluster operators are fine.

```
oc login -u f5admin -p f5admin # the f5admin user has cluster-admin permissions
```
And wait until the cluster is UP :

```
watch oc get co
```

If after 15-20min you are still unable to login, and you get connection problems, apply the procedure recommended to get the nodes into Ready state.

## Using the OpenShift UI:
 
You can use the UI either using XRDP or Firefox SaaS, using the HTTP auth provider and the f5admin/f5admin credentials when prompted in the browser:

- Use the XRDP link of the ocp-provisioner node and open a browser with https://console-openshift-console.apps.$CLUSTER.f5-udf.com/ 
- Use the FIREFOX link of the ocp-provisioner node. With this you will be running a docker firefox remotely inside your browser, from there you can browse to the OpenShift UI URLs (or any other). 

```
# In the OCP Provisioner start the Firefox docker container
docker start firefox
# Verify
docker ps
docker ps -a

# If Firefox fails to start, re-create the container
docker run -d \
    --name=firefox \
    --network host \
    -p 5800:5800 \
    -v ~/firefox-saas:/config:rw \
    jlesage/firefox
```

This uses makes use of the following https://hub.docker.com/r/jlesage/firefox and is launched as follows
Refresh if required: docker stop firefox, docker rm firefox ...

## Using the registry

Sample usage from the ocp-provider host:

```
    docker login -u <your docker account>
    docker pull docker.io/nginx
    registry=default-route-openshift-image-registry.apps.ocp.f5-udf.com
    docker tag nginx $registry/registry-images/nginx
    oc login -u f5admin -p f5admin
    oc create ns registry-images
    docker login -u f5admin -p $(oc whoami -t) $registry
    docker push $registry/registry-images/nginx
```
