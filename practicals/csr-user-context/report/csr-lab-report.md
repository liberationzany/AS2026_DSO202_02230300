# DSO202 — CSR Lab Report

Creating a Kubernetes "user" and context with an x509 client certificate
and RBAC (*Create_CSR*, Unit II).

## 1. Objective

Kubernetes authenticates requests but stores no users. My aim was to show
the two halves of "adding a user" separately, and in that order:

- **Authentication.** A certificate signed by the cluster CA makes the API
  server accept `saroj` (groups `dev-team`, `system:authenticated`) as an
  identity.
- **Authorization.** Until an RBAC binding names that identity, every
  request is Forbidden. After the binding, the identity can do exactly what
  the Role lists, in one namespace, and nothing else.

Beyond the notes' eight steps, I tested the claims in the notes' warnings
directly:

- binding by group;
- what the signer does with bad requests;
- what a wrong `--cluster` looks like;
- whether a certificate really survives deleting its CSR and bindings;
- how a ServiceAccount token compares.

Descriptor coverage: Unit II 2.3 (Kubernetes RBAC) and Unit I 1.5.2
(RBAC for namespace-level access). The descriptor maps both to Assignment 1.

## 2. Environment

| Item | Value |
|---|---|
| Operating system | Windows 11, build 10.0.26300; commands run from Git Bash |
| OpenSSL | 3.5.6 (MinGW build shipped with Git for Windows) |
| kind / kubectl | kind v0.32.0; kubectl client v1.36.3 |
| Cluster | shared `dso202` cluster (`kind-dso202`), v1.36.1, three nodes |
| Admin identity used for setup | `kubernetes-admin`, groups `kubeadm:cluster-admins`, `system:authenticated` (`stage0`) |
| Credential directory | `~/k8s-users` (`C:/Users/zeroe/k8s-users`), outside the repository |

The deviations are listed in the README:

- the context points at `kind-dso202` rather than `kind-kind`;
- Windows-style paths were passed to `kubectl.exe`;
- the CSR and the RBAC objects were also saved as manifests.

## 3. Procedure and Observations

### Step 0 — Environment (`evidence/stage0-environment.txt`)

`kubectl config get-clusters` lists `kind-dso202`, `kind-kind` and an old
EKS entry. Only `kind-dso202` is running. `kubectl auth whoami` shows that
the admin context is itself a certificate identity: user
`kubernetes-admin` in the group `kubeadm:cluster-admins`. The admin
"user" is the same mechanism as the one this lab builds, with a powerful
group in its O field. The `dev` namespace did not exist beforehand.

### Steps 1–2 — Key and CSR (`evidence/step1-2-key-and-csr.txt`)

`openssl genrsa` wrote a 2048-bit key, and `openssl rsa -check` reported
`RSA key ok`. The CSR subject reads `CN=saroj, O=dev-team`.
`openssl req -verify` reported `self-signature verify OK`, which proves that
whoever made the request holds the matching private key. That proof is the
only thing the CSR proves.

### Steps 3–4 — Signed by the cluster CA (`evidence/step3-4-sign-approve.txt`)

| Moment | `CONDITION` |
|---|---|
| after `kubectl apply` | `Pending` (REQUESTOR `kubernetes-admin`, REQUESTEDDURATION `90d`) |
| after `kubectl certificate approve` | `Approved,Issued` within 2 s |

The extracted certificate shows:

- `subject=O=dev-team, CN=saroj` and `issuer=CN=kubernetes`;
- Extended Key Usage `TLS Web Client Authentication` only;
- validity from `Nov 7 17:11:53 2026 GMT` to `Feb 5 17:11:53 2027 GMT`,
  exactly 90 days.

The validity starts about five minutes *before* the request was made (the
key file is stamped 23:16 local time, which is 17:16 UTC). The signer
backdates the start time to tolerate clock differences between machines.

Three further checks went beyond the notes:

- `openssl verify -CAfile cluster-ca.crt saroj.crt` returned `OK` against
  the CA read from the control-plane node.
- The certificate's public key is identical to the one derived from
  `saroj.key`.
- `kube-controller-manager` is started with `--cluster-signing-cert-file`
  and `--cluster-signing-key-file` set to `/etc/kubernetes/pki/ca.{crt,key}`.
  This is the same CA the API server trusts, which is why the notes say to
  use the CSR API rather than signing by hand inside the node. No
  `--cluster-signing-duration` is set, so the default cap applies.

### Step 5 — RBAC (`evidence/step5-rbac.txt`)

Before any binding, I used the certificate directly with flags:

- `auth whoami` returned `Username saroj`, `Groups [dev-team
  system:authenticated]`.
- `get pods -n default` returned `Forbidden: User "saroj" cannot list
  resource "pods"`.

