# DSO202 — Assignment 3 Report

Assignment 2, packaged with Kustomize and with Helm.

## 1. Objective

Assignment 2 is a directory of numbered manifests for one environment. A
second environment would mean copying all fourteen files and editing
namespaces, hosts, replica counts and resources by hand. Every copy is then
a chance for drift.

This assignment packages the same application twice:

- **Kustomize:** a namespace-free base plus `dev` and `prod` overlays;
- **Helm:** a `tasktracker` chart plus `dev` and `prod` values files.

The two tools take the same environment decisions, so they can be compared
on equal terms:

| | dev | prod |
|---|---|---|
| frontend / backend replicas | 1 / 1 | 3 / 3 |
| backend, database resources | base | raised |
| database volume | 1Gi, **deleted** with the StatefulSet | **5Gi**, **retained** |
| PodDisruptionBudgets | none | `minAvailable: 2` on frontend and backend |
| host | `tasktracker[-helm]-dev.localhost` | `tasktracker[-helm]-prod.localhost` |

All four environments were deployed side by side on the shared cluster,
next to Assignment 2. The descriptor places Helm and Kustomize in Unit III
3.2. The brief's "Unit 4" is the original syllabus numbering for the same
material.

## 2. Environment

| Item | Value |
|---|---|
| Cluster | shared `dso202` kind cluster, Kubernetes v1.36.1 |
| kubectl / Kustomize / Helm | v1.36.3 / v5.8.1 (built in) / v4.3.1 |
| Ingress | ingress-nginx v1.15.1 from Assignment 2; host access through `assignment2/scripts/host-proxy.sh` |
| Images | `dso202-frontend:1.0`, `dso202-db:1.0`, `dso202-backend:1.1` (kind-loaded, `pullPolicy: Never`) |
| Namespaces | `dso202-a3-dev`, `dso202-a3-prod` (Kustomize); `dso202-a3-helm-dev`, `dso202-a3-helm-prod` (Helm) |

## 3. Kustomize

### 3.1 Structure and rendering (`evidence/stage1-kustomize-render.txt`)

The base is Assignment 2's objects with `metadata.namespace` removed: 11
resource files plus a `kustomization.yaml`. In the base,
`configMapGenerator` and `secretGenerator` replace the fixed-name
ConfigMap and Secret.

The overlays use four mechanisms:

| Mechanism | Used for |
|---|---|
| `namespace:` | puts every object in the environment's namespace, *and* rewrote the deployer RoleBinding's `subjects[0].namespace` to `dso202-a3-dev`. Without that, the binding would point at a ServiceAccount in a namespace that does not exist |
| `replicas:` | 1 (dev) / 3 (prod) without a patch file |
| `configMapGenerator` with `behavior: merge` | replaces `BACKEND_URL` and `CORS_ORIGIN`, keeps the base's other five keys |
| strategic-merge patch (`patch-resources.yaml`) | resources of one named container; every other field kept |
| JSON 6902 patches | the host in two list positions of the Ingress; the PVC size inside `volumeClaimTemplates`; `whenDeleted` |
| an extra resource (`pdb.yaml`) | PodDisruptionBudgets in prod only |

I filtered the dev-versus-prod diff of the rendered output to remove label
and namespace lines. What remains is exactly the table in §1: the two
origins, the hash names, replicas, resources, `whenDeleted`, 1Gi → 5Gi, the
two PDBs and the host.

Changing one base literal (`DB_PORT=5432` → `5433`) changed the generated
name from `app-config-h29cdc7dhk` to `app-config-kf5th9bg6c`, and back
again when reverted.

### 3.2 Deployment (`evidence/stage3-kustomize-deploy.txt`)

`kubectl apply -k` created 18 objects in dev and 20 in prod (prod adds the
two PDBs). The TLS Secrets came from Assignment 2's script.

| | dev | prod |
|---|---|---|
| Pods | 1 frontend, 1 backend, `db-0` | 3 frontend, 3 backend, `db-0` |
| PVC | `data-db-0` 1Gi | `data-db-0` **5Gi** |
| `whenDeleted` | `Delete` | `Retain` |
| PDB allowed disruptions | — | 1 and 1 |
| `/api/status` through the Ingress | 200, `db: connected` | 200, `db: connected` |
| `config.js` | `https://tasktracker-dev.localhost:8443` | `https://tasktracker-prod.localhost:8443` |
| POST a task | id 4 created | id 4 created |

