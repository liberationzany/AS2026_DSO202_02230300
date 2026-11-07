# DSO202 — Practical 2 Report

Implement persistent storage for a stateful application in Kubernetes.

## 1. Objective

Practical 1 ran stateless nginx Pods. Deleting a Pod lost nothing, because
there was nothing to lose. This practical asks what happens when the data
matters. It builds the storage layer step by step:

- a volume described by hand (static provisioning)
- a volume created on demand (dynamic provisioning)
- a deliberately broken attempt to give a Deployment state
- a StatefulSet that gives each replica a fixed name, its own volume and its own DNS record
- a PostgreSQL database whose rows survive the deletion of its Pod

The cleanup at the end is part of the lesson. It shows which objects the
reclaim policies keep and which they destroy.

Descriptor sections covered: Unit I 1.2.1 (Pods), 1.2.4–1.2.5 (Services,
Secrets), 1.3.3 (DNS), 1.4.1 (Volumes/PVs), 1.4.2 (PVCs), 1.4.3
(StorageClasses), 1.5.1 (Namespaces), 1.5.3 (ResourceQuota/LimitRange);
Unit II 2.1.1–2.1.4 (StatefulSets, stable identity, headless Services,
ordered updates).

## 2. Environment

| Item | Value |
|---|---|
| Operating system | Windows 11, build 10.0.26300; commands run from Git Bash |
| Docker | Docker Desktop 29.4.0, WSL 2 backend, 8 CPUs, 7.7 GiB |
| kind | v0.32.0 go1.26.5 windows/amd64 |
| kubectl | Client v1.36.3 (Kustomize v5.8.1) |
| Cluster Kubernetes version | v1.36.1 on all three nodes, containerd 2.3.1 |
| PostgreSQL image | `postgres:18-alpine`, which reported **PostgreSQL 18.6** |
| Other images | `busybox:1.37`, `nginx:1.30-alpine`, `nginx:1.31-alpine` |

Source: `evidence/stage0-prereqs.txt` and `evidence/stage1-cluster.txt`.

**Changes from the guide:** the host directory was
`C:/Users/zeroe/dso202-p2-storage` instead of `/tmp/dso202-p2-storage`,
because Windows does not have the WSL `/tmp`. Listing 1 (not the fallback)
was used, and the node-name patches applied successfully.

## 3. Procedure and Observations

### Stage 0 — Prerequisites

All three tools reported the expected versions, and the host directory
was created before the cluster. Two clusters from earlier work (`dso202`
and `kind`) were still running. The guide says to delete the Practical 1
cluster; I stopped its containers instead, because it still held the
Assignment 1 deployment.

```
$ kind version
kind v0.32.0 go1.26.5 windows/amd64
$ kubectl version --client
Client Version: v1.36.3
```

The output shows that the toolchain matches the guide's minimum versions.

### Stage 1 — Cluster, namespace, and the storage landscape

```
$ kubectl get nodes -L dso202/node-index
NAME            STATUS   ROLES           AGE   VERSION   NODE-INDEX
control-plane   Ready    control-plane   49s   v1.36.1
worker-node-1   Ready    <none>          37s   v1.36.1   1
worker-node-2   Ready    <none>          37s   v1.36.1   2

$ docker exec dso202-p2-worker ls -ld /mnt/dso202-static
drwxrwxrwx 1 root root 512 Nov  7 14:24 /mnt/dso202-static

$ kubectl get storageclass
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
dso202-retain        rancher.io/local-path   Retain          WaitForFirstConsumer   false
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   false
```

The provisioner Pod `local-path-provisioner-855c7b7774-f7bvh` runs in
`local-path-storage`. Its ConfigMap says every dynamic volume is a
directory under `/var/local-path-provisioner` on the node. The quota
showed all nine limits at zero, including the three storage limits.

The output shows that the custom node names and labels applied, that
the Windows directory reached only `worker-node-1`, and that both classes
use the same provisioner and differ only in reclaim policy.

### Stage 2 — Static provisioning and the meaning of Retain

The PV started `Available`. The claim bound to it at once, even though no
StorageClass named `manual` exists:

```
$ kubectl get storageclass manual
Error from server (NotFound): storageclasses.storage.k8s.io "manual" not found
$ kubectl get pod static-writer -o wide
NAME            READY   STATUS    ...   NODE
static-writer   1/1     Running   ...   worker-node-1
```

No nodeSelector was written, yet the Pod landed on `worker-node-1`. The
PV's `nodeAffinity` (`dso202/node-index In [1]`) placed it there. The same
line was readable inside the container and directly on the Windows host.
I then deleted the Pod and the claim:

```
$ kubectl get pv
NAME            ...  RECLAIM POLICY   STATUS     CLAIM
pv-web-static   ...  Retain           Released   dso202-practical-02/pvc-web-static
$ kubectl delete pv pv-web-static
$ ls -l /c/Users/zeroe/dso202-p2-storage/pv-web-static/
-rw-r--r-- 1 zeroe 197609 128 Nov  7 20:28 ledger.txt
```

After recreating all three objects, the ledger held three lines:

```
2026-11-07T14:28:47Z start pod=static-writer node=worker-node-1
2026-11-07T14:28:55Z start pod=static-writer node=worker-node-1
2026-11-07T14:29:24Z start pod=static-writer node=worker-node-1
```

The output shows that deleting the claim and the PV object removed API
entries but not one byte of data. A new PV, claim and Pod picked up data
written before any of them existed.

### Stage 3 — Dynamic provisioning and two uncomfortable truths

```
$ kubectl describe pvc dynamic-data | tail -n 6
  Normal  WaitForFirstConsumer  ...  persistentvolume-controller  waiting for first consumer to be created before binding
```

Once `dynamic-writer` existed, the claim became `Bound` to
`pvc-54563f4e-7d76-40a6-9064-5013765a6f7a`, with reclaim policy `Delete`.
That volume was created automatically, and its directory appeared on
`dso202-p2-worker` as
`pvc-54563f4e-..._dso202-practical-02_dynamic-data`.

```
$ kubectl exec dynamic-writer -- df -h /data
Filesystem                Size      Used Available Use% Mounted on
/dev/sde               1006.9G     33.2G    922.5G   3% /data

$ kubectl patch pvc dynamic-data --type merge -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
Error from server (Forbidden): persistentvolumeclaims "dynamic-data" is forbidden: only dynamically provisioned pvc can be resized and the storageclass that provisions the pvc must support resize
```

After deleting the Pod and the claim, `kubectl get pv` listed only the
static PV, and `ls /var/local-path-provisioner` on the node printed nothing.

The output shows three things. Binding waited for a consumer. The "1Gi"
claim could see the whole 1 TB WSL disk. And the class, not the claim,
decided both expansion (refused) and reclamation (deleted).

### Stage 4 — Why a Deployment cannot own state

This stage is a **deliberate failure**, not a success.

```
$ kubectl get pods -l app=shared-writer -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName
shared-writer-6f4b987c7b-28znw   worker-node-1
shared-writer-6f4b987c7b-b2cw6   worker-node-1
shared-writer-6f4b987c7b-qm7fc   worker-node-1

$ kubectl exec deploy/shared-writer -- cat /data/visitors.log
2026-11-07T14:30:09Z pod=shared-writer-6f4b987c7b-qm7fc node=worker-node-1
2026-11-07T14:30:09Z pod=shared-writer-6f4b987c7b-b2cw6 node=worker-node-1
2026-11-07T14:30:09Z pod=shared-writer-6f4b987c7b-28znw node=worker-node-1
```

After all three Pods were deleted, the replacements were `-d9zsf`,
`-j7zws` and `-pxcgj`. Every name was new, and all three appended to the
same file.

- **Observation 1:** the volume dictated placement. All three replicas were
  forced onto `worker-node-1`, because the one claim's volume lives there.
- **Observation 2:** there was one set of data, not three. Three processes
  wrote into one file with no owner. A database in this position would
  corrupt its data files.
- **Observation 3:** no replica kept an identity across a restart, so
  nothing could reliably refer to "replica 1".

