# DSO202 — Assignment 2

## Brief

> Utilize the concepts and knowledge gained from the Unit 2 lectures to
> effectively implement Assignment 1.

The Assignment 1 Task Tracker (nginx frontend, Node/Express backend,
PostgreSQL) is rebuilt in a new namespace, `dso202-assignment-2`, using the
Unit II topics in *DSO202_Unit2_Lecture_Notes*:

| Unit II topic | Assignment 1 | Assignment 2 |
|---|---|---|
| **2.1 StatefulSets** | Postgres as a Deployment (`Recreate`) plus a hand-made PVC | StatefulSet `db`: Pod `db-0`, governing headless Service `db-headless`, `volumeClaimTemplates` (PVC `data-db-0`), explicit `OrderedReady`, `partition`, `persistentVolumeClaimRetentionPolicy: Retain` |
| **2.2 Ingress** | frontend NodePort 30081 **and** backend NodePort 30082; `BACKEND_URL=http://localhost:30082` | the ingress-nginx controller; one Ingress with TLS for `tasktracker.localhost`: `/api` → `backend-svc`, `/` → `frontend-svc`. **Every Service is ClusterIP**, which removes Assignment 1's documented deviation from contract table 4.3 |
| **2.3 RBAC** | everything ran as the namespace's `default` ServiceAccount | one ServiceAccount per tier with no permissions and **no mounted token**; a `deployer` ServiceAccount with a namespaced least-privilege Role (no delete, no RBAC); the built-in `view` ClusterRole bound to group `tasktracker-developers` in this namespace only. **All application objects were applied as the deployer** |
| **2.4 Operators** | — | not deployed. The StatefulSet is hand-written, as §2.1.6 recommends for learning, and the README explains what a Postgres Operator would add (see below) |

Probes, which Unit II §2.2.8 uses to explain intermittent 502s behind an
Ingress, were added to every tier. Testing them exposed a crash bug in the
given backend. It is fixed in `dso202-backend:1.1` (see *Known issues*).

## Software versions used

| Tool | Version |
|---|---|
| OS | Windows 11 (build 10.0.26300), Git Bash |
| Docker Desktop | 29.4.0 |
| kind / kubectl | v0.32.0 / v1.36.3 |
| Kubernetes | v1.36.1, shared `dso202` cluster (control-plane, worker-node-1, worker-node-2) |
| Ingress controller | ingress-nginx **controller-v1.15.1**, kind provider manifest (vendored in `ingress-controller/`) |
| Images | `dso202-frontend:1.0`, `dso202-db:1.0` (Assignment 1); `dso202-backend:1.1` (this assignment) |

## Repository structure

```
assignment2/
├── README.md
├── ingress-controller/
│   └── ingress-nginx-kind-v1.15.1.yaml   # vendored, unmodified, pinned by digest
├── app-patch/backend/                    # dso202-backend:1.1
│   ├── Dockerfile                        # FROM dso202-backend:1.0 + one file
│   └── src/db.js                         # + pool.on('error') handler
├── manifests/                            # numbered in apply order
│   ├── 00-namespace.yaml                 # admin
│   ├── 01-configmap.yaml                 # deployer
│   ├── 02-secret.yaml                    # deployer
│   ├── 03-serviceaccounts.yaml           # admin: frontend, backend, db (no token)
│   ├── 04-service-db-headless.yaml       # deployer: governs the StatefulSet
│   ├── 05-statefulset-db.yaml            # deployer
│   ├── 06-service-db.yaml                # deployer: client-facing ClusterIP (DB_HOST)
│   ├── 07-deployment-backend.yaml        # deployer: 2 replicas, probes
│   ├── 08-service-backend.yaml           # deployer: ClusterIP
│   ├── 09-deployment-frontend.yaml       # deployer: 2 replicas, probes
│   ├── 10-service-frontend.yaml          # deployer: ClusterIP
│   ├── 11-ingress.yaml                   # deployer
│   ├── 12-rbac-deployer.yaml             # admin
│   └── 13-rbac-viewers.yaml              # admin
├── scripts/
│   ├── make-tls-secret.sh                # self-signed cert -> tasktracker-tls (key never in Git)
│   └── host-proxy.sh                     # localhost:8443/8081 -> the controller's node
├── evidence/                             # real command output, one file per stage
└── report/
    └── assignment2-report.md
```

The header of every manifest says who applies it, and why each
non-obvious field is set.

## Known issues and deviations

1. **The given backend crashed whenever the database restarted.** The
   `pg` Pool emits `error` when Postgres terminates an idle connection, and
   `db.js` had no listener, so Node exited with code 1. Assignment 1 never
   showed it: its checklist only tested a database that was missing at
   startup, and Kubernetes' restarts made the crash look like recovery.
   **Fixed** in `app-patch/backend` (`dso202-backend:1.1`), built
   `FROM dso202-backend:1.0` plus the one changed file. Assignment 1's
   source and image are untouched. Before/after evidence is in
   `evidence/stage6-probes.txt`.
2. **`BACKEND_URL` cannot be empty.** Same-origin requests would ideally use
   an empty `BACKEND_URL` (relative `/api/...` URLs), but
   `docker-entrypoint.sh` uses `${BACKEND_URL:=http://localhost:8080}`, and
   `:=` also replaces an *empty* value. It is therefore set to the full
   public origin, `https://tasktracker.localhost:8443`.