Both environments have task id 4. They are separate databases, seeded the
same way.

### 3.3 Lifecycle (`evidence/stage4-kustomize-lifecycle.txt`)

**Config rollout through the hash.**

1. I added a literal (`NODE_OPTIONS`) to the dev overlay. `kubectl diff -k`
   showed every `app-config-h29cdc7dhk` reference changing to
   `app-config-h7d5549f49`.
2. `apply -k` *created* the new ConfigMap and reconfigured both Deployments
   and the StatefulSet. The backend's `generation` went from 1 to 2, and the
   Pods rolled with no `rollout restart`. Assignment 2 needed a manual
   restart for exactly this.

Three things the test showed that I had not expected:

1. **The new key never reached the process.** `printenv NODE_OPTIONS`
   printed nothing. The base Deployments, like Assignment 2's, list each
   variable with its own `configMapKeyRef`. A new key changes the hash and
   so restarts the Pods, but only listed keys are injected. The Helm chart
   uses `envFrom` instead.
2. **The database restarted as well.** The StatefulSet reads `POSTGRES_DB`
   from the same generated ConfigMap, so a change meant for the backend also
   rolled `db-0`. One shared generator ties the rollouts of all three tiers
   together. Separate generators per tier would avoid that.
3. **The old ConfigMap is left behind.** After reverting, both
   `app-config-…` objects existed: `apply` never deletes. I removed the
   orphan by hand. `kubectl apply --prune` or a GitOps tool with pruning
   (Practical 4) is the systematic answer.

**PodDisruptionBudget.** In prod, `backend` showed `ALLOWED DISRUPTIONS 1`.
Two evictions through the Eviction API, one after the other:

- the first returned `"status":"Success","code":201`;
- the second returned `TooManyRequests: Cannot evict pod as it would
  violate the pod's disruption budget` (allowed disruptions now 0).

Once the Deployment replaced the evicted Pod, it returned to 1. A
`kubectl drain` would have waited at that point instead of taking a second
backend replica down.

## 4. Helm

### 4.1 Chart design (`helm/tasktracker/`)

| Template | What it adds over Assignment 2 |
|---|---|
| `_helpers.tpl` | release-prefixed names (two releases can share a namespace; `helm template blue` gives `blue-tasktracker-backend`, ...), recommended labels, minimal immutable selector labels, `tasktracker.origin` |
| `configmap.yaml` | `BACKEND_URL` and `CORS_ORIGIN` **derived** from `ingress.host` and `publicPort`. In Kustomize they are written by hand in each overlay, separately from the host patch. Port 443 is omitted automatically |
| `secret.yaml` | password = value, else the **existing** one (`lookup`), else `randAlphaNum 24` |
| `tls-secret.yaml` | `genSelfSignedCert` for the host, reused on upgrade only if issued for the same host |
| `db.yaml`, `backend.yaml`, `frontend.yaml` | `checksum/config` and `checksum/secret` annotations; `envFrom` for the backend |
| `pdb.yaml` | `fail` if `minAvailable >= replicas` (a budget no drain could ever satisfy) |
| `tests/test-api.yaml` | `helm test`: page served, `config.js` has the derived origin, backend reports `db: connected` |
| `values.schema.json` | types, ranges, enums and patterns for every value |

### 4.2 Validation (`evidence/stage2-helm-validate.txt`)

`helm lint` passed for both environments. Five bad inputs were rejected
before anything reached the cluster:

| Input | Rejected by | Message |
|---|---|---|
| `frontend.replicas=0` | schema | `minimum: got 0, want 1` |
| `db.storage.size=5GB` | schema | `'5GB' does not match pattern '^[0-9]+(Mi\|Gi\|Ti)$'` |
| `ingress.host=Task_Tracker.local` | schema | does not match the DNS-name pattern |
| `images.pullPolicy=Sometimes` | schema | `value must be one of 'Always', 'IfNotPresent', 'Never'` |
| PDB enabled with `backend.replicas=1` | template `fail` | `minAvailable (1) must be lower than backend.replicas (1), or no Pod could ever be evicted` |

