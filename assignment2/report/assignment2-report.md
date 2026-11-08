# DSO202 — Assignment 2 Report

The Assignment 1 Task Tracker, rebuilt with Unit II: StatefulSets, Ingress,
RBAC and Operators.

## 1. Objective

Assignment 1 met its contract with Unit I objects: Deployments, Services,
a ConfigMap, a Secret and a PVC. In doing so it needed two compromises:

- the database ran as a Deployment with a hand-made volume;
- the backend had to be exposed on a NodePort, contrary to the contract
  table, because the browser calls it directly.

Assignment 2 applies each Unit II topic to a real weakness of that build,
rather than adding objects for their own sake:

| Unit II | Weakness in Assignment 1 | What Assignment 2 does |
|---|---|---|
| 2.1 StatefulSets | Postgres's identity and volume were not tied together; `Recreate` had to prevent two Pods sharing the volume | StatefulSet `db` with a governing headless Service, a per-ordinal PVC, an explicit retention policy and an update partition |
| 2.2 Ingress | two NodePorts; `backend-svc` deviated from the contract (ClusterIP) | one Ingress with TLS. `/api` and `/` share one origin, so every Service is ClusterIP again |
| 2.3 RBAC | every Pod ran as `default`, with an API token mounted; deployment needed cluster-admin | a ServiceAccount per tier with no token; a least-privilege `deployer`, used to apply the application; a group `view` binding |
| 2.4 Operators | — | evaluated, not deployed (§4) |

Descriptor coverage: Unit II 2.1–2.4. The descriptor maps Assignment 1 to
Units I & II, and this assignment completes the Unit II half.

## 2. Environment

| Item | Value |
|---|---|
| Cluster | shared `dso202` kind cluster, Kubernetes v1.36.1, 3 nodes (`stage0`) |
| Tools | kubectl v1.36.3, kind v0.32.0, Docker Desktop 29.4.0, Git Bash on Windows 11 |
| Ingress controller | ingress-nginx controller-v1.15.1, kind provider manifest, digest-pinned |
| Namespace | `dso202-assignment-2`; Assignment 1 keeps running in `dso202-assignment-1` |
| Public URL | `https://tasktracker.localhost:8443/`, through an IPv4-loopback-only socat proxy to the controller's node |

**Why a proxy and a `localhost` name.** The cluster was created in
Practical 1 with only host port 30080 mapped. Recreating it to map 80/443
would destroy the other labs, so `scripts/host-proxy.sh` forwards host ports
8443 and 8081 to the node that runs the controller, as Assignment 1 did for
its NodePorts. The host is `tasktracker.localhost`: names under
`.localhost` are reserved for loopback (RFC 6761), and curl and browsers
resolve them to 127.0.0.1 themselves, so no DNS and no hosts-file edit
(which needs administrator rights) is involved. §3.6 explains why the first
choice, the public wildcard name `localtest.me`, did not work here.

## 3. Implementation and Observations

### 3.1 Deploying as the least-privilege deployer (`evidence/stage3-deploy-as-deployer.txt`)

The cluster admin applied only the namespace, the ServiceAccounts and the
RBAC objects. Every application object was applied with
`kubectl --as=system:serviceaccount:dso202-assignment-2:deployer`, and the
three `rollout status` checks also ran as the deployer. All of them
succeeded, which shows that the Role is *sufficient*. §3.5 shows it is also
*narrow*.

Final state:

- `db-0`, two backend Pods and two frontend Pods, all Running and Ready;
- four ClusterIP Services, one of them headless;
- PVC `data-db-0` Bound.

### 3.2 StatefulSet (`evidence/stage5-statefulset.txt`)

