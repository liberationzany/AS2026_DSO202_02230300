# DSO202 — Practical 5 Report

Use Kustomize to manage environment-specific configurations for a Kubernetes
application.

## 1. Objective

The same application usually runs in several environments that differ in a
few settings, such as namespace, replicas, image version, resources and
content. Keeping a full copy of the manifests per environment means every
common change must be made several times, and a missed copy is
configuration drift.

This practical uses Kustomize to keep the shared resources once (the
**base**) and to describe each environment only by its differences (an
**overlay**). The working rule is "render first": inspect the YAML
Kustomize produces before the API server sees it.

Specifically, the practical:

- renders a base and four overlays;
- deploys dev, staging, prod and qa without copying `deployment.yaml` or `service.yaml`;
- uses the `namespace`, `labels`, `replicas` and `images` transformers, a
  `configMapGenerator`, a strategic-merge patch and a JSON 6902 patch;
- demonstrates the ConfigMap-hash rollout chain;
- predicts and checks a reference-aware `namePrefix` render.

Descriptor coverage: Unit III (configuration management). The resequenced
descriptor's Practical 4, "Use Kustomize to manage environment-specific
configurations for a Kubernetes application".

## 2. Environment

| Item | Value |
|---|---|
| Operating system | Windows 11, build 10.0.26300; commands from Git Bash |
| Docker | Docker Desktop 29.4.0, WSL 2 backend |
| kind | v0.32.0 |
| kubectl | client v1.36.3, **kustomizeVersion v5.8.1** (from `kubectl version --client -o yaml`) |
| Cluster | shared `dso202` kind cluster: `control-plane`, `worker-node-1`, `worker-node-2`, v1.36.1, containerd 2.3.1 |
| Images | `nginx:1.30-alpine`, `nginx:1.31-alpine`, `busybox:1.37`, all already cached on the nodes |

**Deviations from the guide:**

- **The example repository was built for this practical.** The guide
  assumes an existing `examples/webapp` repository, which was not supplied.
  I wrote it following the course notes *01-kustomize-concepts* and
  *02-patches-and-generators*: the same base files, `web-content`
  generator, `replace` behaviour, `patch-resources.yaml`, and
  `app.kubernetes.io/*` labels.
- **The image tags differ from the notes.** The notes use
  `nginx:1.27-alpine`. I used the two nginx tags already on the nodes
  instead, because Practical 4 showed that image pulls on this connection
  take many minutes.
- **The port-forward used port 8085.** Port 8080 was already in use by the
  Argo CD UI forward from Practical 4.
- **Rendered output went to `evidence/rendered/`** instead of `/tmp/`, so it
  is kept as evidence.

## 3. Procedure and Observations

### Task 0 — Pre-flight (`evidence/task0-preflight.txt`)

The context was `kind-dso202`, and all three nodes were `Ready`.
`kubectl version --client -o yaml` reported `kustomizeVersion: v5.8.1`,
so `kubectl kustomize` and `-k` are available. The output shows that the
built-in Kustomize can be used with no extra install.

### Task 1 — Read the repository (`evidence/task1-tree.txt`)

```
examples/webapp/
├── base
│   ├── deployment.yaml
│   ├── index.html
│   ├── kustomization.yaml
│   └── service.yaml
└── overlays
    ├── dev        (index.html, kustomization.yaml, namespace.yaml)
    ├── prod       (index.html, kustomization.yaml, namespace.yaml, patch-resources.yaml)
    ├── qa         (index.html, kustomization.yaml, namespace.yaml, patch-annotation.yaml)
    ├── sandbox    (kustomization.yaml, PREDICTION.md)
    └── staging    (index.html, kustomization.yaml, namespace.yaml)
```

1. **Files that exist only once:** `base/deployment.yaml`,
   `base/service.yaml` and `base/kustomization.yaml` (plus the placeholder
   `base/index.html`).
2. **Values that differ:** namespace, environment label, replicas, image
   tag, page content, prod resources, and the qa owner annotation.
3. **Where the differences live:** in each overlay's `kustomization.yaml`
   (transformers and generator), its `index.html`, and its patch file.
   Nowhere else.

### Task 2 — Render the base (`evidence/task2-render-base.txt`)