The configuration "worked" only because `ReadWriteOnce` allows several
Pods on one node. On a cloud cluster with a network disk, replicas
scheduled to other nodes would fail with a multi-attach error.

### Stage 5 — StatefulSets and stable identity

The headless Service showed `CLUSTER-IP None`. The watch captured strict
ordering: `webnote-1` entered `Pending` only after `webnote-0` reached
`1/1 Running`. Three claims were created from one template:

```
content-webnote-0   Bound   pvc-4c9177fa-...   1Gi   RWO   standard
content-webnote-1   Bound   pvc-fadb1b48-...   1Gi   RWO   standard
content-webnote-2   Bound   pvc-9137ccac-...   1Gi   RWO   standard
```

The Pods spread across nodes (`webnote-0` on worker-node-1, `-1` and `-2`
on worker-node-2), unlike Stage 4. DNS resolved both forms:

```
$ kubectl exec client -- nslookup webnote.dso202-practical-02.svc.cluster.local
Address: 10.244.1.5
Address: 10.244.1.3
Address: 10.244.2.17
$ kubectl exec client -- nslookup webnote-1.webnote.dso202-practical-02.svc.cluster.local
Name:	webnote-1.webnote.dso202-practical-02.svc.cluster.local
Address: 10.244.1.3
```

A note written into `webnote-0` only did not appear in `webnote-1`'s page,
which shows the volumes are private. I then deleted `webnote-1`:

```
webnote-1   worker-node-2   10.244.1.6          # was 10.244.1.3
content-webnote-1   Bound   pvc-fadb1b48-...    # same volume, AGE 2m8s > Pod age
<h2>webnote-1</h2>
created: 2026-11-07T14:32:01Z on worker-node-2  # unchanged
started: 2026-11-07T14:32:01Z on worker-node-2
started: 2026-11-07T14:33:38Z on worker-node-2  # appended by the replacement
```

The output shows all four guarantees: the same name, the same claim, the
same data, and a new IP. The new IP is why applications must use the DNS
name.

### Stage 6 — Scaling, retention, and ordered updates

Scaling to 4 created `content-webnote-3`, and the quota tracked it
(`standard ... requests.storage 4Gi / 12Gi`). Scaling to 2 terminated
`webnote-3` first, then `webnote-2`, in descending order. All four claims
remained. Scaling back to 3 brought back `webnote-2` with its original
`created: 2026-11-07T14:33:17Z` line, so ordinal 2 reclaimed its own
volume by name.

For the partitioned update, I edited the committed manifest
(`partition: 2`, image `nginx:1.31-alpine`) and applied it:

```
NAME        IMAGE
webnote-0   nginx:1.30-alpine
webnote-1   nginx:1.30-alpine
webnote-2   nginx:1.31-alpine
```

Setting `partition: 0` completed the rollout, and all three Pods ran
`nginx:1.31-alpine`. `webnote-0` still showed its original `created:` line
and the hand-written Stage 5 note. Deleting the StatefulSet removed every
Pod but left 4 claims. Re-applying it brought back `webnote-1` with its
full history (one `created:` line and four `started:` lines).

`kubectl explain statefulset.spec.updateStrategy.rollingUpdate` confirms
that on v1.36.1 `maxUnavailable` is beta and enabled by default. The
description also notes it "might not be effective for the OrderedReady
podManagementPolicy".

### Stage 7 — A real stateful application: PostgreSQL

The Secret's value was recovered with one command
(`... | base64 -d` → `taskuser`). This shows a Secret is encoded, not
encrypted. Two Services were created: `postgres` (ClusterIP
10.96.204.228) and `postgres-headless` (None). The data claim used
`dso202-retain`, and its PV showed `RECLAIM POLICY Retain`. `$PGDATA` was
`/var/lib/postgresql/18/docker`, one level below the mount point.