| Check | Result |
|---|---|
| Pod identity | `spec.hostname.subdomain` = `db-0.db-headless` |
| Per-Pod DNS | `db-0.db-headless.dso202-assignment-2.svc.cluster.local` → `10.244.1.17` (the Pod IP) |
| Client Service DNS | `db-svc...` → `10.96.150.103` (a virtual IP) |
| EndpointSlice | `db-headless` lists `10.244.1.17` with `hostname: db-0` |
| PVC name | `data-db-0`, from the template `data`, StatefulSet `db`, ordinal 0 |
| Delete Pod `db-0` | new UID, same name, same node, same PVC. The row written before the delete is still there, and Postgres logs `Database directory appears to contain a database; Skipping initialization` |
| Delete the whole StatefulSet | Pod terminated, **PVC kept** (`whenDeleted: Retain`). Re-applying the StatefulSet (as the deployer) re-attached `data-db-0`: 4 rows |

**Two Services for one database.** `db-headless` exists for the
StatefulSet: it gives the Pod its DNS identity. `db-svc` is what the backend
uses (`DB_HOST`). Unit II §2.1.6 says not to use one Service for both
roles. The practical difference is that a ClusterIP Service only routes to
*Ready* Pods, so the backend is never sent to a Postgres that is still
running initdb.

**Why one replica.** A StatefulSet gives each replica a stable identity and
its own volume. It does not make Postgres replicate. `replicas: 3` here
would create three independent, empty databases behind one Service, and
tasks would appear and disappear depending on which Pod answered. The scale
decision is therefore 1, and replication is left to an Operator (§4).

### 3.3 Probes, and a crash they revealed (`evidence/stage6-probes.txt`)

The backend has three probes, each with one job:

- **startup:** a TCP check, allowing up to 5 minutes. `server.js` only
  listens after it connects to the database.
- **readiness:** `GET /api/status`, which runs `SELECT 1` and returns 503
  without the database.
- **liveness:** a TCP check only. Losing the database should not restart
  the backend.

The test scaled `db` to 0.

**With the given image (`1.0`):**
- both backend Pods went to `0/1` and both endpoints became `ready=false`,
  as intended;
- but both Pods also **restarted** (restart count 2 → 3), and the
  termination reason was `Error`, exit code 1.

The liveness probe was not the cause. The previous container's log shows:

```
[db] connected
[server] listening on :8080
error: terminating connection due to administrator command
Emitted 'error' event on BoundPool instance at:
```

When Postgres shuts down, it terminates the pool's idle connection. The
`pg` Pool emits `error`, and `db.js` has no listener. In Node an unhandled
`error` event throws, so the process exits. Kubernetes then masked the bug:
the restarted container waited in `waitForDatabase()`, the startup probe
held it, and it came back. That is why it never showed in Assignment 1's
checklist, which only tested startup *before* the database existed.

**Fix (`app-patch/backend`, image `1.1`):**
- `pool.on('error', ...)` logs the lost connection; the pool already
  replaces broken clients on the next query.
- The image is built `FROM dso202-backend:1.0`, replacing one file, so
  dependencies, user and command are unchanged, and no base image had to be
  downloaded over a slow link.

**With `1.1`, the same outage:**

| Time | Event | Backend |
|---|---|---|
| 13:55:59 | `db` scaled to 0 | — |
| 13:56:29 | — | both `READY false`, **`RESTARTS 0`**; log `[db] idle connection lost (57P01)`; events `Readiness probe failed: ... statuscode: 503` |
| 13:56:30 | `db` scaled to 1 | — |
| 13:56:44 | — | both Ready, both endpoints `ready=true`, still 0 restarts |

This is the behaviour Unit II §2.2.8 depends on. During the outage the
Ingress has no backend endpoint and returns a clear error instead of
crashing Pods.

### 3.4 Workload identities and security context (`evidence/stage7-rbac-security.txt`)

- Every Pod runs under its own ServiceAccount with
  `automountServiceAccountToken: false`. In the backend,
  `/var/run/secrets/kubernetes.io/serviceaccount` does not exist, so there
  is no credential for a compromised process to steal.
  `auth can-i list pods --as=...:backend` returns `no`.
- The backend runs as `uid=100(app)` and the frontend as `uid=101(nginx)`,
  enforced by `runAsNonRoot`. The numeric UIDs are written in the manifests
  because the images use user *names*, which the kubelet cannot verify as
  non-root.