This is the notes' central point: the certificate authenticates, and
authorises nothing.

I then ran the notes' three imperative commands. `kubectl describe role`
shows that kubectl split the resources by API group: `pods` and `pods/log`
are in the core group, and `deployments.apps` is in `apps`. I saved the same
objects as `manifests/02`–`04`. `kubectl diff` against the live objects
exited with 0 (no differences).

### Steps 6–7 — kubeconfig (`evidence/step6-7-kubeconfig.txt`)

After `set-credentials --embed-certs=true`, plain `kubectl config view`
shows `DATA+OMITTED` for both fields. My first check measured that
placeholder (12 characters) and wrongly suggested the data was tiny. With
`--raw`, the fields hold 1488 base64 characters of certificate and 2312 of
private key, and the embedded certificate decodes to `O=dev-team, CN=saroj`.
`set-context saroj-dev --cluster=kind-dso202 --user=saroj --namespace=dev`
created the three-way pointer, as shown by `get-contexts`.

### Step 8 — Switch and verify (`evidence/step8-switch-and-verify.txt`)

| Command (context `saroj-dev`) | Expected (notes) | Observed |
|---|---|---|
| `auth whoami` | — | `saroj`, `[dev-team system:authenticated]` |
| `get pods` | works | `No resources found in dev namespace.` |
| `get pods -n kube-system` | Forbidden | Forbidden |
| `get nodes` | Forbidden | Forbidden, "at the cluster scope" |

To test the Role verb by verb, I went beyond the notes:

| Action | Result | Why |
|---|---|---|
| `create deployment hello` | created, rolled out | `create` on `deployments.apps` |
| `logs deployment/hello` | nginx log lines | `get` on `pods/log` |
| `scale deployment hello --replicas=2` | Forbidden: cannot **patch** `deployments/scale` | no `patch`/`update` verb, and `scale` is a separate subresource |
| `get replicasets` | Forbidden | the Deployment's own ReplicaSet is not listed in the Role |
| `exec deploy/hello` | Forbidden: cannot **create** `pods/exec` | exec is a subresource, granted separately |
| `get secrets` | Forbidden | not listed |
| `delete deployment hello` | deleted | `delete` |

Results of the notes' `auth can-i` checks, run from the admin context:

- `list pods --namespace=dev --as=saroj`: **yes**.
- `delete nodes --as=saroj`: **no**, with a warning that nodes are not
  namespaced.
- `list pods --namespace=dev --as=anyuser --as-group=dev-team`: **no**. This
  is correct for the notes' setup, which binds the *user* `saroj` and not
  the group. The notes list this command beside the group-binding tip, but
  it only answers yes after a group binding exists (Ext 1).

`auth can-i --list` also shows what every authenticated identity gets by
default: self-review APIs and read access to discovery and health URLs.

### Extension 1 — Group binding and a second user (`evidence/ext1-group-binding.txt`)

After `manifests/05-rolebinding-dev-team.yaml` bound `pod-manager` to the
group `dev-team`:

- `--as=anyuser --as-group=dev-team` returned **yes**;
- `--as-group=qa-team` returned **no**.

I then issued a second certificate, `/CN=pema/O=dev-team`, with a 24-hour
expiry. `pema` has no binding of their own. `pema` could list pods in `dev`
and was Forbidden in `default`: the access came only from the O field in
the certificate.

### Extension 2 — Failure modes (`evidence/ext2-failure-modes.txt`)

| Case | What happened |
|---|---|
| `usages: [client auth, server auth]` | Approved, then `Approved,Failed`. Condition `Failed reason=SignerValidationFailure msg=invalid usage for client certificate: server auth`; `.status.certificate` empty |
| `signerName: example.com/my-signer` | stays `Approved` with no `Issued` and no `Failed`: no controller handles that signer |
| context `--cluster=kind-kind` (stopped cluster) | `dial tcp 127.0.0.1:64534 ... actively refused`: the old port of the stopped cluster |
| context `--cluster=kind-dso2O2` (typo: letter O for zero) | `set-context` accepted it silently; requests went to `http://localhost:8080` and were refused |
| `saroj.crt` presented with `pema.key` | rejected by kubectl before any connection: `tls: private key does not match public key` |

The first two rows correct the notes. The notes say that a rejected request
reads "only `Approved`". On this cluster a rejection is explicit,
`Approved,Failed`, and comes with a reason. "Only `Approved`" means
something different: nothing is signing that request. The typo row confirms
the notes' `localhost:8080` warning exactly.

### Extension 3 — The revocation caveat (`evidence/ext3-revocation.txt`)

