# DSO202 — Practical 1

## Purpose

Sets up a local three-node Kubernetes cluster with `kind` and deploys a
single static web application through the object types covered in Unit I:
Namespace, ResourceQuota/LimitRange, Pod, Deployment, and Service
(ClusterIP and NodePort). Built around a single narrow application (nginx)
so that attention stays on the Kubernetes objects rather than on
application code.

## Software versions used

| Tool                 | Version                          |
|----------------------|-----------------------------------|
| OS                    | Windows 11 (build 10.0.26200)    |
| Docker Desktop        | 29.4.0                           |
| kind                   | v0.32.0 (windows/amd64)          |
| kubectl (client)       | v1.36.3                          |
| Kubernetes (cluster)   | v1.36.1                          |

## Repository structure

```
practical-01/
├── README.md
├── cluster/
│   ├── kind-cluster.yaml            # Listing 1
│   └── kind-cluster-fallback.yaml   # Listing 1B
├── manifests/
│   ├── 00-namespace.yaml            # Listing 2
│   ├── 01-quota-and-limits.yaml     # Listing 3
│   ├── 02-pod-web.yaml              # Listing 4
│   ├── 03-deployment-web.yaml       # Listing 5
│   ├── 04-service-clusterip.yaml    # Listing 6
│   ├── 05-service-nodeport.yaml     # Listing 7
│   └── 06-pod-client.yaml           # Listing 8
├── evidence/                        # captured command output
└── report/
    └── practical-01-report.md
```

## Rebuilding from an empty machine

```bash
# Stage 0 — verify prerequisites
docker info --format '{{.ServerVersion}} {{.OperatingSystem}}'
kind version
kubectl version --client

# Stage 1 — create the cluster
kind create cluster --config cluster/kind-cluster.yaml
kind get clusters
kubectl config current-context     # kind-dso202

# Stage 3 onward — apply every manifest in order (filenames are numbered
# so a directory apply applies them correctly)
kubectl apply -f manifests/
kubectl config set-context --current --namespace=dso202-practical-01

# Verify the cluster matches the repository
kubectl diff -f manifests/ && echo "cluster matches repository"
```

If Listing 1 fails during cluster creation with an error mentioning
`nodeRegistration`, or `kubectl get nodes` keeps showing the Docker
container names after a clean recreation, use the fallback config instead:

```bash
kind create cluster --config cluster/kind-cluster-fallback.yaml
```

## Cleanup commands

```bash
# Delete the workload objects declaratively, in reverse order of creation
kubectl delete -f manifests/06-pod-client.yaml
kubectl delete -f manifests/05-service-nodeport.yaml
kubectl delete -f manifests/04-service-clusterip.yaml
kubectl delete -f manifests/03-deployment-web.yaml
kubectl delete -f manifests/02-pod-web.yaml
kubectl delete -f manifests/01-quota-and-limits.yaml
kubectl delete -f manifests/00-namespace.yaml

# Reset the kubectl default namespace
kubectl config set-context --current --namespace=default

# Delete the cluster entirely
kind delete cluster --name dso202
```