- The backend's root filesystem is read-only (`touch /app/x` → `Read-only
  file system`). The frontend's is not: its entrypoint writes `config.js`
  at start.
- All containers drop all capabilities, block privilege escalation and use
  the `RuntimeDefault` seccomp profile.

### 3.5 RBAC: the deployer and the developers (`evidence/stage7-rbac-security.txt`)

| Question (`auth can-i ... --as=deployer`) | Answer |
|---|---|
| patch deployments / statefulsets, create ingresses | yes |
| delete deployments; delete PVCs | no |
| create rolebindings (could escalate itself) | no |
| create pods/exec | no |
| patch deployments in `dso202-assignment-1` | no |
| list nodes | no |

Group `tasktracker-developers` (the built-in `view` ClusterRole, bound by a
RoleBinding):

- can list pods here;
- **cannot** read Secrets, because `view` excludes them;
- cannot delete pods;
- has nothing in `dso202-assignment-1`.

**The §2.3.8 incident, reproduced.** I copied the deployer Role with
`patch` removed, onto a throwaway ServiceAccount.

1. The first `kubectl apply` returned `deployment.apps/frontend unchanged`
   and succeeded. With no difference to send, kubectl makes no PATCH
   request at all, so the missing verb stays hidden until the first real
   change.
2. With a real change (replicas 2 → 3), the apply failed: `cannot patch
   resource "deployments" in API group "apps"`.
3. The real deployer, which has `patch`, applied the same change. A pipeline
   can therefore pass review and its first runs, and only fail on the first
   real update.

`kubectl replace` (an HTTP PUT, the `update` verb) succeeded on the
throwaway Role, confirming that `update` and `patch` are separate verbs.

### 3.6 Ingress (`evidence/stage1-ingress-controller.txt`, `stage2-validate.txt`, `stage4-ingress.txt`)

**Controller.** The vendored kind manifest for ingress-nginx v1.15.1
creates the `nginx` IngressClass and a controller that publishes host ports
80 and 443 on its node (`worker-node-2`). Its image (116 MB) took **21 min
21 s** to pull, and the webhook-certificate image (27 MB) took 13–18 min.
Until the controller was Ready, even a server-side *dry run* of the Ingress
failed (`failed calling webhook "validate.nginx.ingress.kubernetes.io" ...
connection refused`): an admission webhook is in the request path of every
Ingress write.

**First attempt: `tasktracker.localtest.me` failed.** `localtest.me` is a
public DNS name whose subdomains resolve to loopback. Over HTTPS, curl
reported `IPv6: ::1`, `IPv4: (none)`, then `schannel: failed to receive
handshake`. With `--resolve ...:127.0.0.1` the same request returned
`{"status":"ok","db":"connected"}`, so the Ingress, TLS and backend were all
correct.

The cause was this network's DNS server (10.2.23.1): it returns the `::1`
AAAA record but drops the 127.0.0.1 A record ("No address (A) records
available"), which looks like DNS-rebinding protection. Docker Desktop
accepted the IPv6 loopback connection, but the TLS handshake through it
failed.

I moved every host to `*.localhost`, which RFC 6761 reserves for loopback
and which curl and browsers resolve themselves. I also bound the proxy to
127.0.0.1 only, so a client that tries `::1` first is refused at once and
falls back. The first attempt is kept, labelled, in the evidence.

**Second attempt: `tasktracker.localhost` worked.**

| Request | Result |
|---|---|
| `describe ingress` | `tasktracker-tls terminates tasktracker.localhost`; `/api → backend-svc:http (2 Pod IPs)`, `/ → frontend-svc:http (2 Pod IPs)` |
| `GET /api/status` | `{"status":"ok","db":"connected"}` from 127.0.0.1, HTTP 200 |
| `GET /` | the Task Tracker page (`<title>Field Log — Task Tracker</title>`) |
| `GET /config.js` | `BACKEND_URL: "https://tasktracker.localhost:8443"`, the same origin |
| `GET /apix` | 200, the **frontend** page: `Prefix /api` matches whole path segments, so `/apix` falls through to `/` |
| `http://...:8081/` | `308 Permanent Redirect`, `Location: https://tasktracker.localhost`; responses carry `Strict-Transport-Security` |
| certificate for SNI `tasktracker.localhost` | `CN=tasktracker.localhost`, SAN `DNS:tasktracker.localhost` (the Secret from the script) |
| SNI `other.localhost` | HTTP 404 and `CN=Kubernetes Ingress Controller Fake Certificate`: an unknown host gets the controller's default certificate |
| CRUD | POST → id 6 `pending`; PUT → `done`; GET shows `done`; DELETE → 204; GET → 404; list back to ids 1, 2, 3, 5 |
| 20 × `/api/status` | 12 to `10.244.1.27`, 8 to `10.244.2.17`: the two backend Pods |