```
$ kubectl exec postgres-0 -- psql ... -c "SELECT id, title, done FROM tasks ORDER BY id;"
  1 | Complete Practical 2 | f
  2 | Read Unit II notes   | f
  3 | Draft the report     | f
$ kubectl delete pod postgres-0
$ kubectl exec postgres-0 -- psql -U taskuser -d tasktracker -c "SELECT count(*) FROM tasks;"
 count
-------
     3
$ kubectl logs postgres-0 | head
PostgreSQL Database directory appears to contain a database; Skipping initialization
... LOG:  database system was shut down at 2026-11-07 14:43:40 UTC
... LOG:  database system is ready to accept connections
```

The claim `data-postgres-0` kept the same volume
(`pvc-ed0f35ee-...`) across the Pod deletion. Both
`postgres.dso202-practical-02.svc.cluster.local` (10.96.204.228, the
Service IP) and `postgres-0.postgres-headless...` (10.244.2.25, the Pod
IP) resolved. The output shows that rows written by one process were read
through a replacement Pod. The clean "shut down" line, with no recovery,
shows that the 60-second grace period allowed an orderly stop.

### Stage 8 — Cleanup, and the cost of Retain

Before deleting anything, `kubectl diff` against the live manifests
reported no differences. I then captured `evidence/final-state-*.txt` and
a 99-line `evidence/tasktracker-dump.sql`. After the workloads were
deleted, six claims remained. After `kubectl delete pvc --all`:

```
NAME                                       RECLAIM POLICY   STATUS     CLAIM
pv-web-static                              Retain           Released   dso202-practical-02/pvc-web-static
pvc-ed0f35ee-ced9-4523-8f1f-e517b8293790   Retain           Released   dso202-practical-02/data-postgres-0
$ docker exec dso202-p2-worker ls /var/local-path-provisioner
pvc-ed0f35ee-ced9-4523-8f1f-e517b8293790_dso202-practical-02_data-postgres-0
```

The four `standard` volumes disappeared, along with their node
directories. The two `Retain` volumes stayed `Released` with their data.
After `kind delete cluster --name dso202-p2`, the static ledger was still
on the Windows host with all three lines. The database directory was
gone, because it had lived inside a node container.

The output shows that a PersistentVolume describes storage; it is not the
storage itself. It also shows that a retained volume is not a backup,
because the cluster's deletion destroyed it. Only the SQL dump outside
the cluster survived.

## 4. Analysis

**1. Why was the Stage 3 claim Pending when the Stage 2 claim bound at once?**
The field is `volumeBindingMode` on the StorageClass. `standard` uses
`WaitForFirstConsumer`, so the controller waits until a Pod using the
claim is scheduled. Only then does it know which node the volume must be
on (event: "waiting for first consumer to be created before binding").
The Stage 2 claim named class `manual`, which has no StorageClass object
(`NotFound`). With no class, no binding mode applies, and an `Available`
PV that matches is bound immediately. Delaying binding prevents a
node-local or zonal volume from being created somewhere the Pod can never
run.

**2. Which object decided whether the data survived?**
The reclaim policy decided it. For the static volume it is
`persistentVolumeReclaimPolicy: Retain` on the PersistentVolume, which an
administrator writes. For the dynamic volume, the PV inherits
`reclaimPolicy` from the StorageClass (`standard` → `Delete`). The claim
has no say, as the `Delete` in `kubectl get pv` for
`pvc-54563f4e-...` shows. In a real organisation, a platform or cluster
administrator defines StorageClasses, so they choose this, not the
developer who writes the claim.

**3. Why were all Stage 4 replicas on one node?**
The single claim `shared-data` was bound to a local-path volume created
on `worker-node-1`. That volume carries node affinity for that node, so
the scheduler could place a Pod that mounts it only there. `ReadWriteOnce`
restricts a volume to one *node*, not one Pod, so all three mounted it
together. On a managed cloud cluster with a zonal block disk, the disk
attaches to one node. Replicas scheduled elsewhere would stay in
`ContainerCreating` with a `Multi-Attach error`, or be unschedulable
outside the disk's zone.

