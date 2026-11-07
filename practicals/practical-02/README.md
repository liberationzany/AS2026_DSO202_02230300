# DSO202 — Practical 2: Persistent Storage for a Stateful Application

## Purpose

Shows how Kubernetes stores data that must outlive a Pod, on a three-node
`kind` cluster. Covers:

- static provisioning: a hand-written PersistentVolume backed by a host directory
- dynamic provisioning through StorageClasses, and the `Delete` and `Retain` reclaim policies
- why a Deployment cannot give each replica its own state
- StatefulSets: stable names, private volumes, per-Pod DNS, ordered and partitioned updates
- a real PostgreSQL database whose rows survive Pod deletion

Descriptor sections: Unit I 1.2, 1.3.3, 1.4.1–1.4.3, 1.5.1, 1.5.3;
Unit II 2.1.1–2.1.4.

## Software and image versions used

| Tool / image             | Version                                        |
|--------------------------|------------------------------------------------|
| OS                       | Windows 11 (build 10.0.26300), Git Bash shell  |
| Docker Desktop           | 29.4.0 (WSL 2 backend, 8 CPUs, 7.7 GiB)        |
| kind                     | v0.32.0 (windows/amd64)                        |
| kubectl (client)         | v1.36.3                                        |
| Kubernetes (cluster)     | v1.36.1 (`kindest/node`, pinned by digest)     |
| `busybox`                | 1.37                                           |
| `nginx`                  | 1.30-alpine → 1.31-alpine (Stage 6 rollout)    |
| `postgres`               | 18-alpine (reported PostgreSQL 18.6)           |
| Storage provisioner      | `rancher.io/local-path` (installed by kind)    |

## Repository structure

```
practical-02/
├── README.md
├── cluster/
│   ├── kind-cluster.yaml             # Listing 1
│   └── kind-cluster-fallback.yaml    # Listing 1B (not needed in this run)
├── manifests/
│   ├── 00-namespace.yaml             # Listing 2
│   ├── 01-quota-and-limits.yaml      # Listing 3
│   ├── 02-storageclass-retain.yaml   # Listing 4  (cluster-scoped)
│   ├── 03-pv-static.yaml             # Listing 5  (cluster-scoped)
│   ├── 04-pvc-static.yaml            # Listing 6
│   ├── 05-pod-static-writer.yaml     # Listing 7
│   ├── 06-pvc-dynamic.yaml           # Listing 8
│   ├── 07-pod-dynamic-writer.yaml    # Listing 9
│   ├── 08-deployment-shared-pvc.yaml # Listing 10 (deliberate anti-pattern)
│   ├── 09-service-webnote.yaml       # Listing 11
│   ├── 10-statefulset-webnote.yaml   # Listing 12 (edited in Stage 6)
│   ├── 11-pod-client.yaml            # Listing 13
│   ├── 12-secret-postgres.yaml       # Listing 14
│   ├── 13-service-postgres.yaml      # Listing 15
│   └── 14-statefulset-postgres.yaml  # Listing 16
├── evidence/                         # captured command output, one file per stage
│   └── tasktracker-dump.sql          # pg_dump taken before cleanup
└── report/
    └── practical-02-report.md
```

Every namespaced object carries `namespace: dso202-practical-02`. The
StorageClass and the PersistentVolume are cluster-scoped and carry none.
Every object uses the same label keys: `app`, `tier`, `dso202/practical`
and `dso202/managed-by`.

## Windows-specific notes

The guide assumes a WSL 2 shell. This run used Git Bash on Windows, which
needs two changes:

1. **Host directory.** `/tmp/dso202-p2-storage` is replaced by
   `C:/Users/zeroe/dso202-p2-storage` in both cluster files. It is kept
   outside the OneDrive-synced folder so the sync client cannot lock or
   upload files while the node writes to them. Docker Desktop mounted it
   into `worker-node-1` with no further configuration.
2. **Path conversion.** Git Bash rewrites arguments that look like Unix
   paths. For example, `kubectl exec ... -- cat /data/ledger.txt` would be
   sent with a Windows path in place of `/data/ledger.txt`. Export
   `MSYS_NO_PATHCONV=1` before running the commands below. WSL, Linux and
   macOS do not need this.

