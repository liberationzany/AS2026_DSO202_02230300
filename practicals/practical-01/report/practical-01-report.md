# DSO202 — Practical 1 Report

Set up a local Kubernetes cluster using Minikube or Kind; core kubectl operations.

## 1. Objective

This practical builds the local Kubernetes environment used throughout
DSO202. Its purpose is to stand up a three-node `kind` cluster and use it
to create, inspect, and troubleshoot the five categories of object that
Unit I introduces: cluster/node components, namespaces with resource
governance (ResourceQuota/LimitRange), Pods, Deployments (ReplicaSets and
rolling updates), and Services (ClusterIP and NodePort).

Descriptor sections covered: Unit I 1.1, 1.2.1–1.2.4, 1.3.1, 1.3.2, 1.3.3,
1.4.1, 1.5.1, 1.5.3. Learning outcomes addressed: LO1 (core concepts and
architecture), LO2 (deploying and managing applications via Pods,
Deployments, Services), LO3 (kubectl for cluster management and
troubleshooting), and the multi-tenancy half of LO5 (namespace-based
isolation via Namespace + ResourceQuota + LimitRange).

## 2. Environment

| Field                 | Value                        |
|------------------------|-------------------------------|
| Operating system        | Windows 11 (build 10.0.26200) |
| Docker Desktop version  | 29.4.0                        |
| kind version             | v0.32.0 (windows/amd64)       |
| kubectl client version   | v1.36.3                       |
| Cluster Kubernetes version | v1.36.1 (`kindest/node:v1.36.1`) |
| Host resources reported by Docker | 8 CPUs, ~7.7 GiB memory |

## 3. Procedure and Observations

### Stage 0 — Prerequisites

`docker info`, `kind version`, and `kubectl version --client` were run to
confirm all three tools were installed and the Docker daemon reachable.
Docker Desktop was initially not running (`failed to connect to the
docker API at npipe:...`); starting it resolved the check. Host resources
(8 CPUs, ~7.7 GiB) exceed the stated minimum of 4 GiB / 2 CPUs.

### Stage 1 — Cluster creation

`cluster/kind-cluster.yaml` (Listing 1) defines a three-node cluster
(`control-plane`, `worker-node-1`, `worker-node-2`) with the API server
bound to `127.0.0.1`, an explicit Pod subnet (`10.244.0.0/16`) and Service
subnet (`10.96.0.0/16`), and host port 30080 published from the
control-plane container for the NodePort Service used later.

`kind get clusters` reported `dso202` and `kubectl config current-context`
reported `kind-dso202`, matching the checkpoint. `kubectl get nodes -o
wide` confirmed all three Node objects `Ready`, with the custom names set
by the `kubeadmConfigPatches` in Listing 1 (`control-plane`,
`worker-node-1`, `worker-node-2`) rather than kind's default Docker
container names — proving the patch worked. See `evidence/final-state-nodes.txt`.

### Stage 2 — Inspecting the cluster

`kubectl get pods -n kube-system -o wide` showed the expected pattern:
`etcd`, `kube-apiserver`, `kube-controller-manager`, and `kube-scheduler`
each appear once, on `control-plane` only; `kube-proxy` and `kindnet`
appear three times, once per node (DaemonSets); `coredns` appears twice,
both on `control-plane`, because the control-plane taint is tolerated by
CoreDNS but not by ordinary Pods. `kubectl api-resources` confirmed Nodes,
Namespaces, PersistentVolumes, and StorageClasses are cluster-scoped while
Pods, Services, Deployments, ResourceQuotas, and LimitRanges are
namespaced.

### Stage 3 — Namespace, ResourceQuota, LimitRange

`manifests/00-namespace.yaml` (Listing 2) creates namespace
`dso202-practical-01` with labels and annotations. `manifests/01-quota-and-limits.yaml`
(Listing 3) applies a ResourceQuota (`dso202-quota`) and a LimitRange
(`dso202-limits`) in one file, separated by `---`.

`kubectl describe resourcequota dso202-quota` (see
`evidence/resourcequota-describe.txt`) showed `count/configmaps` already at
`1/10` before any work was done, because every namespace receives a
`kube-root-ca.crt` ConfigMap automatically — the quota's `Used` column
counts objects the cluster itself created, not only student-created ones.

The default namespace for the `kind-dso202` context was set with
`kubectl config set-context --current --namespace=dso202-practical-01`, so
all later commands omit `-n`.

### Stage 4 — Pods