| Removed | `saroj-dev get pods` | `auth whoami` |
|---|---|---|
| CSR objects `saroj` and `pema` | still works | still `saroj` |
| user RoleBinding `saroj-pod-manager` | **still works**, through the `dev-team` group binding | still `saroj` |
| group RoleBinding as well | Forbidden | **still authenticates as `saroj`** |

The certificate is valid until `Feb 5 17:11:53 2027 GMT` whatever happens to
the objects in the cluster. Deleting a user's own binding did not cut off
access while a group binding they matched still existed. `--as=saroj` alone
answered "no" at that point, while `--as=saroj --as-group=dev-team` answered
"yes", because impersonation only carries the groups you name. I restored
both bindings from the manifests afterwards.

### Extension 4 — ServiceAccount token (`evidence/ext4-serviceaccount-token.txt`)

`kubectl create token ci-bot -n dev --duration=1h` issued a 917-character
JWT. Only its length and claims were recorded:

- `sub` is `system:serviceaccount:dev:ci-bot`;
- the lifetime is 3600 s;
- it is bound to the SA's UID.

Through a separate kubeconfig, the token could list pods in `dev` and was
Forbidden in `kube-system`, the same scoping as the certificate.

Deleting the ServiceAccount did revoke the token, but not instantly:

| Time | Event | Result |
|---|---|---|
| 23:19:50 | token used | works |
| 23:19:50 | `delete serviceaccount ci-bot` | deleted |
| 23:19:51 | token used again | **still works** |
| 23:20:06 | token used again | `Unauthorized` (both `get pods` and `auth whoami`) |

### Extension 5 — Hand-off kubeconfig (`evidence/ext5-handoff-kubeconfig.txt`)

`config view --minify --flatten --context=saroj-dev` produced a standalone
file containing one cluster, one user and one context. It contains
`client-key-data`, so the file *is* the credential. It worked with
`--kubeconfig` (pods allowed, nodes Forbidden) and left the main
kubeconfig's current context unchanged.

## 4. Analysis

**Why there is no `User` object.** Users are defined by whatever
authenticator vouches for them: the CA for certificates, the token issuer,
or the OIDC provider. Kubernetes only receives the resulting name and
groups. The admin context in Step 0 is not a special account. It is a
certificate whose O is `kubeadm:cluster-admins`. Everything in RBAC is
matching strings, so a binding to a user "that does not exist" is valid. It
waits for any request that carries that name.

**Why CN and O carry the identity.** The API server trusts every
certificate signed by its CA, so whoever controls signing controls
identity. Approving a CSR is therefore an identity decision, not a
formality. Approving a CSR with `O=system:masters` would create a cluster
admin. This is why `kubectl certificate approve` is itself protected by
RBAC (`approve` on `signers`), and why the CSR shows its REQUESTOR.

**Authentication and authorization fail in different ways:**

| Failure | Error | Seen in |
|---|---|---|
| Authentication | HTTP 401 `Unauthorized` | deleted ServiceAccount token |
| Authentication, client side | TLS error before any request | wrong private key |
| Authorization | 403 `Forbidden` | every RBAC refusal |

Reading which of the two you got tells you which half to fix.

**What the signer enforces.** For `kubernetes.io/kube-apiserver-client`, the
controller signs only after approval, and only for client-auth usages. An
extra `server auth` usage fails visibly. The issued certificate carries only
the Client Authentication EKU, so even a certificate that was issued could
not serve TLS. The requested duration is honoured up to the controller's
cap. Here 90 days and 24 hours were both given exactly, counted from the
backdated start time.

**Least privilege in the notes' Role.** `pod-manager` can create and delete
Deployments but cannot scale or edit them, and cannot see the ReplicaSets
they create. For a real developer that is an odd set of permissions:
`scale` needs `patch` on `deployments/scale`, and debugging needs
`pods/exec`. Each subresource (`log`, `exec`, `scale`) is a separate grant.
Granting `pods` does not include them.

**Revocation, compared:**

| | x509 client certificate | ServiceAccount token |
|---|---|---|
| Lives in the cluster as | nothing (the CSR is only a request record) | a ServiceAccount object |
| Delete the cluster object | no effect (Ext 3) | rejected within seconds (Ext 4) |
| Remove all RBAC | Forbidden, but still authenticated | Forbidden |
| Lifetime | up to the signing cap (90 d requested) | as requested (1 h) |
| Fits | local development, break-glass admin | workloads, CI, shared clusters |

## 5. Reflection

**Problem: the `kubectl apply` of my CSR said the file did not exist.**
Steps 3–4 first failed with `the path "/c/Users/.../01-csr-saroj.yaml" does
not exist`. The cascade that followed (`NotFound`, then an empty
`saroj.crt`) made it look as if the CSR had been rejected.

1. I ruled out the file: `cat` from the same shell read it.
2. The difference was the reader. Bash and OpenSSL are MSYS programs and
   understand `/c/...`. `kubectl.exe` is a native Windows program.
