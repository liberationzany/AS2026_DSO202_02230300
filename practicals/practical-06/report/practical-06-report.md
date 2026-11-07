# DSO202 — Practical 6 Report

Create a Helm chart for an application and deploy it to Kubernetes
(Unit III 3.2 — Helm).

## 1. Objective

Practical 5 used Kustomize to vary plain manifests between environments.
This practical uses Helm, which adds what Kustomize does not have:

- a versioned package (the chart);
- a record of every deployment of it (the release and its revisions);
- lifecycle commands to install, upgrade, roll back and uninstall as one unit.

First I operated a published chart (podinfo), so the release lifecycle was
concrete before writing any chart code. Then I wrote my own chart,
`webapp`, for the Practical 1 nginx page. I validated it with every check
Helm and Kubernetes offer, deployed it as separate dev and prod releases,
and pushed it through upgrades, a rollback, a drift conflict and a failed
upgrade with automatic rollback.

Descriptor coverage: Unit III 3.2.1 (charts, releases and repositories),
3.2.2 (templates, values, validation) and 3.2.3 (install, upgrade,
rollback, release history, server-side apply). This is the resequenced
descriptor's Practical 5, and it prepares for the Final Project item
"Create Helm charts for deploying the application to Kubernetes".

## 2. Environment

| Item | Value |
|---|---|
| Operating system | Windows 11, build 10.0.26300; commands from Git Bash |
| Docker | Docker Desktop 29.4.0, WSL 2 backend |
| kind / kubectl | kind v0.32.0; kubectl client v1.36.3 |
| Helm | `version.BuildInfo{Version:"v4.3.1", ..., KubeClientVersion:"v1.37"}`, installed with winget; the notes were written against v4.3.0 |
| Cluster | shared `dso202` cluster: `control-plane`, `worker-node-1`, `worker-node-2`, v1.36.1 |
| Published chart | `podinfo/podinfo` 6.15.0 (pinned; the repository now also offers 6.16.0 and 6.17.0) |
| Own chart | `webapp` 0.1.0, appVersion `1.30-alpine` |

The deviations are listed in the README:

- dev uses NodePort 30083, because 30080 is held by Practical 1;
- local port-forward ports were changed to avoid Argo CD's 8080;
- Stage 6 was reconstructed from section 3.2.3, because the notes end
  before its steps;
- `python` replaced `jq` for decoding the release record.

## 3. Procedure and Observations

### Stage 0 — Helm and the cluster (`evidence/stage0-setup.txt`)

`helm version` reported v4.3.1, and `helm list -A` printed only headings.
`helm env` showed Windows paths for the repository config and cache, and
**`HELM_NAMESPACE="dso202-operators"`, not `default`**. Helm takes its
default namespace from the current kubeconfig context, which still pointed
at the operator demo's namespace. The output shows that a bare `helm
install` here would have placed a release in an unrelated namespace, so
every later command passes `-n`.

### Stage 1 — Consuming a published chart (`evidence/stage1-podinfo.txt`)

`helm repo add` and `helm repo update` worked as the notes describe.
`helm search repo podinfo --versions` listed **6.17.0, 6.16.0, 6.15.0**,
so the version the notes call current is now two releases old. Pinning
`--version 6.15.0` is the only reason this run installed the same software
as the notes. `helm show chart` confirmed the legacy `apiVersion: v1`.

**The first install failed:**

```
$ time helm install my-podinfo podinfo/podinfo --version 6.15.0 ... --wait --timeout 15m
Error: INSTALLATION FAILED: resource Deployment/dso202-helm/my-podinfo not ready.
       status: Failed, message: Progress deadline exceeded
real	10m33.029s
... Successfully pulled image "ghcr.io/stefanprodan/podinfo:6.15.0" in 10m5.458s ... Image size: 34763248 bytes.
```

The diagnosis is in §5. Once the image was on both nodes, I uninstalled
the failed release and reinstalled it, which took 12 s. Then:

```
$ curl -s http://localhost:8086 | grep -E '"(version|message)"'
  "version": "6.15.0",
  "message": "Hello from DSO202",