`manifests/02-pod-web.yaml` (Listing 4) was applied, creating `web-pod`
running `nginx:1.30-alpine`. Re-applying the same file printed
`pod/web-pod unchanged` — the declarative-management contract: applying
an unmodified manifest is a no-op.

The first image pull took over six minutes; `kubectl describe pod
web-pod` showed the Pod stuck on the `Pulling` event with no error, and a
manual `crictl pull` on the worker node from a separate shell confirmed
this was a slow pull, not a failure — the Pod reached `1/1 Running` once
the pull finished. This is the kind of situation Stage 8.5's guidance
("read the Events: section first, not last") is written for.

`kubectl get pods --show-labels` confirmed the four labels applied by the
manifest (`app`, `tier`, `dso202/practical`, `dso202/managed-by`).
`kubectl logs`, `kubectl exec ... -- nginx -v`, and `kubectl explain
pod.spec.containers.resources` all produced the expected output.

### Stage 5 — Deployments

`manifests/03-deployment-web.yaml` (Listing 5) was applied and reached
`3/3 READY` after `kubectl rollout status`. The three-level ownership
chain was confirmed with `kubectl get deployment,replicaset,pod -l
app=web` and by reading the ReplicaSet's `ownerReferences`, which named
`Deployment/web-deployment`.

**Self-healing.** One Deployment-managed Pod was deleted directly. A
replacement appeared within seconds carrying the same ReplicaSet prefix
and a new random suffix — the ReplicaSet's control loop, not the
Deployment, performed the recreation.

**Scaling.** `kubectl scale --replicas=5` produced `5/5`; re-applying the
unmodified manifest returned the Deployment to `3/3`, demonstrating that
the manifest — not the last imperative command — is authoritative once a
declarative workflow is in use.

**Rolling update and rollback.** `kubectl set image ... web=nginx:1.31-alpine`
triggered a new ReplicaSet; with `maxUnavailable: 0` and `maxSurge: 1`,
`kubectl rollout status` showed replicas being added and readied before
any old replica terminated. `kubectl rollout undo` returned the Deployment
to `nginx:1.30-alpine`.

**Failed rollout.** Setting the image to `nginx:9.99-does-not-exist`
produced a stalled rollout (`ErrImagePull` on the new Pod) while all
three original replicas stayed `Running` throughout — `maxUnavailable: 0`
converted a bad release into a stalled release rather than an outage, as
the guide predicts. `kubectl rollout undo` recovered the Deployment.

The manifest was re-applied a final time and `kubectl diff -f
manifests/03-deployment-web.yaml` printed no output, confirming the live
Deployment now matches the committed file exactly.

### Stage 6 — Services

`manifests/04-service-clusterip.yaml` (Listing 6) was applied. The
generated EndpointSlice listed **four** addresses, not three: the three
`web-deployment` replicas plus `web-pod` from Stage 4, because `web-pod`
carries the same `app=web,tier=frontend` labels the Service selects on.
This is a genuine and instructive observation — a Service selects on
labels, not on ownership, so any Pod with matching labels receives
traffic regardless of which controller (or no controller) created it.

`kubectl exec client-pod -- nslookup web-clusterip` resolved to the
Service's ClusterIP via the fully-qualified name
`web-clusterip.dso202-practical-01.svc.cluster.local`. Requests through
the Service were distributed across the four matching Pods (confirmed by
writing a distinct `index.html` per Pod and sampling nine requests).

`manifests/05-service-nodeport.yaml` (Listing 7) opened port 30080 on
every node. `curl http://localhost:30080` from the host initially
returned "connection refused" for a few seconds immediately after the
Service was created — `kube-proxy` had not yet programmed the
`KUBE-NODEPORTS` iptables chain — then succeeded once the rule appeared
(confirmed with `docker exec dso202-control-plane iptables -t nat -L
KUBE-NODEPORTS`). The same request succeeded from inside the
`dso202-worker` container as well, confirming the port is opened on every
node, not only the one Listing 1 published to the host.

The broken-selector fault was reproduced with `kubectl create service
clusterip broken-service --tcp=80:80`: the generated selector
(`app=broken-service`) matched no Pod, and the resulting EndpointSlice
showed `<unset>` endpoints — the diagnostic signature described in the
guide.

### Stage 7 — Evidence capture

