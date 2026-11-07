# DSO202 — Practical 4: GitOps with Argo CD

## Purpose

Installs Argo CD on the shared `dso202` kind cluster and delivers a small web
app **only through Git**. Argo CD runs inside the cluster, pulls the desired
state from this GitHub repository, and keeps reconciling the cluster to it.
Three experiments prove the GitOps loop:

1. **Git as the source of truth:** a pushed commit changes `replicas` from 2 to 4, and the cluster follows.
2. **Drift and self-heal:** a manual `kubectl scale --replicas=1` is undone automatically.
3. **Pruning:** deleting `service.yaml` from Git deletes the Service, and `git revert` brings it back.

Descriptor mapping: Unit IV (ArgoCD/GitOps). The descriptor lists this lab
as Practical 7, "Set up ArgoCD and implement GitOps-based deployment for a
sample application". The course guide is titled "practical 4".

## Software versions used

| Tool                 | Version                                        |
|----------------------|------------------------------------------------|
| OS                   | Windows 11 (build 10.0.26300), Git Bash        |
| Docker Desktop       | 29.4.0 (WSL 2 backend)                         |
| kind                 | v0.32.0                                        |
| kubectl (client)     | v1.36.3                                        |
| Kubernetes (cluster) | v1.36.1 — the existing `dso202` cluster from Practical 1 |
| Argo CD              | v3.6.1 (`stable` install manifest, `quay.io/argoproj/argocd:v3.6.1`) |
| Demo image           | `nginxdemos/hello:plain-text`                  |

## Repository structure

```
practical-04/
├── README.md
├── argocd/
│   └── argocd-app.yaml          # the Application CR — the ONLY file applied with kubectl
├── gitops/
│   └── manifests/               # the path Argo CD watches (desired state)
│       ├── deployment.yaml      # webapp-deploy (replicas changed by Experiment 1)
│       └── service.yaml         # webapp-svc (deleted, then restored, in Experiment 3)
├── evidence/                    # captured command output per step
└── report/
    └── practical-04-report.md
```

`argocd/argocd-app.yaml` is kept outside `gitops/manifests` so the
Application never tries to manage itself.

### Same repository, scoped path

The guide uses a separate public repository (`k8s-gitops-demo`). This run
uses this coursework repository instead, as instructed. The Application's
`source.path` is `practicals/practical-04/gitops/manifests`, so Argo CD
reads only that folder and ignores the rest of the repository. The repository
is public, so no credentials are stored in Argo CD.

## Git history that drove the cluster

| Commit    | Change                                   | Argo CD result |
|-----------|------------------------------------------|----------------|
| `e99c1c5` | initial desired state (2 replicas + Service) | first sync, history id 0 |
| `612aa56` | `replicas: 2` → `4`                      | 2 new Pods, history id 1 |
| `09f9223` | delete `service.yaml`                    | Service **pruned**, history id 2 |
| `2b494cd` | `git revert` of the deletion             | Service recreated, history id 3 |

## Rebuilding from a clean state

```bash
export MSYS_NO_PATHCONV=1                     # Git Bash on Windows only

# 0. The dso202 cluster from Practical 1 must be running
kubectl config use-context kind-dso202
kubectl get nodes

# 1. Install Argo CD into its own namespace.
#    --server-side avoids the client-side 'metadata.annotations: Too long'
#    limit that Argo CD's large CRDs can hit with a plain 'kubectl apply'.
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=900s

# 2. UI access (keep running in a second terminal), then browse https://localhost:8080
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl port-forward svc/argocd-server -n argocd 8080:443      # login: admin / <password above>

# 3. Register the app declaratively (desired state must already be pushed)
kubectl apply -f argocd/argocd-app.yaml
kubectl -n argocd get application my-webapp                    # Synced / Healthy
kubectl get pods -n demo-app -o wide

# Force an immediate poll instead of waiting up to 3 minutes
# (same as the UI's Refresh button):
kubectl -n argocd annotate application my-webapp argocd.argoproj.io/refresh=normal --overwrite
```

Experiments 1 and 3 are changes to `gitops/manifests/` that are committed
and pushed. Experiment 2 is a single
`kubectl scale deployment webapp-deploy -n demo-app --replicas=1`.

## Cleanup

The guide ends with `kind delete cluster --name dso202`. That was **not
run**, because the same cluster also holds Practical 1, Assignment 1 and the
operator demo. To remove only this practical:

```bash
# Deleting the Application with the finalizer below also deletes what it deployed
kubectl -n argocd patch application my-webapp --type merge \
  -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}'
kubectl delete -f argocd/argocd-app.yaml
kubectl delete namespace demo-app --ignore-not-found

# Remove Argo CD itself (CRDs are cluster-scoped and go last)
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl delete namespace argocd
```

At the end of this run, Argo CD and `my-webapp` were left running on
`dso202` (4/4 Pods, `Synced`/`Healthy`). The images took about 45 minutes to
pull on this connection, and later practicals may reuse them.