```
$ kubectl kustomize examples/webapp/base | grep '^kind:'
kind: ConfigMap
kind: Service
kind: Deployment
$ kubectl kustomize examples/webapp/base | grep -n 'name: web-content'
13:  name: web-content-d5t9kfg4d9          <- the generated ConfigMap
66:          name: web-content             <- volumeMount (local volume name)
70:          name: web-content-d5t9kfg4d9  <- the Deployment's rewritten reference
71:        name: web-content               <- the volume's own name
```

**Checkpoint: why the name is not exactly `web-content`.** The
`configMapGenerator` appends a hash of the ConfigMap's *content* to the
logical name. Kustomize then rewrites every reference to `web-content` in
the other resources to the hashed name. The local volume and mount names
are not object references, so they stay as `web-content`. The output shows
that the Deployment file never needs to contain the hash.

### Task 3 — Compare dev and prod without touching the cluster (`evidence/task3-compare-dev-prod.txt`)

Excerpt of `diff -u` between the two renders, which are both 86 lines:

```
-  name: webapp-dev                        +  name: webapp-prod
-    <h1>DEV v1</h1>                       +    <h1>PRODUCTION</h1>
-  name: web-content-2gd6cctf49            +  name: web-content-9dkcdmkmf8
-    app.kubernetes.io/environment: dev    +    app.kubernetes.io/environment: prod
-  replicas: 1                             +  replicas: 4
-      - image: nginx:1.31-alpine          +      - image: nginx:1.30-alpine
   limits:  cpu 100m / memory 64Mi    ->   cpu 250m / memory 128Mi
   requests: cpu 50m / memory 32Mi    ->   cpu 100m / memory 64Mi
```

There are seven differences: namespace, environment label, replica count,
image tag, resource requests/limits, page content, and the ConfigMap hash.
The hash differs only *because* the content differs. Everything else
(ports, probe, selector, volume layout) is identical. The output shows that
each environment difference can be explained by reading a few lines of an
overlay, not by reviewing a duplicate Deployment.

### Task 4 — Deploy dev safely (`evidence/task4-deploy-dev.txt`)

```
$ kubectl diff -k examples/webapp/overlays/dev
Error from server (NotFound): namespaces "webapp-dev" not found
$ kubectl apply -k examples/webapp/overlays/dev
namespace/webapp-dev created
configmap/web-content-2gd6cctf49 created
service/webapp created
deployment.apps/webapp created
$ kubectl get all -n webapp-dev
pod/webapp-59d7d8df84-mgq2x   1/1   Running
service/webapp   ClusterIP   10.96.113.249   80/TCP
deployment.apps/webapp   1/1
replicaset.apps/webapp-59d7d8df84   1   1   1
```

The `diff` error is discussed in §5. The output shows the Deployment keeps
the base name `webapp`; only the namespace separates the environment.

### Task 5 — Reach the application (`evidence/task5-reach-app.txt`)

`kubectl port-forward -n webapp-dev service/webapp 8085:80`, then:

```
$ curl -s http://127.0.0.1:8085
<h1>DEV v1</h1>
<p>Environment: dev. Experimental build, one replica.</p>
```

The output shows the page served is the dev overlay's `index.html`, not
the base placeholder, so `behavior: replace` worked.

### Task 6 — The ConfigMap hash / rollout chain (`evidence/task6-hash-rollout.txt`)

| | Before | After editing `overlays/dev/index.html` to `DEV v2 -- configuration changed` |
|---|---|---|
| Generated ConfigMap | `web-content-2gd6cctf49` | `web-content-8hc9b5tgbm` (old one still present) |
| Deployment volume reference | `web-content-2gd6cctf49` | `web-content-8hc9b5tgbm` |
| Deployment `generation` | 1 | 2 |
| ReplicaSet | `webapp-59d7d8df84` | `webapp-797d89cc59` (old scaled to 0) |
| Pod | `webapp-59d7d8df84-mgq2x` | `webapp-797d89cc59-p62xg` (old one `Terminating`) |
| Served page | `DEV v1` | `DEV v2 -- configuration changed` |

`kubectl diff -k` before applying showed exactly the predicted change:
`generation: 1 → 2`, the `configMap.name` line, and a new ConfigMap object.