3. I had exported `MSYS_NO_PATHCONV=1` for the earlier labs, which stops
   Git Bash translating `/c/...` to `C:/...` for Windows programs.
4. Switching the variable to a `C:/` path fixed it.

The same cause later broke one Windows `python` call and one `openssl`
call. The MinGW build of OpenSSL also could not open `/c/...` paths, even
though it runs under MSYS. I corrected those evidence entries and noted
them, rather than leaving failed commands in.

Lesson: on Git Bash, decide which programs see which path style before
writing a helper, and do not trust a failure cascade until its first error
is understood.

**Problem: a revoked token that still worked.** The notes say a
ServiceAccount is "revocable by deleting the object". My first run deleted
`ci-bot` and two seconds later the same token still listed pods. That
seemed to contradict the notes. Instead of writing that down, I re-ran with
timestamps: accepted at +1 s, `Unauthorized` at +16 s.

So revocation works, with a delay of a few seconds. That is consistent with
the API server caching successful token authentications briefly, and with
it seeing the deletion through its watch cache. I did not find the exact
TTL from this cluster's flags (`kube-apiserver.yaml` sets none), so the "a
few seconds" is what I measured, not a documented figure. Either way, it is
a delay of seconds, against the certificate's three months.

**Problem: my own misleading evidence.** My first check of the embedded
kubeconfig fields reported 12 characters each. That is the length of
`DATA+OMITTED`, the redaction placeholder that `kubectl config view` prints
without `--raw`. I replaced it with the `--raw` length check and kept the
redacted output too, because it shows that the default view hides secrets.

**What surprised me.** Group membership is the risky part of certificates.
In Ext 3, deleting `saroj`'s own binding, the obvious "offboarding" step,
did nothing, because `saroj` still matched the `dev-team` group binding. A
group is written into the certificate when it is issued and cannot be taken
out afterwards. The only way to remove someone from a group before expiry
is to remove the binding for the whole group.

**What I would do differently:**

- Issue lab certificates with a short expiry, as I did for `pema` (24 h),
  instead of 90 days. The notes' value is fine for a course, but the
  revocation table shows why short lifetimes are the real control.
- Use a group-only design with ServiceAccounts or OIDC for anything shared.
- Keep the RBAC as files from the start rather than converting imperative
  commands afterwards.

## 6. References

- *Create_CSR* (HackMD, `@sarojsanyasi/dso202-unit2-csr`), course-provided notes — accessed 2026-11-07
- *DSO202 Module Descriptor (resequenced)*, `Module_Descriptor_Resequenced.docx` — accessed 2026-11-07
- kube-apiserver and kube-controller-manager static Pod manifests on the `dso202` control-plane node (`/etc/kubernetes/manifests/`) — 2026-11-07
- Kubernetes v1.36.1 API responses and CSR status conditions (`SignerValidationFailure`) from the cluster — 2026-11-07
- OpenSSL 3.5.6 command output (`genrsa`, `req`, `x509`, `verify`) — 2026-11-07

## 7. Assessment Mapping (Module Descriptor)

Assessed under *A. Practical Work & Report* of the DSO202 module descriptor
(`Module_Descriptor_Resequenced.docx`): practical report out of 5, practical
work out of 15.

### Practical Report (5 marks)

| Criterion (descriptor) | Marks | Where it is evidenced |
|---|---|---|
| Documentation | 2 | §1 Objective with descriptor sections; §2 Environment; §3 one subsection per step and extension, each naming its evidence file and the observed output; §6 References |
| Reflection | 2 | §5: the path-conversion failure traced from its first error; the token that outlived its ServiceAccount, re-tested with timestamps; a corrected piece of my own evidence; what surprised me; what I would change |
| Clarity & Coherence | 1 | Expected-vs-observed tables (Steps 4 and 8, Ext 2–4); §4 links each observation to the authentication/authorization split; two corrections to the notes stated with evidence |

### Practical Work (15 marks)

| Criterion (descriptor) | Marks | Where it is evidenced |
|---|---|---|
| Code Organisation & Readability | 3 | Numbered manifests in apply order; credentials kept outside the repository with a `.gitignore` guard; README with step-to-evidence table, deviations, rebuild and cleanup |
| Code Comments | 2 | Header comment on every manifest explaining purpose, the matching imperative command and the non-obvious rule (CN match, API group split, missing verbs, signer constraints) |
| Functional/Configuration Requirements | 10 | Certificate issued and verified against the cluster CA (`step3-4`); Role and bindings (`step5`, diff exit 0); working context with the expected allowed and Forbidden results (`step8`); group binding, failure modes, revocation, SA token and hand-off extensions (`ext1`–`ext5`) |