**4. What is the second replica's fully qualified name, and what must exist for it to resolve?**
The name is `webnote-1.webnote.dso202-practical-02.svc.cluster.local`.
These must exist: the namespace `dso202-practical-02`; the headless
Service `webnote` (`clusterIP: None`, selecting `app: webnote`); the
StatefulSet with `serviceName: webnote`; the Pod `webnote-1` in a Ready
state (because `publishNotReadyAddresses: false`); the EndpointSlice the
control plane derives for the Service; and cluster DNS (CoreDNS) to
answer the query.

**5. What happened to the claims at each scaling step?**
At 3 → 4, a new claim `content-webnote-3` was created from the template.
At 4 → 2, `webnote-3` and then `webnote-2` were terminated, but all four
claims stayed `Bound`. At 2 → 3, `webnote-2` returned and re-attached
`content-webnote-2` by name, with its original `created:` line, while
`content-webnote-3` stayed unused. Two fields govern this:
`persistentVolumeClaimRetentionPolicy.whenScaled` and `.whenDeleted`.
Both default to `Retain`.

**6. Why does Listing 16 mount at `/var/lib/postgresql`?**
From PostgreSQL 18, the image's data directory is
`/var/lib/postgresql/18/docker` (confirmed: `$PGDATA` printed that path),
and `/var/lib/postgresql` is the declared volume location. Mounting at the
parent leaves the data directory as a fresh, empty subdirectory that
`initdb` creates itself. If a volume that already holds entries (such as a
`lost+found` from the filesystem) were mounted directly at the data
directory, `initdb` would refuse with a "directory exists but is not
empty" error. The container would then go into `CrashLoopBackOff` on first
start.

**7. What two things does a StatefulSet not provide for a database?**
(a) **Replication and failover.** A second replica of Listing 16 is a
second, independent, empty database. Configuring primaries and replicas,
and promoting one on failure, is done by a database **Operator**
(CloudNativePG, Zalando, Crunchy) under Unit II 2.4. (b) **Backups.** A
retained volume died with the cluster in Stage 8. Logical or physical
backups stored outside the cluster come from backup tooling such as
`pg_dump` in a CronJob, the Operator's backup feature, or **Velero** and
CSI **VolumeSnapshots**.

**8. Why were the two volumes Released and not Available?**
With `Retain`, the PV keeps its `claimRef` to the deleted claim (the
CLAIM column still read `dso202-practical-02/data-postgres-0`).
Kubernetes will not give a volume that may hold one workload's data to
whichever claim comes next. To return it to service, an administrator
must clean or archive the data, then either delete and recreate the PV,
or remove `spec.claimRef` (for example,
`kubectl patch pv <name> --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'`)
so it becomes `Available` again.

## 5. Reflection