$ kubectl get secrets -n dso202-helm --show-labels
sh.helm.release.v1.my-podinfo.v1   helm.sh/release.v1   ...   name=my-podinfo,owner=helm,status=deployed,version=1
```

Decoding the record (base64, base64, gunzip, JSON) showed
`"apply_method": "ssa"` and the user values in plain text.

**Values-loss upgrade:** `helm upgrade ... --set ui.color='#2e7d32'` left
`USER-SUPPLIED VALUES: ui: color: '#2e7d32'` only, and `spec.replicas`
fell to **1**. The custom message and the replica count were silently
discarded. `--reuse-values` merged them back (revision 3).

**Rollback:**

```
REVISION  STATUS      DESCRIPTION
1         superseded  Install complete
2         superseded  Upgrade complete
3         superseded  Upgrade complete
4         deployed    Rollback to 1
```

`helm get values --revision 2` still returned only the colour, so every
past revision stays readable.

**Uninstall and OCI:** after `helm uninstall`, the namespace remained.
`kubectl get all` still showed both Pods as `Terminating`, because
uninstall returns before deletion completes. Installing from
`oci://ghcr.io/stefanprodan/charts/podinfo` needed no `repo add`. Helm
printed the artifact's digest:
`sha256:ff3d3e14728f75476ed4d43c14f80d52d81d36bc16906843463d464c6146f0d8`.

The output shows the full consume cycle, and that `upgrade --set` without
earlier values is a silent configuration loss.

### Stage 2 — Chart skeleton (`evidence/stage2-chart-skeleton.txt`)

`helm create scaffold` produced the eleven files the notes list, including
the Helm 4 `templates/httproute.yaml`. I deleted the scaffold and created
`webapp/` with `Chart.yaml` (`version: 0.1.0`, quoted
`appVersion: "1.30-alpine"`, `kubeVersion: ">=1.30.0-0"`), a fully commented
`values.yaml`, and a `.helmignore`. The `.helmignore` also excludes the
`.gitkeep` that keeps the empty `charts/` directory in Git. The package
listing in Stage 7 shows it was excluded.

### Stage 3 — Templates (`evidence/stage3-templates.txt`)

The dev render produced four objects in the order **ConfigMap, Service,
Deployment, Pod (test hook)**, the kind-based install order rather than
file order.

- **Names:** the object name is `webapp-dev` alone, because the release
  name already contains the chart name.
- **Image:** resolved to `nginx:1.30-alpine` from `appVersion`.
- **Resources:** `toYaml` printed `limits` before `requests`, because it
  sorts keys.
- **Checksum:** two consecutive renders produced the same
  `checksum/config: 1d50881e2b72ef33…`, so it is repeatable. It differs
  from the notes' `534e2ce7…`, because my ConfigMap text is not
  byte-identical to theirs.
- **Single template:** `-s templates/service.yaml` rendered one template
  alone, with `nodePort: 30083`.

### Stage 4 — Values precedence (`evidence/stage4-values.txt`)

- `-f dev.yaml --set replicaCount=2` gave `replicas: 2`: `--set` beats the
  file.
- `-f dev.yaml -f prod.yaml` gave prod's label and 3 replicas, but **kept
  dev's `type: NodePort` and `nodePort: 30083`**.
- The reverse order kept **prod's `cpu: 500m` / `100m`** under the dev label.
- `--set 'podAnnotations.prometheus\.io/scrape=true'` rendered
  `prometheus.io/scrape: true`, an unquoted boolean. `--set-string`
  rendered `"true"`. Installing the boolean version failed:

  ```
  Error: INSTALLATION FAILED: server-side apply failed for object dso202-dev/webapp-dev apps/v1, Kind=Deployment:
  ... .spec.template.metadata.annotations.prometheus.io/scrape: expected string, got &value.valueUnstructured{Value:true}
  ```

  `helm list --failed` then showed the release as `failed`, with
  **`configmap/webapp-dev` and `service/webapp-dev` already created**: a
  partial release. `helm uninstall` removed them. (`helm list -a` no longer
  exists in Helm 4.)
- `--set resources.limits=null` deleted the default limits block.

The output shows deep merging of maps, why environment files must not be
layered, and that type conversion errors surface only at the API server.

### Stage 5 — Validation (`evidence/stage5-validation.txt`)

| Failure | `helm template` | `helm lint` | Fixed by |
|---|---|---|---|
| 1. No environment | `Error: execution error at (webapp/templates/tests/test-connection.yaml:10:8): page.environment must be set (dev, staging or prod)` | `level=WARN ... missing required values`, **exit code 0**, also with `--strict` | supplying `-f environments/<env>.yaml` |
| 2. `nindent` removed | `YAML parse error ... line 59: mapping values are not allowed in this context`; `--debug` showed `cpu:` / `requests:` at column 0 | — | restoring `{{- toYaml .Values.resources \| nindent 12 }}` |
| 3. `tag: 1.30` | silently rendered `image: "nginx:1.3"` | — | `values.schema.json`: `- at '/image/tag': got number, want string` |
| 4. `replicas` → `replica` | exit 0 | `0 chart(s) failed`, exit 0 | caught only by `kubectl apply --dry-run=server`: `strict decoding error: unknown field "spec.replica"` |