The schema checks each value on its own. Only the template can compare two
values, which is why the PDB rule is a `fail`.

Two renders without a cluster produced different password hashes. Under
`helm template`, `lookup` returns nothing, so a new random value is
generated each time. The rendered evidence therefore redacts passwords and
certificates.

### 4.3 Install and test (`evidence/stage5-helm-install.txt`)

`helm upgrade --install ... --wait` deployed both releases, and their NOTES
printed the URL. Both `helm test` runs ended `Phase: Succeeded`:

```
frontend: page served
  BACKEND_URL: "https://tasktracker-helm-prod.localhost:8443"
backend: database connected
```

Prod has 3+3 Pods, a 5Gi PVC `data-tasktracker-prod-db-0` and two PDBs.
The certificate presented for each host was the chart's own
(`subject=CN=tasktracker-helm-prod.localhost`). The generated password is
24 characters long.

### 4.4 Release lifecycle (`evidence/stage6-helm-lifecycle.txt`)

Each step recorded a short hash of the password and the certificate, plus
the backend Pod names:

| Rev | Action | Password | Certificate | Pods |
|---|---|---|---|---|
| 1 | install | `6a8e4c…` | `30446a…` (no host annotation) | — |
| 2 | chart 0.1.1, same values | same | **new** `10a90c…`: the old Secret had no host annotation, so it was regenerated once | **rolled** |
| 3 | same upgrade again | same | same | **unchanged** (no new Pod) |
| 4 | `--set ingress.host=tasktracker-helm-dev2.localhost` | same | **new** `3607f2…`, `CN=…dev2…` | rolled; `config.js` shows the new origin; data intact |
| 5 | `helm rollback 3` | same | **`10a90c…` again** | rolled; the old host answers, `dev2` → 404 |

What the table shows:

- **`lookup` kept the password through every revision.** That matters more
  than it looks. Postgres only reads `POSTGRES_PASSWORD` when it
  initialises an empty data directory, so a chart that generated a new
  password on each upgrade would lock the backend out of its own database.
  The tasks created at install time were still listed at revision 4.
- **A rollback does not re-render the templates.** Revision 5 restored the
  *exact* certificate of revision 3. `helm rollback` re-applies the
  manifest stored in revision 3's release record
  (`sh.helm.release.v1.tasktracker-dev.v3`), so `lookup`,
  `genSelfSignedCert` and `randAlphaNum` do not run again.
- **Revision 2 restarted everything, including the database, without a
  value change.** The cause is my label helper: the Pod templates carry
  `helm.sh/chart: tasktracker-0.1.1`, so every chart version bump changes
  every Pod template.
- **Revision 3 changed nothing**, so the checksum annotations only roll
  Pods when the rendered config or secret actually changes.
- `helm get values --revision 4` showed the `dev2` host; the current values
  showed the original one. `helm history` and the five release-record
  Secrets confirm the sequence.

**A fix made during the lifecycle test.** My first `tls-secret.yaml` reused
any existing certificate. I realised before running revision 4 that
changing the host would then keep serving a certificate for the *old*
name. The template now stores the host in the annotation
`tasktracker.dso202/certificate-host` and reuses the certificate only when
it matches. That is why the chart is 0.1.1, and revision 4 shows it working.

**Backend Pods stop slowly.** Deleting a running backend Pod took 33 s
against a 30 s grace period; an nginx Pod took under a second. The
backend's PID 1 is `node src/server.js`. PID 1 gets no default signal
handling, and the app installs no SIGTERM handler, so the kubelet waits out
the grace period and sends SIGKILL. Every rollout and rollback above waited
about 30 s per old backend Pod.

## 5. Kustomize and Helm compared, on this application

