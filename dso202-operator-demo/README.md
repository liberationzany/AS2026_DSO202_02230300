# DSO202 — Operator Demo: StaticSite CRD and Controller

## Purpose

Worked example for Unit II 2.4 (CRDs, controllers and operators) together
with 2.3 (RBAC). It adds a new kind, `StaticSite`, to the cluster. A
controller then keeps a ConfigMap, a Deployment and a ClusterIP Service in
place for every StaticSite. The controller is a bash loop that uses
`kubectl` as its API client. It first runs from the laptop and then inside
the cluster under a least-privilege ServiceAccount.

Runs on the three-node `dso202` kind cluster from Practical 1.

## Files

```
dso202-operator-demo/
├── 01-crd-staticsite.yaml        # the type declaration (schema, CEL rules, status subresource)
├── 02-staticsite-sample.yaml     # one instance of that type
├── 03-rbac-controller.yaml       # ServiceAccount, ClusterRole, ClusterRoleBinding
├── 04-controller-deployment.yaml # the controller running inside the cluster
├── reconcile.sh                  # the reconciliation loop
└── Dockerfile                    # alpine + bash + kubectl image for the in-cluster controller
```

## Run it

```bash
# Stage 1 — namespace
kubectl create namespace dso202-operators
kubectl config set-context --current --namespace=dso202-operators

# Stage 2–3 — register the type, create one object (nothing runs yet)
kubectl apply -f 01-crd-staticsite.yaml
kubectl wait --for=condition=Established crd/staticsites.dso202.cst.edu.bt
kubectl apply -f 02-staticsite-sample.yaml
kubectl get staticsites

# Stage 6 — run the controller from the laptop (Git Bash / WSL), leave it running
bash reconcile.sh

# Stage 7 — change desired state
kubectl patch staticsite welcome --type=merge -p '{"spec":{"replicas":4}}'

# Stage 8 — delete a child and watch the loop recreate it
kubectl delete deployment site-welcome

# Stage 9 — delete the owner; garbage collection removes the children
kubectl delete staticsite welcome
```

### Stage 10 — run the controller inside the cluster

Stop the laptop loop (Ctrl+C) first. Two copies of the loop would fight
over the status writes.

```bash
docker build -t dso202/staticsite-controller:1.0 .
kind load docker-image dso202/staticsite-controller:1.0 --name dso202

kubectl create configmap staticsite-controller-script --from-file=reconcile.sh
kubectl apply -f 03-rbac-controller.yaml -f 04-controller-deployment.yaml
kubectl apply -f 02-staticsite-sample.yaml
kubectl logs -l app.kubernetes.io/name=staticsite-controller --tail=4

# Least privilege, checked directly: expect no / no / yes
SA=system:serviceaccount:dso202-operators:staticsite-controller
kubectl auth can-i delete deployments      --as=$SA
kubectl auth can-i get secrets             --as=$SA
kubectl auth can-i patch staticsites/status --as=$SA
```

## Changes from the lecture listing

- The notes' PDF cuts off three long lines in `reconcile.sh`: the `phase`
  assignment, the status patch body and the list jsonpath. They were
  rebuilt from the fields the loop reads and the CRD's `status` schema
  (`phase`, `readyReplicas`, `observedGeneration`).
- `04-controller-deployment.yaml` sets `HOME=/tmp` on an `emptyDir`. The
  image runs as UID 65532, which has no home directory, and `kubectl` writes
  its discovery cache under `$HOME`. The same change adds a restrictive
  `securityContext` (non-root, no privilege escalation, read-only root
  filesystem).

## Cleanup

Delete in reverse order. The CRD goes last because deleting it removes
every StaticSite at once.

```bash
kubectl delete -f 04-controller-deployment.yaml -f 03-rbac-controller.yaml
kubectl delete configmap staticsite-controller-script
kubectl delete staticsites --all
kubectl delete -f 01-crd-staticsite.yaml
kubectl delete namespace dso202-operators
kubectl config set-context --current --namespace=default
```