With the schema in place, `--set replicaCount=three` and the
three-violation command were rejected, and every violation was listed at
once (`/page/environment`, `/service/type`, `/replicaCount`).
`helm install --dry-run=server` reported `Dry run complete` for the
misspelled field. The final loop printed `dev: ok` and `prod: ok`, and
both environments passed `kubectl apply --dry-run=server` (after
`dso202-prod` was created; see §5).

### Stage 6 — Release lifecycle of `webapp` (`evidence/stage6-lifecycle.txt`)

**Install and test:** `helm upgrade --install` created `webapp-dev` (1
replica, NodePort 30083) and `webapp-prod` (3 replicas, ClusterIP). Each
release's NOTES printed the access method matching its Service type.
`helm test` returned `Phase: Succeeded` for both. Dev answered on the
NodePort from a node
(`docker exec dso202-control-plane curl -s http://localhost:30083`), and
prod from an in-namespace busybox Pod.

**Upgrade by file:** I changed `environments/dev.yaml` to
`Development build v2`. `helm template` predicted the new
`checksum/config: 4e9ac327…`. After the upgrade (revision 2) the checksum
was `4e9ac327…`, a new ReplicaSet `webapp-dev-7f99fdfb58` replaced
`566797f967`, and the page showed v2. **Rollback to 1** (revision 3)
restored checksum `1d50881e…` and ReplicaSet hash `566797f967`, with a new
Pod (`-svsqp`). A curl made immediately after the rollback returned
nothing, during the single-replica Pod swap. Five seconds later, three
curls all returned the v1 page.

**Drift under server-side apply:**

```
$ kubectl scale deployment webapp-prod -n dso202-prod --replicas=5
managedFields: helm Apply | kubectl.exe Update scale | kube-controller-manager Update status
$ helm upgrade webapp-prod ./webapp -f environments/prod.yaml -n dso202-prod --wait
Error: UPGRADE FAILED: ... Apply failed with 1 conflict: conflict with "kubectl.exe" with subresource "scale" using apps/v1: .spec.replicas
spec.replicas=5      (revision 2: failed)
$ helm upgrade ... --force-conflicts
REVISION: 3, spec.replicas=3, managedFields: helm Apply | kube-controller-manager Update status
```

**NodePort clash with automatic rollback:**

```
$ helm upgrade webapp-dev ... --set service.nodePort=30080 --rollback-on-failure --timeout 2m
Error: UPGRADE FAILED: release webapp-dev failed, and has been rolled back due to rollback-on-failure being set:
... spec.ports[0].nodePort: Invalid value: 30080: provided port is already allocated
4  failed    Upgrade "webapp-dev" failed: ...
5  deployed  Rollback to 3
```

The Service stayed on 30083. With `--atomic` and `--dry-run=server`, the
same upgrade printed `Flag --atomic has been deprecated, use
--rollback-on-failure instead` and then **`Release "webapp-dev" has been
upgraded`**, although nothing changed (still revision 5, nodePort 30083).
Helm's server dry run did not detect the port conflict.
`helm template ... | kubectl apply --dry-run=server` did:
`The Service "webapp-dev" is invalid: ... 30080: provided port is already allocated`.

### Stage 7 — Package and clean up (`evidence/stage7-package-cleanup.txt`)

`helm package` produced `webapp-0.1.0.tgz` with ten files: `Chart.yaml`,
`values.yaml`, `values.schema.json`, `.helmignore` and the six template
files. `.gitkeep` was excluded. I saved the final release histories and the
prod manifest (`evidence/final-*`), then uninstalled both releases and
deleted `dso202-dev`, `dso202-prod` and `dso202-helm`. `helm list -A` is
empty again.

## 4. Analysis

The review questions from each section of the notes are answered below.

**3.2.1.1 — The problem Helm solves**

1. `kubectl apply -f` only knows the objects in the files it is given *now*.
   An object deleted from the file is never mentioned again, so nothing
   deletes it. Helm stores the full rendered manifest of every revision in
   the release record. On upgrade it compares the previous manifest with
   the new one and deletes objects that are no longer rendered.
2. A password in a values file can be read in (a) the release record
   Secret, where Stage 1 decoded the user values in plain text with three
   decoding steps, and through `helm get values` by anyone allowed to read
   Secrets in the namespace; and (b) the values file in version control,
   plus shell history and CI logs if it was passed with `--set`.
3. Kustomize fits when a team owns plain manifests and needs small
   per-environment differences without a templating language
   (Practical 5). Helm fits when an application must be distributed as a
   versioned package that others install, configure through a documented
   values interface, upgrade and roll back as one unit, as podinfo was.

