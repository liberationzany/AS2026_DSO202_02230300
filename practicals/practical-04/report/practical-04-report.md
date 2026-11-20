# DSO202 — Practical 4 Report

Set up Argo CD and implement GitOps-based deployment for a sample application.

## 1. Objective

In earlier practicals I changed the cluster myself with `kubectl apply`.
This practical moves that job to a controller. Argo CD runs inside the
cluster, reads the desired state from a GitHub repository, and keeps the
cluster equal to it.

The aim was to prove three things by observation:

- a Git commit is enough to change a running workload;
- a manual change made behind Git's back does not survive;
- deleting a file from Git deletes the object it described.

The guide's Modules 1–3 cover the theory: push-based versus pull-based
delivery, the four OpenGitOps principles, the Argo CD components, and the
sync and health statuses. Modules 4–5 are the hands-on part reported here.

Descriptor coverage: Unit IV (ArgoCD and GitOps-based continuous deployment),
building on Unit II 2.4. Argo CD is itself a controller, installed with CRDs
(`Application`, `AppProject`, `ApplicationSet`).

## 2. Environment

| Item | Value |
|---|---|
| Operating system | Windows 11, build 10.0.26300; commands from Git Bash |
| Docker | Docker Desktop 29.4.0, WSL 2 backend |
| kind | v0.32.0 |
| kubectl | client v1.36.3 |
| Cluster | existing `dso202` cluster from Practical 1: `control-plane`, `worker-node-1`, `worker-node-2`, Kubernetes v1.36.1 |
| Argo CD | v3.6.1 (from the `stable` install manifest) |
| Git remote | `https://github.com/liberationzany/AS2026_DSO202_02230300.git` (public), branch `main` |
| Demo image | `nginxdemos/hello:plain-text` |

**Deviations from the guide**, each deliberate:

- **Repository:** I used this coursework repository instead of a new
  `k8s-gitops-demo` repository. The Application's `path` is restricted to
  `practicals/practical-04/gitops/manifests`.
- **`targetRevision`:** set to `main` instead of `HEAD`, so the tracked
  branch is explicit.
- **Install command:** run with `--server-side`.
- **Refresh:** triggered with the `argocd.argoproj.io/refresh` annotation
  instead of the UI button.
- **Cleanup:** the guide's final cluster deletion was skipped, because the
  cluster is shared with earlier work.

## 3. Procedure and Observations

### Step 1 — Cluster

The `dso202` cluster had been stopped (its containers were halted to save
memory during Practical 2). I started it again with `docker start`, and
all three nodes reported `Ready` on v1.36.1. The namespaces from earlier
practicals (`dso202-practical-01`, `dso202-assignment-1`,
`dso202-operators`) were intact.

### Step 2 — Install Argo CD (`evidence/step2-install-argocd.txt`)

```
$ kubectl get crd | grep argoproj
applications.argoproj.io        2026-11-07T14:49:52Z
applicationsets.argoproj.io     2026-11-07T14:49:52Z
appprojects.argoproj.io         2026-11-07T14:49:52Z
$ kubectl -n argocd get deploy argocd-server -o jsonpath='{...image}'
quay.io/argoproj/argocd:v3.6.1
```

The guide expects one to two minutes. Here, the Pods sat in
`ContainerCreating` and `Init:0/1` for about 45 minutes. `kubectl describe`
showed `Pulling image "quay.io/argoproj/argocd:v3.6.1"` and nothing else.
At about 28 minutes, `argocd-server` also showed
`CreateContainerConfigError: secret "argocd-redis" not found`. The final
state was 7/7 Pods `Running` and `Ready`. The output shows that installing
Argo CD only adds CRDs and ordinary Deployments to the cluster: it is a
controller like any other. Diagnosis of the delay is in §5.

### Step 3 — UI access (`evidence/step3-ui-access.txt`)

`kubectl port-forward svc/argocd-server -n argocd 8080:443` exposed the
ClusterIP Service. `https://localhost:8080/` answered `HTTP 200`, and
`/api/version` returned `v3.6.1`. A login as `admin` with the password
from `argocd-initial-admin-secret` (16 characters) returned a session
token. Neither the password nor the token is recorded in the evidence.
The output shows the UI and API are reachable only through the tunnel, as
expected for a ClusterIP Service.

### Step 4 — Register the Application declaratively (`evidence/step4-first-sync.txt`)

The desired state was pushed first, as commit `e99c1c5`. Then:

```
$ kubectl apply -f argocd/argocd-app.yaml
application.argoproj.io/my-webapp created
$ kubectl -n argocd get application my-webapp
NAME        SYNC STATUS   HEALTH STATUS
my-webapp   Synced        Healthy
revision=e99c1c5ee75fc434a70045f2071f5bf9bea8afa9
$ kubectl get pods -n demo-app -o wide
webapp-deploy-749f746dd4-c86fs   1/1   Running   ...   worker-node-2
webapp-deploy-749f746dd4-vbsg5   1/1   Running   ...   worker-node-1
```

