# DSO202 — Assignment 1

## Purpose

Deploys a three-tier Task Tracker (nginx frontend, Node/Express backend,
PostgreSQL db) onto the shared `dso202` kind cluster, against the contract
in `assignment.pdf` (`DSO202_Assignment1_Image_Build_Guide.md`). Application
source lives in `Assignment-1-app-code/`; the Kubernetes objects that
configure and connect the three images live in `manifests/`.

## Software versions used

| Tool                 | Version                          |
|----------------------|-----------------------------------|
| OS                    | Windows 11 (build 10.0.26200)    |
| Docker Desktop        | 29.4.0                           |
| kind                   | v0.32.0 (windows/amd64)          |
| kubectl (client)       | v1.36.3                          |
| Kubernetes (cluster)   | v1.36.1 (shared `dso202` cluster, also running Practical 1) |

## Repository structure

```
assignment1/
├── README.md
├── assignment.pdf                     # the tutor's Image Build Guide (contract)
├── Assignment-1-app-code/             # given application source + Dockerfiles
│   ├── frontend/  backend/  db/
│   └── docker-compose.yml             # local smoke-test harness only
└── manifests/
    ├── 00-namespace.yaml
    ├── 01-configmap.yaml
    ├── 02-secret.yaml
    ├── 03-pvc.yaml
    ├── 04-deployment-db.yaml
    ├── 05-service-db.yaml
    ├── 06-deployment-backend.yaml
    ├── 07-service-backend.yaml
    ├── 08-deployment-frontend.yaml
    └── 09-service-frontend.yaml
```

## Known issues found in the given materials

Two problems in the tutor's own handoff package had to be worked around;
neither is a mistake in this submission's manifests.

1. **Published images are arm64-only.** `sarojsanyasi/dso202-{frontend,backend,db}:1.0`
   on Docker Hub have no `linux/amd64` manifest (`docker manifest inspect`
   confirms it), and this machine and the `dso202` kind nodes are amd64.
   `kind load docker-image` silently drops a non-matching-platform image
   (no error, just absent from `crictl images` afterward), and
   `docker run --platform linux/arm64 ...` fails with `exec format error` --
   no QEMU emulation is registered. This violates the guide's own Section 5
   multi-arch requirement. **Worked around by building the given source
   under `Assignment-1-app-code/` locally instead**, tagged
   `dso202-{frontend,backend,db}:1.0`, native amd64.

2. **`docker-compose.yml` had a typo** (`loqcalhost` instead of `localhost`
   in the frontend's `BACKEND_URL`), which broke the guide's own Section 7
   Step 5 local smoke test. Fixed.

## Deviation from the contract, documented

**`backend-svc` is `NodePort`, not the `ClusterIP` the contract table (4.3)
specifies.** `app.js` runs in the browser and calls `BACKEND_URL` directly
with `fetch()` -- there is no reverse proxy in `nginx.conf` forwarding
`/api/*` on the frontend's behalf. A `ClusterIP` Service is not reachable
from outside the cluster, so with the given frontend code as-is, a
ClusterIP-only backend leaves the browser unable to ever load tasks.
Confirmed by testing: the UI showed "backend unreachable" / "could not load
the ledger (Failed to fetch)" until `backend-svc` was changed to `NodePort`.
A `NodePort` Service still gets a `ClusterIP` too, so nothing that calls it
in-cluster (there is nothing that does, in this app) is affected.

See `manifests/07-service-backend.yaml` and `manifests/01-configmap.yaml`
for where this is applied.

## Reaching the app from the host

`kind`'s `extraPortMappings` (set at cluster creation, in Practical 1's
`cluster/kind-cluster.yaml`) only forwards host port 30080, which Practical
1's own `web-nodeport` Service already holds -- a `nodePort` is allocated
cluster-wide, not per namespace, so this assignment's Services use 30081
(frontend) and 30082 (backend) instead. Those aren't in the cluster's
port mappings, and a kind node's own Docker-network IP isn't reachable from
the Windows host directly (`curl` to `172.20.0.x:<port>` times out) --
confirmed by testing. Recreating the cluster with new port mappings would
work but destroys Practical 1 / operator-demo state already running in it,
so two small local proxy containers are used instead, non-destructively:

```bash
docker run -d --name dso202-frontend-proxy --network kind --restart unless-stopped \
  -p 30081:30081 alpine/socat tcp-listen:30081,fork,reuseaddr tcp-connect:dso202-control-plane:30081

docker run -d --name dso202-backend-proxy --network kind --restart unless-stopped \
  -p 30082:30082 alpine/socat tcp-listen:30082,fork,reuseaddr tcp-connect:dso202-control-plane:30082
```

`--restart unless-stopped` means these two survive a Docker Desktop restart or
host reboot on their own (Docker restarts anything not explicitly stopped) --
no need to rerun the commands unless the containers were deliberately removed.
Then browse **http://localhost:30081/**.

## Rebuilding from a clean state