**The chain, in my own words.** I changed one line of HTML. The generator
hashes the ConfigMap's content, so new content produced a new hash and
therefore a new ConfigMap *name*. Kustomize rewrote the Deployment's
volume to point at that new name. That reference sits inside
`spec.template`, so the Pod template changed. Any Pod-template change makes
the Deployment controller create a new ReplicaSet and roll the Pods. If I
had edited a fixed-name ConfigMap in place, the template would not have
changed. The running Pod would have kept its old mount until the kubelet
re-synced, and nothing would have rolled or been recorded in
`rollout history`. The old ConfigMap `web-content-2gd6cctf49` is still
there after the rollout, which is what makes a rollback to revision 1
possible without regenerating anything.

### Task 7 — Deploy staging and prod (`evidence/task7-staging-prod.txt`)

```
NAMESPACE        NAME     READY   ...   ENVIRONMENT
webapp-dev       webapp   1/1           dev
webapp-prod      webapp   4/4           prod
webapp-staging   webapp   2/2           staging
```

Images: dev and staging `nginx:1.31-alpine`; prod `nginx:1.30-alpine`.
Each environment's Service served its own page (`DEV v2…`, `STAGING`,
`PRODUCTION`) when fetched from a busybox Pod inside that namespace. The
seven Pods were spread over both workers.

**Replica counts by environment:** dev 1, staging 2, prod 4, and later qa 2.

### Task 8 — What the prod patch changed (`evidence/task8-prod-patch.txt`)

The rendered prod container:

```
        resources:
          limits:   {cpu: 250m, memory: 128Mi}
          requests: {cpu: 100m, memory: 64Mi}
```

The live objects agree: prod is
`{"limits":{"cpu":"250m","memory":"128Mi"},"requests":{"cpu":"100m","memory":"64Mi"}}`,
while dev keeps the base `{"limits":{"cpu":"100m","memory":"64Mi"},"requests":{"cpu":"50m","memory":"32Mi"}}`.

1. **Deleted or merged?** Merged. The patch named the container `webapp`
   (the merge key for the `containers` list) and supplied four values,
   which replaced the base's four. Every field the patch did not mention
   survived: the image, ports, readiness probe and volume mounts are all
   still in the rendered prod container (the `readinessProbe`,
   `volumeMounts` and `containerPort` check counts 3). A
   replacement would have left a container with only `name` and
   `resources`.
2. **Which environment owns the production resource policy?** Only prod.
   It lives in `overlays/prod/patch-resources.yaml`, and no other overlay
   references it.
3. **Why a patch rather than copying `deployment.yaml` into `prod/`?** The
   patch is 16 lines and contains *only* the policy that differs. A copied
   Deployment would also duplicate the image, probe, ports and volumes.
   The next common change, such as a new probe in the base, would then
   silently miss prod, which is exactly the drift Kustomize exists to
   prevent.

### Task 9 — The QA overlay (`evidence/task9-qa-overlay.txt`)

Files (full text in the evidence and in `examples/webapp/overlays/qa/`):
`index.html`, `kustomization.yaml`, `namespace.yaml` and
`patch-annotation.yaml`. Neither `deployment.yaml` nor `service.yaml` was
copied.

```yaml
# patch-annotation.yaml  (JSON 6902)
- op: add
  path: /metadata/annotations/training.example.com~1owner
  value: qa-team
# kustomization.yaml
patches:
  - path: patch-annotation.yaml
    target: {group: apps, version: v1, kind: Deployment, name: webapp}
```

The rendered Deployment contained `training.example.com/owner: qa-team`
before anything was applied. After `apply -k`, the live Deployment showed
`replicas=2 image=nginx:1.30-alpine owner=qa-team` and the label
`environment: qa`, and the Service returned `<h1>QA</h1>`. The patch went
through one wrong version first, described in §5.

### Challenge extension — `namePrefix` in a sandbox overlay (`evidence/challenge-nameprefix.txt`)

I wrote the predictions in `overlays/sandbox/PREDICTION.md` *before*
rendering. All of them held:

- `sandbox-webapp` for the Deployment and the Service.
- `sandbox-web-content-d5t9kfg4d9` for the ConfigMap, **and** for the
  Deployment's `configMap.name` reference.