| Concern | Kustomize | Helm |
|---|---|---|
| Learning cost / readability | plain YAML; the base is valid Kubernetes as it stands | Go templates + Sprig; harder to read, but one parameterised source |
| Keeping related values consistent | by hand (origin written in each overlay, separately from the host patch) | derived (`tasktracker.origin`) |
| Config-change rollouts | automatic (hash name); orphans old ConfigMaps | automatic (checksum annotations); no orphans |
| Secrets and generated data | literals in Git | generated once, kept with `lookup`; frozen in release records on rollback |
| Validation | whatever the API server rejects | schema + `fail` + `lint` + `helm test`, before and after install |
| History and rollback | none of its own (Git history) | revisions, `history`, `rollback`, `get values --revision` |
| Removing things | `delete -k`; `apply` leaves removed objects behind | `uninstall` removes the release's objects (not StatefulSet PVCs or the namespace) |
| Fit | a team's own app, varied per environment, especially with GitOps (Argo CD renders Kustomize natively) | something distributed to others, or needing lifecycle and generated values |

The two are not exclusive. A common pattern is a Helm chart for a
third-party component, then a Kustomize overlay or Argo CD on top for the
environment.

## 6. Reflection

**What went wrong first was DNS, not Kubernetes.** The hosts were
originally `*.localtest.me`, a public name that resolves to loopback. On
this network only the IPv6 answer survives (diagnosed in Assignment 2), so
all four environments were moved to `*.localhost`. Because each tool
declares the host in one place per environment, the change was a single
`sed` across both packages. Assignment 2's copy-per-file layout would have
been worse.

**My own tests corrected my assumptions three times:**

1. I expected a new ConfigMap key to reach the backend. It changed the hash
   but not the environment, because the Deployment lists its variables one
   by one.
2. I expected "change backend config" to restart only the backend. The
   shared generator restarted the database too.
3. I expected `helm rollback` to behave like an upgrade with old values. It
   replays the stored manifest, generated data included. In this case that
   was the desired behaviour (the old certificate came back), but it would
   surprise anyone relying on `lookup` during a rollback.

**A bug I caught before it shipped:** reusing a TLS certificate after the
host changes. It would have passed every test that keeps the host fixed.

**What I would do differently:**

- Keep `helm.sh/chart` and `app.kubernetes.io/version` out of the Pod
  template labels, and use only the stable selector labels plus
  `component`. Then a chart bump would not restart the database (revision
  2).
- Use one generator per tier in Kustomize, and `envFrom` in the base as
  well as the chart.
- Add a SIGTERM handler to the backend: close the HTTP server and the pool,
  then exit. That turns 30-second rollouts into one-second ones.
- Put the generated Helm password into an external secret store, or at
  least mark the Secret `helm.sh/resource-policy: keep`, so that
  `helm uninstall` with `retainOnDelete` keeps both the data *and* the
  password that opens it.

## 7. References

- *01-kustomize-concepts*, *02-patches-and-generators*, *03-kind-hands-on-lab* (HackMD, course notes)
- *Unit III 3.2 — Helm* (HackMD, course notes)
- *DSO202 Module Descriptor (resequenced)*, `Module_Descriptor_Resequenced.docx`
- Assignment 2 of this repository (`assignment2/`), the application being packaged
- Kustomize v5.8.1 and Helm v4.3.1 command output on the `dso202` cluster — 2026-11-08

## 8. Assessment Mapping (Module Descriptor)

Assessed under *B. Assignments* of the DSO202 module descriptor
(`Module_Descriptor_Resequenced.docx`), out of 10 marks.

| Criterion (descriptor) | Marks | Where it is evidenced |
|---|---|---|
| Code Organization & Readability | 1 | Kustomize base/overlays and a standard Helm chart layout, with environment values kept outside the chart; one concern per patch and template file |
| Code Comments & Documentation | 1 | Header comments in every kustomization, patch and template explaining the decision; documented `values.yaml`; README; this report |
| Configuration Requirements | 2 | The same dev/prod decisions in both tools (§1 table); generators/checksums for config rollout; schema, `fail` guard and `helm test` |
| Configuration Implementation | 5 | §3–4: four environments deployed and reached through the Ingress; hash rollout, PDB eviction, orphan handling; Helm install, test, upgrades, host change, rollback with password/certificate tracking |
| Deployment & Configuration | 1 | README deploy and cleanup commands; `helm list` / `kubectl get ingress -A` final state with all five environments answering (`evidence/final-state.txt`) |