**What was difficult.** The hardest part was not a Kubernetes concept
but turning the guide into working files. The PDF copy of the companion
file cuts off long lines at the page edge, and several of them are the
important ones. These include the node image digest, the `echo ... >>`
redirections in every writer Pod, and the `index.html` lines of the
webnote init container. I rebuilt each one from the guide's expected
output. For example, the guide's Stage 2 output reads `... start
pod=static-writer node=worker-node-1` from `/data/ledger.txt`, which fixes
both the missing variable (`${NODE_NAME}`) and the target file. I took the
digest from Practical 1's cluster file, which uses the same image. A wrong
reconstruction would have failed silently, for example by writing to the
wrong file, so I checked each one against the stage output when it ran.

**An error met, and how it was diagnosed.** In Stage 5, the guide shows
`nslookup webnote...` returning three addresses, each labelled with its Pod
name. My output gave the three addresses with no per-Pod names. My first
thought was that the headless Service was misconfigured. I checked with
`kubectl get endpointslice -l kubernetes.io/service-name=webnote`, which
listed exactly the three Pod IPs, and with a direct
`nslookup webnote-1.webnote.dso202-practical-02.svc.cluster.local`, which
resolved to `10.244.1.3`, matching `kubectl get pods -o wide`. So DNS was
correct. The difference is in how `busybox:1.37`'s `nslookup` formats the
answer for the set name. The per-Pod records exist and resolve. A second,
smaller surprise: Pods on `worker-node-1` received `10.244.2.x` addresses,
not `10.244.1.x` as in the guide. kind gives each node its Pod CIDR in
join order, so the CIDR does not follow the node's name.

**Environment issues.** The first pulls of `nginx:1.30-alpine` and
`postgres:18-alpine` were slow, about 40 seconds for nginx and nearly 5
minutes for PostgreSQL. A `kubectl get pods -w` that I had limited in time
ended before `postgres-0` became Ready. `kubectl wait
--for=condition=Ready` then confirmed readiness rather than the watch.
Running from Git Bash also needed `MSYS_NO_PATHCONV=1`. Without it, Git
Bash rewrites container paths such as `/data/ledger.txt` into Windows
paths before `kubectl` sees them.

**What I would do differently.** I would pre-pull the four images into
the nodes (`kind load docker-image`) before Stage 1, so that readiness
timings measure the probes rather than the network. I would also capture
the `-w` watches with `kubectl wait` plus a final `get`, rather than
relying on a timeout.

**One thing that remains unclear.** `kubectl explain` says
`maxUnavailable` "might not be effective for the OrderedReady
podManagementPolicy", but not whether it is ignored completely or only
partly. I would need to test it on a StatefulSet with `Parallel`
management to find out how the two interact.

Extensions 1–4 were not attempted in this run.

## 6. References

- *DSO202 — Practical 2 Guide* (`DSO202_Practical2_Guide.md`, HackMD), course-provided — accessed 2026-11-07
- *DSO202 — Practical 2 Companion File: YAML Definitions* (`DSO202_Practical2_Manifests.md`, HackMD), course-provided — accessed 2026-11-07
- *DSO202 Module Descriptor (resequenced)*, `Module_Descriptor_Resequenced.docx` — assessment criteria, accessed 2026-11-07
- `kubectl explain statefulset.spec.updateStrategy.rollingUpdate`, read from the v1.36.1 API server — 2026-11-07
- PostgreSQL container log messages from `postgres:18-alpine` (18.6), read with `kubectl logs` — 2026-11-07

## 7. Assessment Mapping (Module Descriptor)

Assessed under *A. Practical Work & Report* of the DSO202 module descriptor
(`Module_Descriptor_Resequenced.docx`): practical report out of 5, practical
work out of 15.

### Practical Report (5 marks)

| Criterion (descriptor) | Marks | Where it is evidenced |
|---|---|---|
| Documentation | 2 | §1 Objective with descriptor sections; §2 Environment (all tool versions and the PostgreSQL tag); §3 one subsection per stage, each with real command output and a sentence on what it shows; §6 References with access dates |
| Reflection | 2 | §5: a named discrepancy (busybox `nslookup` output), the commands used to diagnose it (`get endpointslice`, per-Pod `nslookup`, `get pods -o wide`), what would be done differently, and one open question |
| Clarity & Coherence | 1 | §4 answers all eight review questions, each citing the stage output it relies on; Stage 4 is presented as a failure, as the guide requires |

### Practical Work (15 marks)

| Criterion (descriptor) | Marks | Where it is evidenced |
|---|---|---|
| Code Organisation & Readability | 3 | Repository structure as in guide §4; numbered manifests `00-` … `14-`; the four-key label scheme on every object and claim template; explicit `namespace:` on every namespaced object and none on the StorageClass or PV; README that rebuilds the practical without the guide |
| Code Comments | 2 | Companion-file comment blocks kept in all 15 manifests and both cluster files; amended comments where values changed (Windows host path in Listing 1, image tag and partition history in Listing 12) |
| Functional/Configuration Requirements | 10 | `evidence/stage2-static.txt` (three-line ledger, `Released`); `stage3-dynamic.txt` (WaitForFirstConsumer, `df -h`, resize rejection); `stage4-deployment-antipattern.txt` (one node, one log, new names); `stage5-statefulset.txt` (ordered creation, three claims, DNS, private content, identity after deletion); `stage6-scaling-updates.txt` (descending termination, retained claims, returning `created:`, partitioned rollout); `stage7-postgres.txt` (`count` = 3 after Pod deletion, both Service names resolve); `stage8-cleanup.txt` (four volumes gone, two `Released`, cluster deleted); `tasktracker-dump.sql` |