**3.2.1.2 — Architecture**

1. `sh.helm.release.v1.payments.v7`, a Secret in the namespace `finance`.
   This follows the pattern observed in Stage 1:
   `sh.helm.release.v1.my-podinfo.v1` in `dso202-helm`.
2. Tiller was a long-running in-cluster server, usually given
   cluster-admin rights, that any client able to reach it could drive. Each
   user's actions therefore ran with Tiller's permissions. Since Helm 3,
   the client talks to the API server directly with the user's own
   kubeconfig, so RBAC limits each person to their own permissions.
3. The release record is a Secret in the release's own namespace, so
   release names only have to be unique per namespace. `helm list -A`
   lists both.

**Stage 1**

1. `b` is lost and reverts to the chart default, exactly as `replicaCount`
   fell from 2 to 1 in Step 9. `--reuse-values`, or
   `--reset-then-reuse-values` when the chart version also changes, would
   have kept it.
2. History is append-only. A rollback re-applies revision 1's chart and
   values as a *new* revision, so the record shows what happened in order
   (`4 deployed Rollback to 1`).
3. An OCI registry reuses the registry, credentials and access control the
   organisation already runs for images, and charts are addressed by an
   immutable digest (`sha256:ff3d3e14…` was printed on pull). There is
   also no `index.yaml` to download and keep fresh with `helm repo update`.

**Stage 2**

1. `version` must change, because a chart file changed: 1.4.2 → 1.4.3.
   `appVersion` stays the same, because the application did not change.
2. Files whose names begin with `_` are not rendered as manifests.
   `_helpers.tpl` contains only `define` blocks, which produce no output
   until another template calls them with `include`.
3. `-0` lets pre-release Kubernetes versions satisfy the constraint, such
   as `v1.31.0-rc.1` or vendor builds with suffixes. Without it, SemVer
   treats `1.30.0-x` as lower than `1.30.0`, and the chart would refuse to
   install.

**3.2.2.1 — Template language**

1. `{{ .Values.name | upper | quote }}`.
2. Inside `range`, the dot is rebound to the current list element, so
   `.Release` refers to a field of a host string, which does not exist.
   Use `$.Release.Name`: `$` always refers to the root context.
3. `include` returns a string that can be piped, for example to
   `nindent`, so the label block can be indented correctly at each call
   site. `template` writes its output directly and cannot be piped. Stage
   5's Failure 2 shows what wrong indentation of a multi-line block does.

**Stage 4 — Values**

1. `a = 1`. `--set` always overrides every `-f` file, whatever the order on
   the command line.
2. Maps merge deeply. `dev.yaml` sets `service.type: NodePort` and
   `nodePort`, and `prod.yaml` never mentions `service`, so the dev values
   survive. This was observed: `type: NodePort` and `nodePort: 30083` in a
   render labelled prod.
3. `1.30`. `--set image.tag=1.30` keeps the string `"1.30"`, while YAML
   reads `tag: 1.30` as the number 1.3. This was observed as
   `image: "nginx:1.3"`.

**Stage 5 — Validation**

1. `helm lint` reports a failed `required` only as a warning, even with
   `--strict`, and exits 0 (observed). It checks chart structure, not
   whether the chart renders for real values.
2. `"service": { "properties": { "port": { "enum": [80, 8080] } } }`.
3. `helm template` only renders text and checks that it is valid YAML. It
   has no Kubernetes schemas. `replica: 1` is valid YAML; only the API
   server's strict field validation knows that a Deployment has no such
   field.

**Beyond the notes: Helm's dry run is not the API server's.** The notes'
table shows `helm install --dry-run=server` missing an unknown field. This
run found that it also misses a NodePort allocation conflict, while
`helm template | kubectl apply --dry-run=server` caught both. So the
pipeline check that actually reaches the API server's validation and
admission is the kubectl one. A CI stage built only on Helm's dry run would
pass both defects.

**Rollback and Git.** After the Stage 6 rollback, the cluster ran the v1
message while `environments/dev.yaml` in Git still said v2. A rollback
restores the release, not the source of truth. The next
`helm upgrade -f environments/dev.yaml` would quietly bring v2 back. In a
GitOps flow (Practical 4), the rollback should be a `git revert` of the
values change instead.

## 5. Reflection

**The error met, and how it was diagnosed.** The first podinfo install
failed after 10 min 33 s with `Progress deadline exceeded`, even though I
had given `--timeout 15m`. I first assumed the timeout had been ignored. I
checked three things:

- `kubectl get deploy my-podinfo -o jsonpath='{...conditions...}
  progressDeadlineSeconds=...'` printed `progressDeadlineSeconds=600`.
- `kubectl get events | grep -i pull` showed `Successfully pulled image
  ... in 10m5.458s ... Image size: 34763248 bytes`.
- One Pod was `Running` while the other was still `ContainerCreating`.

The pieces fit together. The 35 MB image took longer than the
Deployment's own 600-second progress deadline. The Deployment controller
then reported that the rollout had stalled, and Helm 4's default `watcher`
wait (kstatus) treats that condition as a definitive failure, so it gave
up before reaching my `--timeout`. `--timeout` only caps Helm's waiting; it
does not extend the deadline Kubernetes applies to the Deployment. Once the
image had downloaded, I uninstalled the `failed` release and reinstalled
it, which took 12 s. This kept the revision numbers aligned with the
notes.

**Other things that went wrong.**

- The type-conversion failure in Stage 4 left a **partial release**: the
  ConfigMap and the Service existed with no Deployment, and the release was
  marked `failed`. Helm applies objects in kind order, and nothing is
  undone without `--rollback-on-failure`.
- `kubectl apply --dry-run=server` for prod first failed with
  `namespaces "dso202-prod" not found`. This is the same first-deployment
  trap as Practical 5's `kubectl diff -k`. Even so, the misspelled field in
  Failure 4 was still reported, because the API server decodes the object
  strictly before it looks up the namespace.

**What I would do differently.**

- Pre-pull large chart images, or raise `progressDeadlineSeconds` for first
  installs on a slow link.
- Use `--rollback-on-failure` on every install and upgrade, so that a
  failure never leaves a partial release.
- Set the kubeconfig context namespace back to `default` after each
  practical, because a stale `HELM_NAMESPACE` is an easy way to install
  into the wrong namespace.

**One thing that remains unclear.** The notes say `--dry-run=server`
"renders against the live cluster". In this run it accepted both an
unknown field and an allocated NodePort, so it apparently does not send
the rendered objects to the API server as dry-run requests. I have not yet
found in the Helm 4 documentation exactly which server-side checks it does
perform beyond enabling `lookup` and real `.Capabilities`.

## 6. References

- *Unit III 3.2 — Helm* (HackMD), course-provided notes (sections 3.2.0–3.2.3.2) — accessed 2026-11-07
- *DSO202 Module Descriptor (resequenced)*, `Module_Descriptor_Resequenced.docx` — accessed 2026-11-07
- `helm show chart|values podinfo/podinfo --version 6.15.0`, and the podinfo OCI artifact `oci://ghcr.io/stefanprodan/charts/podinfo` — 2026-11-07
- Helm v4.3.1 command output (`helm version`, `helm env`, `helm lint`, `helm template`, error messages) — 2026-11-07
- Kubernetes API server error messages (strict decoding, NodePort allocation, server-side apply conflicts) from the v1.36.1 cluster — 2026-11-07

## 7. Assessment Mapping (Module Descriptor)

Assessed under *A. Practical Work & Report* of the DSO202 module descriptor
(`Module_Descriptor_Resequenced.docx`): practical report out of 5, practical
work out of 15.

### Practical Report (5 marks)

| Criterion (descriptor) | Marks | Where it is evidenced |
|---|---|---|
| Documentation | 2 | §1 Objective with descriptor sections; §2 Environment (Helm version, pinned chart versions, deviations); §3 one subsection per stage with real output and what it shows; §6 References |
| Reflection | 2 | §5: a named failure (`Progress deadline exceeded`), the diagnostic commands (Deployment conditions, pull events, Pod status) and the reasoning from them; two further problems; what would be done differently; an open question |
| Clarity & Coherence | 1 | §4 answers every review question in the notes (21), each tied to observed output, plus two findings beyond the notes |

### Practical Work (15 marks)

| Criterion (descriptor) | Marks | Where it is evidenced |
|---|---|---|
| Code Organisation & Readability | 3 | Lab layout from the notes (`environments/` outside the chart, `webapp/` with standard chart structure); helpers for names and the two label sets; README with structure, deviations, rebuild and cleanup |
| Code Comments | 2 | Commented `Chart.yaml` and `values.yaml` (every key); header comments in every template; `_helpers.tpl` explains each helper; environment files explain the NodePort choice |
| Functional/Configuration Requirements | 10 | Published chart lifecycle (`stage1`); chart rendering and checksum (`stage3`); values precedence (`stage4`); four validation failures plus schema (`stage5`); dev/prod releases, `helm test`, upgrade/rollback, SSA conflict, rollback-on-failure (`stage6`); packaged chart (`stage7`) |
