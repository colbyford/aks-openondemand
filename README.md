# aks-openondemand

Deploy [Open OnDemand](https://openondemand.org/) on Azure Kubernetes Service
(AKS), and use its UI to launch JupyterLab, Jupyter Notebook, and shell-script
batch workloads.

## Architecture and scope

- `infra/main.bicep` provisions Linux AKS with Azure CNI/network policies,
  autoscaling, an Azure Container Registry (ACR), and a premium Azure Files NFS
  share. Storage access is restricted to the AKS subnet; ACR administration
  credentials are disabled and the kubelet receives `AcrPull`.
- `Dockerfile` installs Open OnDemand 4 on Rocky Linux 9. Apache runs in the
  foreground; no privileged container or systemd is needed. Open OnDemand's
  per-user NGINX/Passenger processes still require its normal root/sudo
  machinery inside the portal container.
- `charts/ondemand` deploys one authenticated portal and a separate workload
  namespace. The **supported unit is one user per release**, authenticated as
  the Unix account `ondemand` (UID/GID 1000). Use a separate hostname, password
  Secret, and dedicated NFS share for every release. Do not share one release's
  credentials or home directory between people. Release names (and any
  `fullnameOverride`) must be unique across the cluster, since the workload
  namespace is cluster-scoped.
- The upstream Kubernetes scheduler adapter submits **Pods**, not Kubernetes
  Jobs or Slurm jobs. The UI can track and cancel workloads. Interactive
  services use private AKS node IPs and NodePorts through Open OnDemand's
  authenticated `/node/` proxy; browsers need access only to the HTTPS portal.
- Both apps share `/home/ondemand` with the portal. Workload resource requests,
  limits, namespace quotas, admission rules, network policies, and execution
  timeouts constrain workloads. Sessions survive portal restarts through NFS.

This is a community deployment, not an OSC-supported production container or
a replacement for a multi-user HPC identity service. For a shared institutional
portal, integrate directory identities, per-user Kubernetes credentials/RBAC,
and storage authorization before extending this design.

## Prerequisites

Azure CLI, kubectl, Helm 3.13+, Docker (or ACR Build), and an Azure subscription
with permission to create resources and role assignments are required. AKS must
support `admissionregistration.k8s.io/v1` ValidatingAdmissionPolicy (Kubernetes
1.30+). The demo below uses the AKS Application Routing add-on for ingress. A
production deployment needs a hostname in DNS and a matching trusted TLS
certificate; the demo can use a local hosts-file entry and a self-signed
certificate instead.

These commands create billable Azure resources. Run them from an administrator
workstation. Set an **absolute** repository path:

```bash
export REPO=/absolute/path/to/aks-openondemand
export RG=ondemand-demo
export AKS=ood-aks
export LOCATION=eastus
export NS=ood-alice
export RELEASE=alice
export HOST=alice.ondemand.test

az login
az group create --name "$RG" --location "$LOCATION"
az deployment group create --name ondemand --resource-group "$RG" \
  --template-file "$REPO/infra/main.bicep" \
  --parameters clusterName="$AKS" nodeMinCount=1 nodeMaxCount=3
az aks get-credentials --resource-group "$RG" --name "$AKS"

# Install the managed ingress controller and wait for its public IP.
az aks approuting enable --resource-group "$RG" --name "$AKS"
kubectl -n app-routing-system get svc nginx --watch
```

Stop the watch after `EXTERNAL-IP` is assigned, then save the address:

```bash
export INGRESS_IP=$(kubectl -n app-routing-system get svc nginx \
  --output=jsonpath='{.status.loadBalancer.ingress[0].ip}')
printf '%s\n' "$INGRESS_IP"
```

The public LoadBalancer IP may take a few minutes to appear. The demo hostname
is local to your workstation; it does not require public DNS.

`nodeMinCount` must not exceed `nodeMaxCount`. Use a region supporting the chosen
VM size and premium Azure Files NFS. The infrastructure uses node subnet
`10.20.0.0/20` and service CIDR `10.21.0.0/16`; avoid overlapping connected
networks. The NFS share uses `NoRootSquash` so the portal can initialize the
home directory, and must remain restricted to trusted AKS nodes.

## Build the portal image

Use a kubectl version matching the cluster's actual patch version, including
the `v` prefix (available from `kubectl version --output=json`). The Dockerfile
verifies the downloaded kubectl binary's published SHA-256 checksum.

```bash
export REGISTRY=$(az deployment group show --name ondemand --resource-group "$RG" \
  --query properties.outputs.registryLoginServer.value --output tsv)
export NFS_SERVER=$(az deployment group show --name ondemand --resource-group "$RG" \
  --query properties.outputs.nfsServer.value --output tsv)
export NFS_PATH=$(az deployment group show --name ondemand --resource-group "$RG" \
  --query properties.outputs.nfsPath.value --output tsv)
export KUBECTL_VERSION=$(kubectl version --output=json | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])')

az acr build --registry "${REGISTRY%%.*}" --image ondemand:0.1.0 \
  --build-arg "KUBECTL_VERSION=$KUBECTL_VERSION" "$REPO"
```

The image targets Linux amd64 by default; pass the appropriate `TARGETARCH`
when building for another architecture. Rebuild regularly for OS/Open OnDemand
security updates. Use reviewed, versioned workload images with `bash`,
`timeout`, and Python 3; the Jupyter image must also contain Jupyter Server 2,
JupyterLab, and Notebook 7. For example, choose a reviewed version of
`quay.io/jupyter/base-notebook` for both apps. Do not use an unpinned `latest`
tag in production.

## Configure authentication, TLS, and networking

Create the portal namespace, then create Secrets **outside version control**:

```bash
kubectl create namespace "$NS"
kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=baseline
# htpasswd is supplied by Apache's administrator utilities. It prompts for a password.
AUTH_FILE=$(mktemp /tmp/ondemand-htpasswd.XXXXXX)
htpasswd -Bc "$AUTH_FILE" ondemand
kubectl -n "$NS" create secret generic ondemand-auth \
  --from-file="htpasswd=$AUTH_FILE"
rm "$AUTH_FILE"

# Demo only: create a self-signed certificate for the local demo hostname.
# For production, use a certificate issued by a trusted CA instead.
TLS_DIR=$(mktemp -d /tmp/ondemand-tls.XXXXXX)
openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
  -keyout "$TLS_DIR/tls.key" -out "$TLS_DIR/tls.crt" \
  -subj "/CN=$HOST" -addext "subjectAltName=DNS:$HOST"
chmod 600 "$TLS_DIR/tls.key"
kubectl -n "$NS" create secret tls ondemand-tls \
  --cert="$TLS_DIR/tls.crt" --key="$TLS_DIR/tls.key"
```

The authentication file must contain exactly one entry, named `ondemand`.
Sign in as `ondemand` with the password entered at the `htpasswd` prompt. The
self-signed certificate is not trusted by browsers, so expect a warning during
this demo. Never disable HTTPS: HTTP Basic authentication sends the password
on each request. The ingress must redirect/reject HTTP, honor the configured
hostname, and preserve WebSocket connections. Apache uses internal HTTP only;
do not publish its Service separately.

Get the API endpoint's IPv4 addresses for workload connection discovery:

```bash
export API_URL=$(kubectl config view --minify \
  --output=jsonpath='{.clusters[0].cluster.server}')
export API_CIDRS=$(python3 -c \
  'import json,socket,sys,urllib.parse; host=urllib.parse.urlparse(sys.argv[1]).hostname; print(json.dumps(sorted({r[4][0]+"/32" for r in socket.getaddrinfo(host,443,socket.AF_INET)})))' \
  "$API_URL")
```

Update these CIDRs if the API endpoint's addresses change. Network policy can
apply after Service DNAT, so allowing only `kubernetes.default`'s ClusterIP
is insufficient. Keep the AKS NodePort range (normally 30000–32767) private;
the portal must reach it within the node subnet. NodePort SNAT can change the
source address to a node IP, hence the explicit subnet allowance.

Create a local values file, substituting a reviewed workload image:

```bash
export WORKLOAD_IMAGE=quay.io/jupyter/base-notebook:YOUR_REVIEWED_TAG
cat > "$REPO/deployment.local.yaml" <<EOF
image:
  repository: ${REGISTRY}/ondemand
  tag: "0.1.0"
auth:
  existingSecret: ondemand-auth
ingress:
  className: webapprouting.kubernetes.azure.com
  host: ${HOST}
  tlsSecret: ondemand-tls
nfs:
  server: ${NFS_SERVER}
  path: ${NFS_PATH}
apps:
  jupyterImage: ${WORKLOAD_IMAGE}
  batchImage: ${WORKLOAD_IMAGE}
networkPolicy:
  nodeSubnetCIDR: 10.20.0.0/20
  nodeHostRegex: '10\.20\.(?:[0-9]|1[0-5])\.[0-9]{1,3}'
EOF
```

Use your controller's class and annotations if it is not the AKS Application
Routing add-on.
`nodeHostRegex` must match only actual AKS node addresses/hostnames; never use
an arbitrary-host wildcard. The supplied Jupyter app uses the node's IPv4
address and configures its base URL for Open OnDemand's `/node/` proxy.
Do not set pod-level `runAsUser` or `runAsGroup`: Kubernetes makes projected
service-account tokens mode `0600` when a UID is specified, but the Open
OnDemand PUN reads the token as `ondemand` (UID 1000). The chart relies on the
image's root defaults for Apache and switches to `ondemand` for the PUN.

## Install and use

```bash
helm lint "$REPO/charts/ondemand" --values "$REPO/deployment.local.yaml" \
  --set-json "networkPolicy.apiServerCIDRs=$API_CIDRS"
helm upgrade --install "$RELEASE" "$REPO/charts/ondemand" --namespace "$NS" \
  --values "$REPO/deployment.local.yaml" \
  --set-json "networkPolicy.apiServerCIDRs=$API_CIDRS" \
  --wait --timeout 10m
kubectl -n "$NS" get pods,services,ingress
kubectl -n app-routing-system get svc nginx -o wide
```

Use the controller Service's `EXTERNAL-IP` as the public IP; the Ingress
`ADDRESS` column may remain blank.

For this local demo, map the hostname to the ingress IP on your workstation.
Print the line to add to its hosts file:

```bash
printf '%s %s\n' "$INGRESS_IP" "$HOST"
```

On macOS/Linux, append the printed line to `/etc/hosts`; on Windows, add it to
`C:\Windows\System32\drivers\etc\hosts`. This mapping is local to that
workstation. Then open `https://$HOST` and authenticate as `ondemand` with the
password you chose. For a public deployment, create a DNS record pointing the
hostname to the ingress IP and use a trusted certificate.

1. Open **Interactive Apps → Jupyter**, choose JupyterLab or Notebook, CPU,
   memory, and duration, and launch. In **My Interactive Sessions**, wait for
   the session to run, then connect. Each session has a random token in addition
   to portal authentication; XSRF protection remains enabled.
2. Use **Files** to create/upload a `.sh` file in your home directory, e.g.
   `scripts/hello.sh`, containing `echo "Hello from AKS"; date`.
3. Open the **Batch** interactive application and submit that relative path.
   The app launches a non-interactive Pod and writes `output.log` and its exit
   status in the session's output directory on NFS. View these through Files.
4. Use the session's delete/cancel action to stop an active workload. App
   execution is limited to the requested duration; the adapter's wall-time
   annotation alone is not an enforced deadline. Completed workloads require
   the administrator cleanup described below.

These are Kubernetes-native apps, not the standard Job Composer submission
templates. Slurm directives, job arrays, scheduler dependencies, SSH into
worker nodes, and desktop/VNC sessions are not provided. Add further application
templates under `charts/ondemand/files/apps`, with the matching ConfigMap
mounts in `templates/apps.yaml` and `templates/deployment.yaml`.

## Verification and operations

After installation, check an unauthenticated HTTPS request is denied or
challenges for authentication, then log in and exercise **both** Jupyter modes
(including kernel execution and WebSockets), a successful batch script, a
failing script, cancellation, and the configured duration limit. Confirm files persist after
a portal restart. In the workload namespace, check Pods run as UID/GID 1000,
privileged/hostPath/other-user NFS mounts are rejected, quotas apply, and the
default service account cannot create Pods or read Secrets.

```bash
kubectl -n "$NS" logs deployment/"${RELEASE}-ondemand"
kubectl get namespaces
# Use the generated workload namespace, normally <release>-ondemand-jobs-ondemand.
kubectl -n "${RELEASE}-ondemand-jobs-ondemand" get pods,services
kubectl -n "${RELEASE}-ondemand-jobs-ondemand" describe pod POD_NAME
```

**Completed-resource cleanup is required.** Open OnDemand skips scheduler
deletion for sessions already marked completed, and the adapter does not add
garbage-collection owner references. Deleting completed UI entries therefore
does not remove their Pods/ConfigMaps. Clean them up periodically to avoid
exhausting namespace quotas. For an individual Pod confirmed `Succeeded` or
`Failed`:

```bash
JOBS_NS="${RELEASE}-ondemand-jobs-ondemand"
POD=YOUR_COMPLETED_POD_NAME
kubectl -n "$JOBS_NS" get pod "$POD" --output=jsonpath='{.status.phase}'
# Only after confirming the Pod is finished:
kubectl -n "$JOBS_NS" delete "pod/$POD" "service/${POD}-service" \
  "configmap/${POD}-configmap" "secret/${POD}-secret" --ignore-not-found
```

Alternatively, **only after all sessions have stopped**, remove all
adapter-managed resources (this preserves the namespace's API CA ConfigMap):

```bash
kubectl -n "$JOBS_NS" delete pod,service,configmap,secret \
  --selector=app.kubernetes.io/managed-by=open-ondemand
```

The portal credential can manage workloads only in its workload namespace.
Workloads receive a separate read-only Pod/Service credential to discover their
connection endpoint. Neither has cluster-admin permissions. Network policies
limit workload egress to DNS, the specified API endpoint, and public IPv4
destinations; add narrowly scoped rules if your jobs need private data services.
The baseline Pod Security profile permits the adapter's inline NFS volumes;
additional admission rules enforce the expected identity and permitted export.
Do not grant workload users access to modify those policies, namespaces, or
role bindings. Namespace isolation is not a substitute for hard multi-tenant
node/storage isolation.

`helm uninstall "$RELEASE" --namespace "$NS"` removes the portal and chart
resources; user storage is retained. Back up NFS first and check for remaining
Pods, services, namespaces, and retained storage before deleting Azure
resources. To remove the entire demo, explicitly delete its resource group:
`az group delete --name "$RG"`. This permanently deletes the NFS account/data.

Local validation includes Helm lint/template rendering, Bicep compilation,
and shell syntax checks. No live Azure deployment is implied by these checks.
The portal image build needs access to Rocky/EPEL/OSC package repositories and
`dl.k8s.io`; application pulls need access to your chosen registry.

### Upstream references

- [Kubernetes adapter configuration](https://github.com/OSC/ood-documentation/blob/master/source/installation/resource-manager/kubernetes.rst)
- [Kubernetes interactive apps](https://github.com/OSC/ood-documentation/blob/master/source/tutorials/tutorials-interactive-apps/k8s-jupyter.rst)
- [OSC example container](https://github.com/OSC/ondemand/blob/master/Dockerfile.example)