The namespace `demo-app` did not exist beforehand.
`CreateNamespace=true` created it. The output shows that one `kubectl
apply`, of the Application, was enough for Argo CD to clone the repository
and create the Deployment, ReplicaSet, two Pods and the Service, at exactly
the commit that was pushed.

### Experiment 1 — Git as the single source of truth (`evidence/exp1-git-source-of-truth.txt`)

```
612aa56 practical-04 exp1: scale webapp from 2 to 4 replicas via Git
-  replicas: 2
+  replicas: 4
   e99c1c5..612aa56  main -> main
```

After the push and a refresh, four Pods were running. Two were new (age
8 s), and the application reported `Synced / Healthy` at revision
`612aa56`. The sync history now lists two entries, one per commit:

```
id=0 revision=e99c1c5...  deployedAt=2026-11-07T15:39:20Z
id=1 revision=612aa56...  deployedAt=2026-11-07T15:40:28Z
```

The output shows that scaling was done by editing a file and pushing.
`kubectl` was used only to read. Every cluster change has a matching
commit hash.

### Experiment 2 — Configuration drift and self-healing (`evidence/exp2-drift-self-heal.txt`)

```
15:40:42 spec.replicas=1 ready=1 app=Synced/Progressing
15:40:44 spec.replicas=4 ready=3 app=Synced/Progressing
15:40:45 spec.replicas=4 ready=4 app=Synced/Healthy
```

The controller log records the correction:

```
2026-11-07T15:40:47Z | Updated sync status: Synced -> OutOfSync
2026-11-07T15:40:47Z | Initiated automated sync to '612aa56f...'
2026-11-07T15:40:47Z | Partial sync operation to 612aa56f... succeeded
2026-11-07T15:40:47Z | Updated sync status: OutOfSync -> Synced
```

The Deployment events show `Scaled down ... from 4 to 1` immediately
followed by `Scaled up ... from 1 to 4`. Three of the four Pods were
replaced (age 23 s); only `-vbsg5` survived. The output shows that
self-heal re-applied the **same** commit. It did not consult the person
who ran `kubectl scale`. The manual change lasted about two seconds.

### Experiment 3 — Automatic pruning (`evidence/exp3-prune.txt`)

```
09f9223 practical-04 exp3: remove webapp Service from Git (prune test)
 .../practical-04/gitops/manifests/service.yaml | 28 -----
$ kubectl get svc -n demo-app
No resources found in demo-app namespace.
2026-11-07T15:41:35Z | Adding resource result, status: 'Pruned', phase: 'Succeeded', message: 'pruned'
```

`git revert HEAD` produced commit `2b494cd`. After the push, the Service
was back:

```
webapp-svc   ClusterIP   10.96.214.137   <none>   80/TCP   0s
$ kubectl run probe ... -- wget -qO- http://webapp-svc
Server address: 10.244.2.11:80
Server name: webapp-deploy-749f746dd4-925b4
```

Argo CD's sync history ends with four entries, matching the four commits
that touched the watched path (`e99c1c5`, `612aa56`, `09f9223`,
`2b494cd`). The output shows that `prune: true` turns a deleted file into
a deleted object, and that a rollback is an ordinary commit.

## 4. Analysis

**Push versus pull, as seen in this run.** At no point did anything
outside the cluster hold credentials to change it. GitHub was only read,
over public HTTPS, and every write to the Kubernetes API came from
`argocd-application-controller` inside the cluster. A CI system that runs
`kubectl apply` would need cluster-admin credentials stored outside the
cluster. Here, the only thing worth stealing from GitHub is the right to
push to `main`, and that is protected by Git's own review and audit tools.

**Sync status and health status are different questions.** During
Experiment 2 the application was briefly `Synced / Progressing`. The
object specs already matched Git again, but the new Pods were not yet
ready. Sync status compares *specs* (Git versus live objects). Health
status checks whether those objects *work*, using readiness and
availability. That is why the Deployment's `readinessProbe` matters to
Argo CD: without it, a Pod is reported healthy as soon as its process
starts.

**Self-heal versus prune.** Both are part of `syncPolicy.automated`, and
they cover different failures:

- `selfHeal` handles a managed object whose live spec differs from Git
  (drift).
- `prune` handles an object that is still live but no longer in Git
  (orphans).

Without `prune`, Experiment 3 would have left `webapp-svc` running and
marked it as requiring pruning. Without `selfHeal`, Experiment 2 would
have shown `OutOfSync` and waited for a person to press Sync.

**Revert is not the same as undo.** The restored Service had a new
ClusterIP: `10.96.214.137`, where it had been `10.96.248.134`. `git revert`
restored the *description*. The object was recreated from it, so any value
assigned at creation time was new. Anything that pinned the old ClusterIP
would have broken. Clients that use the DNS name `webapp-svc` did not
notice. This is the same lesson as the changing Pod IPs in Practical 2.

**Why polling was bypassed.** Argo CD polls Git every three minutes by
default. Each experiment used the `argocd.argoproj.io/refresh=normal`
annotation, the declarative equivalent of the UI's Refresh button, so each
commit was seen within seconds. Production systems use a GitHub webhook
instead.

