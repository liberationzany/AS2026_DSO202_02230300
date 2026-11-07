# DSO202 — Practical 5: Environment-Specific Configuration with Kustomize

## Purpose

One small nginx web app is deployed to four environments (dev, staging,
prod, qa) from **one** base, without copying the Deployment or Service into
any environment. Each overlay holds only what is different: namespace,
environment label, replica count, image tag, page content, and patches
(strategic-merge for prod resources, JSON 6902 for the qa annotation). The
practical also shows the generated-ConfigMap hash triggering a rollout, and
the safe workflow `render → diff → apply → verify`.

Descriptor mapping: Unit III (configuration management with Kustomize).
The resequenced descriptor lists this lab as Practical 4, "Use Kustomize to
manage environment-specific configurations for a Kubernetes application".
The course guide is titled "practical 5".

## Software versions used

| Tool                 | Version                                   |
|----------------------|-------------------------------------------|
| OS                   | Windows 11 (build 10.0.26300), Git Bash   |
| Docker Desktop       | 29.4.0 (WSL 2 backend)                    |
| kind                 | v0.32.0                                   |
| kubectl (client)     | v1.36.3, built-in **Kustomize v5.8.1**    |
| Kubernetes (cluster) | v1.36.1 — the shared `dso202` cluster (control-plane, worker-node-1, worker-node-2) |
| Images               | `nginx:1.30-alpine` (base, prod, qa), `nginx:1.31-alpine` (dev, staging), `busybox:1.37` (test client) |

No standalone `kustomize` binary is needed; `kubectl kustomize` and
`kubectl apply -k` use the built-in one.

## Repository structure

```
practical-05/
├── README.md
├── examples/webapp/
│   ├── base/                        # written once, shared by every environment
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── index.html               # placeholder page every overlay replaces
│   │   └── kustomization.yaml       # resources + configMapGenerator
│   └── overlays/
│       ├── dev/                     # 1 replica, nginx 1.31, own page
│       ├── staging/                 # 2 replicas, nginx 1.31, own page
│       ├── prod/                    # 4 replicas, nginx 1.30 pinned, patch-resources.yaml (strategic merge)
│       ├── qa/                      # 2 replicas, patch-annotation.yaml (JSON 6902)   — Task 9
│       └── sandbox/                 # namePrefix demo + PREDICTION.md, render only  — challenge
├── evidence/                        # command output per task; rendered/ holds full renders
└── report/
    └── practical-05-report.md
```

## Environment summary (from the rendered output)

| Overlay | Namespace | Replicas | Image | Resources | Extra |
|---|---|---|---|---|---|
| dev | `webapp-dev` | 1 | `nginx:1.31-alpine` | base (50m/32Mi → 100m/64Mi) | — |
| staging | `webapp-staging` | 2 | `nginx:1.31-alpine` | base | — |
| prod | `webapp-prod` | 4 | `nginx:1.30-alpine` | **100m/64Mi → 250m/128Mi** | strategic-merge patch |
| qa | `webapp-qa` | 2 | `nginx:1.30-alpine` | base | annotation `training.example.com/owner: qa-team` (JSON 6902) |

## Rebuilding from a clean state

```bash
export MSYS_NO_PATHCONV=1          # Git Bash on Windows only
cd practicals/practical-05
kubectl config use-context kind-dso202

# For each environment: render, diff, apply, verify
for env in dev staging prod qa; do
  kubectl kustomize examples/webapp/overlays/$env > /dev/null      # 1. renders?
  kubectl diff -k examples/webapp/overlays/$env || true            # 2. what would change
  kubectl apply -k examples/webapp/overlays/$env                   # 3. apply
  kubectl rollout status deployment/webapp -n webapp-$env          # 4. verify
done
kubectl get deploy -A -l app.kubernetes.io/name=webapp -L app.kubernetes.io/environment

# Reach dev (8085 because 8080 is used by the Argo CD port-forward)
kubectl port-forward -n webapp-dev service/webapp 8085:80 &
curl http://127.0.0.1:8085
```

On a **first** deployment, `kubectl diff -k` prints
`Error from server (NotFound): namespaces "webapp-<env>" not found`.
The API server cannot dry-run objects into a namespace that does not exist
yet. This is expected; `apply -k` creates the namespace first.

## Cleanup

```bash
for env in dev staging prod qa; do kubectl delete -k examples/webapp/overlays/$env; done
kubectl get ns | grep 'webapp-' || true      # expect nothing
```

`delete -k` deletes only what the overlay renders **now**. ConfigMaps from
earlier content versions (for example the dev v1 ConfigMap left by Task 6)
are not in the render. They are removed here only because the namespace
itself is deleted.