The redirect drops the `:8443` port. The controller only knows it listens
on 443; the host-side port mapping is invisible to it. Through a real load
balancer on 443 the redirect would be correct.

**The lecture's `rewrite-target: /`, tested.** A copy of the Ingress with
the §2.2.7 annotation, on host `rewrite.localhost`, answered `GET
/api/tasks` with Express's own `Cannot GET /` (404). The annotation
rewrote the path to `/` before it reached the backend, whose routes all
live under `/api`. The real Ingress (no annotation) returned the task list
at the same moment. The annotation belongs to applications that expect the
prefix stripped. Copied blindly, it breaks this one.

**No ready backend.**
- With the backend scaled to 0, `/api/status` returned **503** while `/`
  still returned 200. The Ingress kept routing; only the empty `/api`
  upstream failed. This is the §2.2.9 point that a 5xx means routing
  worked.
- Immediately after `rollout status` reported success, one more request
  still got 503, and the next one, a few seconds later, got 200. The
  controller needs a moment to receive the new endpoints.
- The deployer could not `kubectl scale` at all: `cannot patch resource
  "deployments/scale"`. `scale` is its own subresource, so changing
  replicas goes through `apply`, which its Role does allow.

**Changing a fixed-name ConfigMap does not roll the Pods.** After
`01-configmap.yaml` changed the origin, the running frontend still served
the old `config.js`. A `rollout restart` was needed. Assignment 3 removes
this manual step: a hash-suffixed ConfigMap with Kustomize, a checksum
annotation with Helm.

## 4. Operators (Unit II 2.4) — evaluated, not deployed

Section 2.4.6 says to check for an existing Operator before writing one, and
that most teams run databases through one. For this application that would
be a Postgres Operator such as CloudNativePG. Its `Cluster` custom resource
asks for, say, three instances, and its controller provides what §3.2 shows
a StatefulSet cannot:

- streaming replication between the instances;
- automatic failover to a replica;
- scheduled backups to object storage;
- coordinated minor-version upgrades.

It was not installed, for three reasons:

1. Installing it would mean cluster-wide CRDs and a controller with broad
   RBAC on a shared course cluster. That is exactly the review §2.4.6 asks
   for before applying.
2. Its images would be several hundred MB over the same link that took
   21 minutes for the 116 MB controller image.
3. The given `dso202-db` image seeds its schema from
   `/docker-entrypoint-initdb.d`, which an Operator-managed cluster would
   replace with its own bootstrap.

The StatefulSet in `05-statefulset-db.yaml` is what such an Operator would
generate underneath, which is why §2.1.6 recommends writing it by hand
first. The repository's `dso202-operator-demo/` shows the reconcile-loop
mechanics on a toy resource.

## 5. Reflection

**The bug that Kubernetes hid.** The most useful result was not planned.
I added a liveness probe that, by design, should never restart the backend
for a database outage. When the backend restarted anyway, I could have
concluded that the probe was wrong and loosened it. Instead I read the
termination reason first (`Error`, exit code 1, not a probe kill) and then
the previous container's log, which pointed to an unhandled `error` event
in the `pg` Pool.