Final-state evidence (`kubectl get all`, `resourcequota`, `limitrange`,
`endpointslice`, `nodes`, `events`, and the stored Pod YAML) was written
to `evidence/`. Full cluster teardown (`kind delete cluster`) was left
for the student/operator to run deliberately, since it is destructive and
this cluster is reused across later work in the module.

## 4. Analysis

**Why a Deployment and not a bare Pod for production workloads?** A bare
Pod (Stage 4) has no controller watching it — deleting it, or losing the
node it runs on, is permanent. A Deployment's ReplicaSet continuously
reconciles the live Pod count against the desired count, which is what
made the self-healing and rolling-update demonstrations possible in
Stage 5.

**Why does a ResourceQuota require a LimitRange in practice?** Once a
ResourceQuota sets a hard cap on `requests.cpu`/`requests.memory`, the API
server rejects any Pod whose containers don't declare those fields
explicitly. A LimitRange supplies defaults for containers that omit them,
so quick imperative Pods (e.g. `kubectl run`) still succeed without every
command needing an inline resource declaration.

**Why did the NodePort Service briefly refuse connections?** Creating the
Service object and `kube-proxy` actually programming the corresponding
iptables/IPVS rule on each node are two separate, asynchronous steps.
Between them there is a short window where the node is listening at the
Docker layer (the port mapping from Listing 1 exists immediately) but not
yet forwarding at the kube-proxy layer.

**Why did the ClusterIP Service route to four Pods, not three?** Services
route by label selector, not by ownership. `web-pod` (Stage 4) and the
Deployment's three replicas (Stage 5) share the labels `app=web,
tier=frontend`, so the Service — which only checks the selector and
Pod readiness — treats all four as valid backends. This is the same
mechanism the guide's "broken selector" demonstration relies on, seen
from the opposite side: a selector that matches *too much* is just as
real a fault class as one that matches nothing.

## 5. Reflection

The most time-consuming part was not a Kubernetes concept but an
operational one: the first `nginx:1.30-alpine` pull took over six minutes
with no error reported, so the Pod sat in `ContainerCreating` long enough
to look stuck. Diagnosing it correctly meant reading `kubectl describe
pod`'s `Events:` section rather than assuming a misconfiguration, and
independently confirming network access with `crictl pull` from inside
the node container. This reinforced the guide's own advice in section
8.5/8.6: when a Pod misbehaves, the events section is the first place to
look, not the last.

A second point worth recording: the guide's Stage 6 narrative states the
EndpointSlice for `web-clusterip` will list three addresses "matching the
three ready Pods of web-deployment", but because `web-pod` from Stage 4
was never deleted and carries the same selector labels, four addresses
appeared in this run. This was not a misconfiguration — it is the
correct, documented behaviour of label-based selection — but it shows
that the guide's expected output implicitly assumes objects from earlier
stages have been cleaned up, which was not explicit in the instructions
at that point.

If repeating this practical, I would apply `manifests/02-pod-web.yaml`
with a label deliberately distinct from the Deployment's Pod template
(or delete `web-pod` before Stage 6) so the EndpointSlice count matches
the guide's narrative exactly, and I would pre-pull images with `docker
exec <node> crictl pull <image>` before timing any stage that depends on
a fresh image being available.

One thing that remains unclear: `practical1.pdf` references a "Stage 11
Step 2" / "section 21 review questions" and manifest filenames
(`03-pod-probes.yaml`, `05-pod-multicontainer.yaml`,
`08-service-nodeport.yaml`, `09-pod-client.yaml`) that do not correspond
to the eight listings actually defined in the companion manifest file —
the companion file's own listing index only goes up to Listing 8
(`06-pod-client.yaml`). The two documents appear to have been generated
against slightly different intended structures. This report follows the
companion file's Listing index as authoritative, since it is the file
explicitly marked as the source of "every YAML listing referenced" by the
guide.

## 6. References

- kind documentation, Quick Start / Configuration — https://kind.sigs.k8s.io/docs/user/quick-start/ — accessed 2026-09-01
- Kubernetes documentation, kubectl reference — https://kubernetes.io/docs/reference/kubectl/ — accessed 2026-09-01
- Kubernetes documentation, ResourceQuota and LimitRange concepts — https://kubernetes.io/docs/concepts/policy/resource-quotas/ — accessed 2026-09-01
- `DSO202_Practical1_Guide.md` (course-provided, rendered as `practical1.pdf`) — accessed 2026-09-01
- `DSO202_Practical1_Manifests.md` (course-provided, rendered as `manifest.pdf`) — accessed 2026-09-01