**One repository versus two.** The guide recommends keeping application
code and configuration in separate repositories. Here they share one, and
I limited the risk by scoping `source.path` to one folder. That prevents
unrelated commits (reports, other practicals) from changing the cluster.
They still trigger a refresh and a comparison, though. The application
history shows only the four commits that touched the watched path, because
Argo CD records syncs, not refreshes. In a real team, the separation would
also separate *who may merge*, which a path filter cannot do.

## 5. Reflection

**What I found difficult.** Installing Argo CD took me about 45 minutes,
not the one or two the guide suggests. My first `kubectl wait
--timeout=420s` and a second 590 s wait both timed out, with every Pod
still in `ContainerCreating` or `Init:0/1`.

**How I worked out the cause.** `kubectl describe pod argocd-server-...`
showed only `Scheduled` and `Pulling image "quay.io/argoproj/argocd:v3.6.1"`
and no error, so I knew it was not a scheduling or configuration problem. I
then tested the registry from inside a node:

```
docker exec dso202-worker curl -w '%{http_code}' https://quay.io/v2/
```

It returned 401 in 1.5 s, so DNS and connectivity were fine. To tell
whether the pull was stuck or just slow, I pulled the same image on my
laptop at the same time. That took **21 min 40 s**, which convinced me the
problem was my download speed, not Kubernetes. Watching containerd's
`ingest` directory on `dso202-worker` grow (58 MB and rising) confirmed the
pull inside the node was still moving.

**An error that misled me.** At one point `argocd-server` showed
`CreateContainerConfigError: secret "argocd-redis" not found`, and I
thought the install was broken. It turned out that this Secret is created
by an init container in the redis Pod, which was itself still waiting for
the same slow image. Once redis started, the error disappeared without me
changing anything. What I took from this is to look at Pods in the order
they depend on each other before deciding which error is the real cause.

**Smaller issues.**

- Self-heal was faster than my one-second polling loop, so the `OutOfSync`
  state never showed up in my loop's output. I could only see it in the
  controller's log.
- My laptop's clock and the node's clock were about 5 seconds apart: my
  loop printed 15:40:42 for the scale, while the controller logged
  15:40:47.

**What I would do differently.** I would pre-pull the three Argo CD images
before the session, or pin a specific Argo CD version instead of `stable`
and load the images with `kind load`. I would also give Argo CD its own
cluster. The guide's cleanup step is `kind delete cluster`, and I could not
run it without also destroying my Practical 1 and Assignment 1 work.

**What I am still unsure about.** The controller log shows
`SelfHealAttemptsCount:1` on the Experiment 1 sync and
`SelfHealAttemptsCount:2` on the Experiment 2 correction. The Experiment 1
sync came from a new commit, not from drift, so I do not understand why the
counter was already counting. I want to check this against the Argo CD
documentation on self-heal backoff.

I did not capture UI screenshots for this practical. Instead, my evidence
uses the CLI equivalent of each view: sync and health status, the resource
tree, the sync history and the controller events.

## 6. References

- *GitOps and Argo CD Lab Guide* (HackMD), course-provided — accessed 2026-11-07
- *DSO202 Module Descriptor (resequenced)*, `Module_Descriptor_Resequenced.docx` — practical list and assessment criteria, accessed 2026-11-07
- Argo CD `stable` install manifest, `https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml` (resolved to v3.6.1) — 2026-11-07
- Argo CD API `/api/version` and `/api/v1/session`, read from the running v3.6.1 server — 2026-11-07
- `argocd-application-controller` logs, read with `kubectl logs` — 2026-11-07

## 7. Assessment Mapping (Module Descriptor)

Assessed under *A. Practical Work & Report* of the DSO202 module descriptor
(`Module_Descriptor_Resequenced.docx`): practical report out of 5, practical
work out of 15.

### Practical Report (5 marks)

| Criterion (descriptor) | Marks | Where it is evidenced |
|---|---|---|
| Documentation | 2 | §1 Objective; §2 Environment with every version and each deviation stated; §3 one subsection per step, each with real output and what it shows; §6 References |
| Reflection | 2 | §5: a named problem (45-minute install), the exact diagnostic commands (`describe pod`, in-node `curl`, host `docker pull` timing, containerd ingest size), a misleading secondary error explained, what would be done differently, and one open question |
| Clarity & Coherence | 1 | §4 ties each observation to a GitOps concept (pull model, sync vs health, self-heal vs prune, revert vs undo) |

### Practical Work (15 marks)

| Criterion (descriptor) | Marks | Where it is evidenced |
|---|---|---|
| Code Organisation & Readability | 3 | Watched desired state (`gitops/manifests/`) separated from the Application CR (`argocd/`); consistent `app` / `dso202/*` labels; README with structure, commit-to-sync table, rebuild and cleanup |
| Code Comments | 2 | Header and per-field comments in `deployment.yaml`, `service.yaml` and `argocd-app.yaml` (why each sync option is set, why the app file is outside the synced path) |
| Functional/Configuration Requirements | 10 | Argo CD installed and reachable (`step2`, `step3`); Application `Synced/Healthy` from Git (`step4`); scale via commit (`exp1`); drift corrected by self-heal (`exp2`); prune and revert (`exp3`); final state (`final-*`) |