- The volume name, mount name, container name and every label/selector
  value were unchanged.
- The hash `d5t9kfg4d9` is identical to the base's, because the prefix
  changes the name, not the content being hashed.

This is the "reference-aware" part. Kustomize knows that
`volumes[].configMap.name` points at a ConfigMap, so it renamed the
reference along with the object. A plain text search-and-replace would
either miss the reference or wrongly rename the volume's own name. The
sandbox was only rendered, never applied.

### Task 10 — Cleanup (`evidence/task10-cleanup.txt`)

`kubectl delete -k` for dev, staging, prod and qa. Afterwards,
`kubectl get ns | grep webapp-` printed nothing, and no `web-content`
ConfigMap remained anywhere.

## 4. Analysis

**Strategic merge versus JSON 6902.**

| | Strategic merge (prod `patch-resources.yaml`) | JSON 6902 (qa `patch-annotation.yaml`) |
|---|---|---|
| What the file looks like | a fragment of a Deployment | a list of `op` / `path` / `value` operations |
| How it finds its object | from `apiVersion` / `kind` / `metadata.name` inside the patch | from an explicit `target:` in `kustomization.yaml` |
| Lists | merged by Kubernetes' merge key (containers by `name`) | addressed by index, e.g. `/spec/template/spec/containers/0` |
| Keys containing `/` | written normally | must be escaped as `~1` |
| Best for | readable changes to Kubernetes-shaped data (resources, a named container) | one precise operation at a known path (an annotation, removing a field) |

In short, strategic merge speaks Kubernetes and JSON 6902 speaks paths. The
prod resource change is easier to review as a strategic merge, because the
reader sees a container named `webapp` with new resources. The qa
annotation could have been written either way: a strategic-merge fragment
with `metadata.annotations` containing `training.example.com/owner` would
work just as well. The task required JSON 6902, which makes the operation
and its exact location explicit, at the cost of `~1` escaping and a
separate `target:`. As §5 shows, the path-level power of JSON 6902 is also
its risk: an `add` on a *parent* path replaces the whole subtree, whereas a
strategic merge of the same annotations map would have kept the existing
keys.

**Why the environment label uses `includeSelectors: false`.** A
Deployment's `spec.selector` is immutable after creation, and the Service
routes by its selector. Keeping the environment label out of the selectors
means every overlay renders the same `app.kubernetes.io/name: webapp`
selector, so changing or adding an environment label can never break
routing or block an update.

**Why `images:` rather than a patch.** Pinning prod to `1.30-alpine` while
dev and staging run `1.31-alpine` is a one-line transformer per overlay. A
reviewer can see in prod's `kustomization.yaml` that production is pinned,
and a change to the base image cannot reach prod by accident.

**What `apply -k` does not do.** It does not prune. After Task 6,
`webapp-dev` held two `web-content-*` ConfigMaps. `delete -k` likewise
removes only what the overlay renders *now*: it listed
`web-content-8hc9b5tgbm` but not `web-content-2gd6cctf49`. The old one went
away only because the namespace was deleted. On a long-lived environment,
old generated ConfigMaps accumulate until something prunes them, for
example Argo CD with `prune: true` from Practical 4, or
`kubectl apply --prune` with a label selector.

## 5. Reflection

**The Kustomize mistake, and how the rendered output exposed it.** For the
QA annotation, I assumed a JSON 6902 `add` to
`/metadata/annotations/<key>` would fail because the base Deployment has no
`annotations` map. To be "safe", I wrote a two-operation patch: first
`add /metadata/annotations` with `value: {}`, then add the key. I even
wrote in the patch's comment that the render fails without the first
operation.

Before relying on that comment, I tested it by rendering a scratch copy of
the overlay with only the single `add`. The render succeeded and contained
`training.example.com/owner: qa-team`, so Kustomize v5.8.1 creates the
missing map itself and my assumption was wrong. That made me ask what the
"safe" first operation actually does when an annotations map already
exists. I rendered the two-operation patch against a Deployment that
already carried `existing.example.com/keep: "yes"`, and the output showed
the existing annotation **gone**: `add` on the parent path *replaces* the
whole map. My defensive patch would have silently deleted other teams'
annotations the first time anyone added one to the base.