Assignment 1's checklist claimed the backend "does not crash-loop when
started before the database". That was true, but it only tested startup.
Kubernetes' restart policy made the crash look like self-healing, and it is
only a crash *loop* that anyone notices. I now check `lastState.terminated`
and `--previous` logs whenever a restart count moves, rather than trusting
that Running means healthy.

**A mistake in my own test.** My first persistence test inserted a task
with status `todo`, and the table's check constraint rejected it. I trimmed
that from the evidence and re-ran it with a valid status. The failed insert
still used up a sequence value, which is why the surviving rows are 1, 2, 3
and **5**. I left that gap as it is.

**Environment problems.**
- The OpenSSL path problem from the CSR lab returned in
  `make-tls-secret.sh`, which exited silently under `set -e` with its output
  discarded. I fixed the cause (Windows paths for native tools) rather than
  the symptom, and removed the `2>/dev/null` that hid it.
- The ingress controller image (116 MB) took 21 minutes to pull. I used
  that time to deploy and test everything that does not depend on it,
  instead of waiting.
- **"It works with `--resolve`" was the key diagnostic.** When HTTPS
  failed, the controller, the certificate and the proxy were all suspects.
  Pinning the name to 127.0.0.1 made the request succeed. That cleared
  everything inside the cluster at once and pointed at name resolution,
  where `nslookup -type=A` showed the missing record.
- The ingress-nginx admission webhook made a server-side dry-run of the
  Ingress *fail* while the controller was still starting (`failed calling
  webhook ... connection refused`). Once a controller with a webhook is
  installed, Ingress objects cannot even be validated until it is healthy.

**What I would do differently:**
- Write the probes before the first deployment, and test failure (database
  down) as deliberately as success.
- Use cert-manager instead of a script for TLS, once the cluster has
  outbound access fast enough to install it.
- Ingress-nginx is retired and receives no updates after March 2026, as
  §2.2.6 notes. A new deployment should use another controller or the
  Gateway API. I kept it because the notes and the kind provider manifest
  use it.

## 6. References

- *DSO202_Unit2_Lecture_Notes* (HackMD, sections 2.1–2.4) — accessed 2026-11-08
- *DSO202 Assignment 1 Image Build Guide* (`assignment1/assignment.pdf`) and the Assignment 1 submission
- *DSO202 Module Descriptor (resequenced)*, `Module_Descriptor_Resequenced.docx`
- ingress-nginx controller-v1.15.1 release and its `deploy/static/provider/kind/deploy.yaml` (github.com/kubernetes/ingress-nginx) — downloaded 2026-11-08
- node-postgres (`pg`) Pool behaviour, observed from the backend's own crash output on the cluster — 2026-11-08

## 7. Assessment Mapping (Module Descriptor)

Assessed under *B. Assignments* of the DSO202 module descriptor
(`Module_Descriptor_Resequenced.docx`), out of 10 marks.

| Criterion (descriptor) | Marks | Where it is evidenced |
|---|---|---|
| Code Organization & Readability | 1 | Manifests numbered in apply order, split by who applies them (admin vs deployer); vendored controller, image patch and scripts in their own directories; README with structure, rebuild and cleanup |
| Code Comments & Documentation | 1 | Every manifest header names its applier and the Unit II section behind each decision; inline comments on every non-default field; README and this report |
| Configuration Requirements | 2 | Contract restored (every Service ClusterIP); StatefulSet with headless + client Services; Ingress with TLS; per-workload ServiceAccounts; deployer and viewer RBAC (§1 table) |
| Configuration Implementation | 5 | §3.1–3.6: deployed as the deployer; StatefulSet identity, DNS, persistence and retention; probes with a diagnosed and fixed crash; tokenless, non-root, read-only workloads; RBAC allow/deny matrix and the patch-verb incident; Ingress routing and TLS |
| Deployment & Configuration | 1 | Reproducible bootstrap → deployer apply → rollout sequence; end-to-end CRUD through the Ingress; cleanup commands |