```bash
# Stage 0 — prerequisites (Docker Desktop running, kind cluster 'dso202' up)
docker info --format '{{.ServerVersion}}'
kubectl get nodes

# Stage 1 — build the three images natively (amd64) from the given source
cd Assignment-1-app-code
docker compose build
docker tag assignment-1-app-code-frontend:latest dso202-frontend:1.0
docker tag assignment-1-app-code-backend:latest  dso202-backend:1.0
docker tag assignment-1-app-code-db:latest       dso202-db:1.0
cd ..

# Stage 2 — load them into every kind node
kind load docker-image dso202-frontend:1.0 dso202-backend:1.0 dso202-db:1.0 --name dso202

# Stage 3 — apply the manifests, in order
kubectl apply -f manifests/00-namespace.yaml -f manifests/01-configmap.yaml \
  -f manifests/02-secret.yaml -f manifests/03-pvc.yaml \
  -f manifests/04-deployment-db.yaml -f manifests/05-service-db.yaml \
  -f manifests/06-deployment-backend.yaml -f manifests/07-service-backend.yaml \
  -f manifests/08-deployment-frontend.yaml -f manifests/09-service-frontend.yaml

kubectl rollout status deployment/db-deployment       -n dso202-assignment-1
kubectl rollout status deployment/backend-deployment  -n dso202-assignment-1
kubectl rollout status deployment/frontend-deployment -n dso202-assignment-1

# Stage 4 — bring up the two host-access proxies (see above), then browse
# http://localhost:30081/
```

## Verification checklist (Image Build Guide Section 8)

- [x] All three containers run as non-root -- `kubectl exec ... whoami` shows
      `nginx` (frontend) and `app` (backend); the db container's entrypoint
      runs as root only to fix permissions, and the actual `postgres`
      process runs as the `postgres` user (`ps aux` inside the pod).
- [x] Backend does not crash-loop when started before the database is
      reachable -- observed in logs: `[db] not reachable yet (EAI_AGAIN),
      retrying in 2000ms` followed by `[db] connected`.
- [x] Backend `/api/status` responds correctly once the database connection
      succeeds -- `{"status":"ok","db":"connected"}`.
- [x] Frontend's runtime configuration substitution actually produces a
      working `BACKEND_URL` at container start -- confirmed via
      `curl .../config.js` and, separately, in a real browser session.
- [x] Full CRUD cycle verified end-to-end -- both via `curl` against
      `backend-svc` and by driving the actual UI in Chrome (create, change
      status, delete) against the Kubernetes-deployed stack.
- [x] Image sizes reviewed / unnecessary layers removed -- `docker history`
      showed the frontend Dockerfile installing the full `gettext` package
      (16.8MB) for `envsubst`, which `nginx:1.31-alpine`'s own base layer
      already provides via `gettext-envsubst` (confirmed with
      `docker run --rm nginx:1.31.3-alpine which envsubst`). Removed the
      redundant `apk add`; frontend image shrank 112MB -> 92.9MB with no
      behaviour change (re-verified: `config.js` still renders, full CRUD
      still works). No secret values found in any layer's history for any
      of the three images -- credentials are only ever supplied at
      container start via env vars, never baked in at build time.
- [x] Tags follow semantic versioning (`1.0`); nothing pushed as `latest`.
- [x] PVC-backed data survives Pod recreation, not just the check that data
      exists -- `kubectl delete pod` on the db Pod, then confirmed the same
      3 tasks (identical ids and `created_at` timestamps) came back once
      the Deployment recreated it, and the Postgres log read "Database
      directory appears to contain a database; Skipping initialization"
      (i.e. the seed script did not re-run against a fresh volume).

## Cleanup commands

```bash
kubectl delete -f manifests/09-service-frontend.yaml -f manifests/08-deployment-frontend.yaml \
  -f manifests/07-service-backend.yaml -f manifests/06-deployment-backend.yaml \
  -f manifests/05-service-db.yaml -f manifests/04-deployment-db.yaml \
  -f manifests/03-pvc.yaml -f manifests/02-secret.yaml -f manifests/01-configmap.yaml \
  -f manifests/00-namespace.yaml

docker rm -f dso202-frontend-proxy dso202-backend-proxy
```

## Assessment mapping (module descriptor)

Assessed under *B. Assignments* of the DSO202 module descriptor
(`Module_Descriptor_Resequenced.docx`), out of 10 marks. The descriptor maps
Assignment 1 to Units I & II (core objects, RBAC).

| Criterion (descriptor) | Marks | Where it is evidenced |
|---|---|---|
| Code Organization & Readability | 1 | `manifests/` numbered in apply order (`00-namespace` → `09-service-frontend`), one object type per file; application source kept separate in `Assignment-1-app-code/` |
| Code Comments & Documentation | 1 | Header and per-field comments in every manifest; this README (purpose, versions, known issues, rebuild and cleanup commands) |
| Configuration Requirements | 2 | ConfigMap for non-secret settings, Secret for DB credentials, PVC for Postgres data, a Service per tier — matching the contract in the Image Build Guide (§4.3), with the one deviation (`backend-svc` as NodePort) documented above |
| Configuration Implementation | 5 | Three Deployments wired through ConfigMap/Secret env vars, resource requests/limits, non-root containers, DB retry on startup — see the verification checklist above |
| Deployment & Configuration | 1 | Reproducible rebuild sequence (build → `kind load` → ordered `kubectl apply` → `rollout status`) and verified end-to-end CRUD plus PVC persistence across Pod recreation |