## Rebuilding from an empty machine

```bash
export MSYS_NO_PATHCONV=1          # Git Bash on Windows only

# Stage 0 — prerequisites; the host directory must exist BEFORE the cluster
docker info --format '{{.ServerVersion}}'
kind version
kubectl version --client
mkdir -p /c/Users/zeroe/dso202-p2-storage   # WSL/Linux/macOS: /tmp/dso202-p2-storage

# Stage 1 — cluster, namespace, quota, retaining StorageClass
kind create cluster --config cluster/kind-cluster.yaml
kubectl get nodes -L dso202/node-index      # control-plane, worker-node-1, worker-node-2
kubectl apply -f manifests/00-namespace.yaml
kubectl config set-context --current --namespace=dso202-practical-02
kubectl apply -f manifests/01-quota-and-limits.yaml -f manifests/02-storageclass-retain.yaml

# Stage 2 — static provisioning
kubectl apply -f manifests/03-pv-static.yaml -f manifests/04-pvc-static.yaml
kubectl apply -f manifests/05-pod-static-writer.yaml
kubectl exec static-writer -- cat /data/ledger.txt

# Stage 3 — dynamic provisioning (claim stays Pending until the Pod exists)
kubectl apply -f manifests/06-pvc-dynamic.yaml
kubectl apply -f manifests/07-pod-dynamic-writer.yaml
kubectl delete pod dynamic-writer && kubectl delete pvc dynamic-data

# Stage 4 — the anti-pattern, observed then removed
kubectl apply -f manifests/08-deployment-shared-pvc.yaml
kubectl exec deploy/shared-writer -- cat /data/visitors.log
kubectl delete -f manifests/08-deployment-shared-pvc.yaml

# Stage 5–6 — StatefulSet, client Pod, scaling, partitioned update
kubectl apply -f manifests/09-service-webnote.yaml
kubectl apply -f manifests/10-statefulset-webnote.yaml
kubectl rollout status statefulset/webnote
kubectl apply -f manifests/11-pod-client.yaml
kubectl exec client -- wget -qO- http://webnote-1.webnote.dso202-practical-02.svc.cluster.local

# Stage 7 — PostgreSQL on retained storage
kubectl apply -f manifests/12-secret-postgres.yaml -f manifests/13-service-postgres.yaml
kubectl apply -f manifests/14-statefulset-postgres.yaml
kubectl wait --for=condition=Ready pod/postgres-0 --timeout=300s

# Verify the cluster matches the repository (Stage 4 and Stage 3 objects
# were deleted on purpose, so diff only what should be live)
kubectl diff -f manifests/09-service-webnote.yaml -f manifests/10-statefulset-webnote.yaml \
  -f manifests/14-statefulset-postgres.yaml && echo "cluster matches repository"
```

The full command sequence for each stage, with real output, is in
`evidence/stage*.txt`.

## Cleanup (including volumes and the host directory)

```bash
# 1. Capture evidence first, including a logical backup of the database
kubectl exec postgres-0 -- pg_dump -U taskuser -d tasktracker > evidence/tasktracker-dump.sql

# 2. Remove the workloads
kubectl delete -f manifests/14-statefulset-postgres.yaml
kubectl delete -f manifests/10-statefulset-webnote.yaml
kubectl delete -f manifests/11-pod-client.yaml
kubectl delete -f manifests/05-pod-static-writer.yaml

# 3. Remove what no manifest created: claims generated by volumeClaimTemplates
kubectl get pvc
kubectl delete pvc --all

# 4. Retain-policy volumes are now Released, not gone — remove them deliberately
kubectl get pv
kubectl delete pv pv-web-static
kubectl delete pv <pvc-...-of-data-postgres-0>

# 5. Delete the cluster
kubectl config set-context --current --namespace=default
kind delete cluster --name dso202-p2

# 6. The host directory survives the cluster; delete it only after the report is written
ls -l /c/Users/zeroe/dso202-p2-storage/pv-web-static/
rm -rf /c/Users/zeroe/dso202-p2-storage
```