3. **Host access through a proxy, not port 443.** The cluster from
   Practical 1 maps only host port 30080. `scripts/host-proxy.sh` forwards
   loopback ports 8443 and 8081 to the node that runs the controller
   (`hostPort` 443/80).
   **The host is `tasktracker.localhost`.** The first choice was
   `tasktracker.localtest.me`, a public DNS name that resolves to loopback.
   This network's DNS server (10.2.23.1) drops its IPv4 answer and returns
   only `::1`, which looks like DNS-rebinding protection. Docker Desktop's
   IPv6 loopback forward then broke the TLS handshake. Names under
   `.localhost` (RFC 6761) are resolved to 127.0.0.1 by curl and browsers
   themselves, without DNS. The proxy is therefore bound to 127.0.0.1 only
   (`evidence/stage4-ingress.txt`).
4. **Self-signed TLS.** `scripts/make-tls-secret.sh` creates the
   certificate at deploy time, so its key never enters Git. Browsers show a
   warning once, and `curl` needs `-k`. cert-manager would be the
   production choice (Unit II §2.2.6).
5. **ingress-nginx is retired** (no releases after March 2026, as Unit II
   §2.2.6 notes). The final release, v1.15.1, is used because the lecture's
   kind example uses this controller.
6. **No Operator is deployed (Unit II 2.4).** The report (§4) explains what
   a Postgres Operator would add over this StatefulSet, and why it was not
   installed on the shared cluster.
7. **The lecture's `rewrite-target: /` annotation is not used.** It would
   strip `/api` and break every backend route (see `11-ingress.yaml`).

## Rebuilding from a clean state

```bash
export MSYS_NO_PATHCONV=1                      # Git Bash only
cd assignment2

# 0. Images: frontend/db 1.0 from Assignment 1; backend 1.1 from the patch
docker build -t dso202-backend:1.1 app-patch/backend
kind load docker-image dso202-frontend:1.0 dso202-db:1.0 dso202-backend:1.1 --name dso202

# 1. Ingress controller (cluster-wide, once)
kubectl apply -f ingress-controller/ingress-nginx-kind-v1.15.1.yaml
kubectl wait -n ingress-nginx --for=condition=ready pod \
  -l app.kubernetes.io/component=controller --timeout=600s

# 2. Admin bootstrap: namespace, identities, RBAC
kubectl apply -f manifests/00-namespace.yaml -f manifests/03-serviceaccounts.yaml \
              -f manifests/12-rbac-deployer.yaml -f manifests/13-rbac-viewers.yaml
scripts/make-tls-secret.sh dso202-assignment-2 tasktracker.localhost

# 3. The application, as the deployer ServiceAccount
D=--as=system:serviceaccount:dso202-assignment-2:deployer
kubectl $D apply -f manifests/01-configmap.yaml -f manifests/02-secret.yaml \
  -f manifests/04-service-db-headless.yaml -f manifests/05-statefulset-db.yaml \
  -f manifests/06-service-db.yaml -f manifests/07-deployment-backend.yaml \
  -f manifests/08-service-backend.yaml -f manifests/09-deployment-frontend.yaml \
  -f manifests/10-service-frontend.yaml -f manifests/11-ingress.yaml
kubectl $D -n dso202-assignment-2 rollout status statefulset/db
kubectl $D -n dso202-assignment-2 rollout status deployment/backend
kubectl $D -n dso202-assignment-2 rollout status deployment/frontend

# 4. Host access, then browse https://tasktracker.localhost:8443/
scripts/host-proxy.sh
curl -sk https://tasktracker.localhost:8443/api/status
```

## Cleanup

```bash
kubectl delete namespace dso202-assignment-2   # everything, incl. the TLS Secret
# The PVC data-db-0 goes with the namespace. Retain only protects it from
# deleting the StatefulSet, not from deleting the namespace.
docker rm -f dso202-ingress-proxy-8443 dso202-ingress-proxy-8081
# Only if no other assignment uses the controller:
kubectl delete -f ingress-controller/ingress-nginx-kind-v1.15.1.yaml
```

## Assessment mapping (module descriptor)

Assessed under *B. Assignments* of the DSO202 module descriptor
(`Module_Descriptor_Resequenced.docx`), out of 10 marks. The full mapping,
with section references, is at the end of `report/assignment2-report.md`.

| Criterion (descriptor) | Marks | Where it is evidenced |
|---|---|---|
| Code Organization & Readability | 1 | Numbered manifests split by applier (admin / deployer); `ingress-controller/`, `app-patch/`, `scripts/` kept apart |
| Code Comments & Documentation | 1 | Header on every manifest (applier, Unit II section, reasons); this README; the report |
| Configuration Requirements | 2 | StatefulSet + headless/client Services, Ingress + TLS, all Services ClusterIP, per-workload ServiceAccounts, deployer and viewer RBAC |
| Configuration Implementation | 5 | `evidence/stage3`–`stage7`: deployed as the deployer; StatefulSet identity and persistence; probes plus the backend crash fix; security context; RBAC allow/deny matrix |
| Deployment & Configuration | 1 | Rebuild sequence above; end-to-end CRUD through the Ingress (`evidence/stage4-ingress.txt`) |
