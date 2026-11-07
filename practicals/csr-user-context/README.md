# DSO202 — CSR Lab: Creating a Kubernetes "User" and Context

## Purpose

Follows *Create_CSR* (Unit II, RBAC). Kubernetes has no `User` object, so
"creating a user" here means two separate things:

1. **Authentication.** Mint an x509 client certificate that the cluster CA
   signs. The CN becomes the username and each O becomes a group.
2. **Authorization.** Bind an RBAC Role to that name.

Then a kubeconfig context is built for the identity, and it is shown that
the identity can only do what its Role allows.

| Step | What | Evidence |
|---|---|---|
| 0 | Tools, cluster, admin identity | `evidence/stage0-environment.txt` |
| 1–2 | Private key and CSR (`/CN=saroj/O=dev-team`) | `evidence/step1-2-key-and-csr.txt` |
| 3–4 | CSR API object, approval, extraction, verification against the cluster CA | `evidence/step3-4-sign-approve.txt` |
| 5 | Namespace `dev`, Role `pod-manager`, RoleBinding for `saroj` | `evidence/step5-rbac.txt` |
| 6–7 | `set-credentials --embed-certs`, context `saroj-dev` | `evidence/step6-7-kubeconfig.txt` |
| 8 | Switch and verify: allowed and Forbidden requests, `auth can-i` | `evidence/step8-switch-and-verify.txt` |
| Ext 1 | Group binding, and a second user (`pema`) with no user binding | `evidence/ext1-group-binding.txt` |
| Ext 2 | Failure modes: extra usage, unknown signer, wrong cluster, wrong key | `evidence/ext2-failure-modes.txt` |
| Ext 3 | Revocation caveat: CSR and bindings deleted, certificate still authenticates | `evidence/ext3-revocation.txt` |
| Ext 4 | ServiceAccount token: issue, use, revoke by deleting the SA | `evidence/ext4-serviceaccount-token.txt` |
| Ext 5 | Standalone kubeconfig for hand-off | `evidence/ext5-handoff-kubeconfig.txt` |
| — | State left on the cluster | `evidence/final-state.txt` |

Descriptor mapping: Unit II 2.3 (Kubernetes RBAC) and Unit I 1.5.2
(namespace-level access). The descriptor maps Assignment 1 to Units I and
II, "core objects, RBAC".

## Software versions used

| Tool | Version |
|---|---|
| OS | Windows 11 (build 10.0.26300), Git Bash |
| OpenSSL | 3.5.6 (Git for Windows, MinGW build) |
| kind | v0.32.0 |
| kubectl (client) | v1.36.3 |
| Kubernetes (cluster) | v1.36.1, shared `dso202` cluster (control-plane, worker-node-1, worker-node-2) |

## Repository structure

```
csr-user-context/
├── README.md
├── .gitignore                       # *.key, *.kubeconfig, *.crt, *.token
├── manifests/
│   ├── 01-csr-saroj.yaml            # CertificateSigningRequest (public data only)
│   ├── 02-namespace-dev.yaml
│   ├── 03-role-pod-manager.yaml     # declarative form of Step 5's kubectl create role
│   ├── 04-rolebinding-saroj.yaml    # User binding (CN must match)
│   ├── 05-rolebinding-dev-team.yaml # extension: Group binding (O=dev-team)
│   └── 06-serviceaccount-ci-bot.yaml# extension: SA + binding for the token comparison
├── evidence/                        # real command output, one file per step
└── report/
    └── csr-lab-report.md
```

**Credentials are not in the repository.** As the notes do, the key,
certificate and hand-off kubeconfig were written to `~/k8s-users`. The
evidence shows only subjects, dates and lengths, never key, certificate or
token material. `01-csr-saroj.yaml` contains only the CSR: the public key
and the subject. `kubectl diff` against Step 5's imperative objects showed
no difference from `02`–`04`.

## Deviations from the notes

- **Cluster `kind-dso202`, not `kind-kind`.** The lab ran on the shared
  course cluster. A `kind-kind` entry is still in the kubeconfig, but its
  container is stopped. Ext 2 uses it to show the notes' warning about a
  wrong `--cluster` value: the stopped cluster gives "connection refused" on
  its old port, and a misspelled cluster name falls back to `localhost:8080`.
- **Windows paths for Windows binaries.** `kubectl.exe` received
  `C:/Users/zeroe/k8s-users/...` instead of `$HOME/k8s-users/...`, because
  Git Bash path conversion is turned off (`MSYS_NO_PATHCONV=1`) for the
  other labs.
- **Steps 3 and 5 also exist as files.** The CSR heredoc was written to
  `manifests/01-csr-saroj.yaml` before `kubectl apply`. The imperative RBAC
  commands were run exactly as the notes give them, and then also saved as
  declarative manifests.

## Rebuilding from a clean state

```bash
export MSYS_NO_PATHCONV=1
mkdir -p ~/k8s-users && cd ~/k8s-users
openssl genrsa -out saroj.key 2048
openssl req -new -key saroj.key -out saroj.csr -subj "/CN=saroj/O=dev-team"

# a new key means a new request: regenerate the CSR manifest
REQ=$(base64 < saroj.csr | tr -d '\n')
sed "s|^  request: .*|  request: ${REQ}|" <REPO>/practicals/csr-user-context/manifests/01-csr-saroj.yaml \
  | kubectl apply -f -
kubectl certificate approve saroj
kubectl get csr saroj -o jsonpath='{.status.certificate}' | base64 -d > saroj.crt

cd <REPO>/practicals/csr-user-context
kubectl apply -f manifests/02-namespace-dev.yaml -f manifests/03-role-pod-manager.yaml \
              -f manifests/04-rolebinding-saroj.yaml

kubectl config set-credentials saroj --client-certificate=C:/Users/<you>/k8s-users/saroj.crt \
  --client-key=C:/Users/<you>/k8s-users/saroj.key --embed-certs=true
kubectl config set-context saroj-dev --cluster=kind-dso202 --user=saroj --namespace=dev
kubectl --context saroj-dev get pods        # works
kubectl --context saroj-dev get nodes       # Forbidden
```

## State left behind and cleanup

The `dev` namespace, the `pod-manager` Role, both RoleBindings, and the
`saroj` user and `saroj-dev` context in `~/.kube/config` were left in place
so the context can be demonstrated. The current context was switched back to
`kind-dso202`. No CSR objects remain.

```bash
kubectl delete namespace dev                         # Role and bindings go with it
kubectl config delete-context saroj-dev
kubectl config delete-user saroj
rm -rf ~/k8s-users                                   # keys and hand-off kubeconfig
```

The issued certificates stay valid until they expire, which removing them
from the cluster does not change: `saroj` on 2027-02-05 and `pema` on
2026-11-08 (see the report, §4). Once the bindings are gone they authorise
nothing.