The diagnostic commands were `kubectl kustomize <overlay> | grep -A4 '^kind:
Deployment'` and a `sed -n '/^metadata:/,/^  name:/p'` over the render. I
removed the first operation, and the patch file's comment now explains why.
Reading the patch alone looked correct both times; only the rendered output
showed what it really did.

**A second issue: `kubectl diff -k` on a first deployment.** For each new
environment, the guide's safe step 2 failed with
`Error from server (NotFound): namespaces "webapp-dev" not found`. The
guide's `|| true` hides this, so it is easy to read "no output" as "no
differences". The cause is that `kubectl diff` performs a server-side dry
run, and the API server cannot dry-run objects into a namespace that does
not exist yet, even though the same overlay would create it. On a first
deployment, the render (step 1) is the only real preview. On later
deployments the namespace exists, and `diff` worked as intended: in Task 6
it showed the exact `generation` and `configMap.name` change before the
apply.

**What I would do differently.** I would add an annotation to the base
early on, so that any patch touching `/metadata/annotations` is tested
against a non-empty map from the start. For first deployments, I would
create namespaces in a separate step, so that `kubectl diff -k` is
meaningful even the first time.

**One thing that remains unclear.** Practical 4's Argo CD would prune the
orphaned `web-content-<old-hash>` ConfigMaps. However, I have not checked
whether Argo CD's own rendering of an overlay keeps the old one long enough
for a ReplicaSet rollback to work. That would decide whether a rollback
under GitOps should be done by `git revert` (regenerating the old hash) or
by `kubectl rollout undo`.

## 6. References

- *Practical — Environment-Specific Configuration with Kustomize on Kind* (03-kind-hands-on-lab, HackMD), course-provided — accessed 2026-11-07
- *Kustomize — Concepts That Must Stick* (01-kustomize-concepts, HackMD), course-provided — accessed 2026-11-07
- *Kustomize — Patches and Generators Deep Dive* (02-patches-and-generators, HackMD), course-provided — accessed 2026-11-07
- *DSO202 Module Descriptor (resequenced)*, `Module_Descriptor_Resequenced.docx` — accessed 2026-11-07
- `kubectl version --client -o yaml` (Kustomize v5.8.1) and `kubectl kustomize` render output — 2026-11-07

## 7. Assessment Mapping (Module Descriptor)

Assessed under *A. Practical Work & Report* of the DSO202 module descriptor
(`Module_Descriptor_Resequenced.docx`): practical report out of 5, practical
work out of 15.

### Practical Report (5 marks)

| Criterion (descriptor) | Marks | Where it is evidenced |
|---|---|---|
| Documentation | 2 | §1 Objective; §2 Environment with Kustomize version and each deviation; §3 one subsection per task with real output, covering all nine evidence items the guide lists (tree, dev render, dev/prod diff, `get all -n webapp-dev`, ConfigMap names before/after, Pod names before/after, QA files, strategic merge vs JSON 6902, reflection); §6 References |
| Reflection | 2 | §5: a real Kustomize mistake (the two-op JSON 6902 patch), the render commands that exposed it, a second issue (`diff -k` on first deploy) with its cause, what would be done differently, and an open question |
| Clarity & Coherence | 1 | §3 Task 6 chain in my own words, Task 1/2/8 questions answered; §4 comparison table and the prune and selector analysis |

### Practical Work (15 marks)

| Criterion (descriptor) | Marks | Where it is evidenced |
|---|---|---|
| Code Organisation & Readability | 3 | Same practical structure as earlier practicals (README, `evidence/`, `report/`); base/overlay layout with thin overlays and no copied resources; consistent `app.kubernetes.io/*` labels |
| Code Comments | 2 | Header and per-field comments in every `kustomization.yaml`, base resource and patch; the qa patch comment records the verified pitfall |
| Functional/Configuration Requirements | 10 | Four environments deployed and verified (`task4`, `task7`, `task9`); hash rollout chain (`task6`); prod strategic merge (`task8`); qa JSON 6902 annotation live (`task9`); `namePrefix` challenge with prediction (`challenge-nameprefix.txt`, `PREDICTION.md`); clean teardown (`task10`) |
