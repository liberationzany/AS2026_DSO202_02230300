# DSO202 — Practical 6: Helm Charts and the Release Lifecycle

## Purpose

Packages the Practical 1 web page (`nginx:1.30-alpine`) as a Helm chart,
`webapp`, and operates it through the whole Helm 4 release lifecycle on the
shared `dso202` kind cluster, following *Unit III 3.2 — Helm*. It covers:

- **Stage 0** — Helm 4 and the cluster are checked.
- **Stage 1** — consuming a published chart (podinfo): repo, search, show,
  install, inspect, the release record, the values-loss upgrade,
  `--reuse-values`, rollback, uninstall, and OCI.
- **Stage 2** — the chart skeleton (`Chart.yaml`, `values.yaml`, `.helmignore`).
- **Stage 3** — templates: helpers, recommended labels, the checksum
  annotation, NOTES and a `helm test` Pod.
- **Stage 4** — values precedence and merging.
- **Stage 5** — four validation failures and `values.schema.json`.
- **Stage 6** — the release lifecycle on the chart: `upgrade --install`,
  `helm test`, checksum rollout, rollback, server-side-apply drift
  conflicts, a NodePort clash with `--rollback-on-failure`.

Descriptor mapping: Unit III 3.2. The resequenced descriptor lists this lab
as Practical 5, "Create a Helm chart for a complex application and deploy
it to Kubernetes". The course guide is titled "practical 6".

## Software versions used

| Tool                 | Version                                         |
|----------------------|-------------------------------------------------|
| OS                   | Windows 11 (build 10.0.26300), Git Bash         |
| Docker Desktop       | 29.4.0 (WSL 2 backend)                          |
| kind                 | v0.32.0                                         |
| kubectl (client)     | v1.36.3                                         |
| Helm                 | **v4.3.1** (installed with `winget install Helm.Helm`) |
| Kubernetes (cluster) | v1.36.1 — shared `dso202` cluster (control-plane, worker-node-1, worker-node-2) |
| Charts / images      | podinfo chart 6.15.0 (`ghcr.io/stefanprodan/podinfo:6.15.0`); `webapp` 0.1.0 (`nginx:1.30-alpine`, `busybox:1.37` for tests) |

## Repository structure

```
practical-06/
├── README.md
├── dso202-helm-lab/                 # the lab directory from Stage 0, step 6
│   ├── environments/                # deployment values, kept OUTSIDE the chart
│   │   ├── dev.yaml                 # 1 replica, NodePort 30083 (message changed to v2 in Stage 6)
│   │   └── prod.yaml                # 3 replicas, raised resources, ClusterIP
│   └── webapp/                      # the chart
│       ├── Chart.yaml               # version 0.1.0, appVersion "1.30-alpine"
│       ├── values.yaml              # documented defaults (the chart's interface)
│       ├── values.schema.json       # type/enum/range checks (Stage 5)
│       ├── .helmignore
│       ├── charts/                  # empty: no dependencies
│       └── templates/
│           ├── _helpers.tpl         # names, label sets, required environment
│           ├── configmap.yaml       # the page, built from values
│           ├── deployment.yaml      # checksum/config annotation, probes
│           ├── service.yaml         # nodePort only when NodePort + set
│           ├── NOTES.txt
│           └── tests/test-connection.yaml   # helm test hook
├── evidence/                        # command output per stage
└── report/
    └── practical-06-report.md
```

## Deviations from the notes

- **Dev NodePort is 30083, not 30080.** The notes create a fresh cluster.
  This run uses the existing `dso202` cluster, where Practical 1's
  `web-nodeport` holds 30080 and Assignment 1 holds 30081/30082. The clash
  the notes warn about was reproduced on purpose in Stage 6.
- **Local ports 8086 and 8080.** podinfo was reached through a
  port-forward on 8086, because 8080 is used by the Argo CD UI.
- **Stage 6 is reconstructed.** The notes end at section 3.2.3.2, before
  Stage 6's steps. Its commands were built from the lifecycle flags and the
  server-side-apply table in 3.2.3.
- **`jq` was replaced by `python`** to decode the release record. `jq` is
  not installed on this machine.

## Rebuilding from a clean state

```bash
export MSYS_NO_PATHCONV=1                     # Git Bash on Windows only
kubectl config use-context kind-dso202
cd practicals/practical-06/dso202-helm-lab

# Validate every environment before touching the cluster
for env in dev prod; do
  helm lint ./webapp -f environments/$env.yaml &&
  helm template webapp-$env ./webapp -f environments/$env.yaml > /dev/null &&
  echo "$env: ok"
done

# Install / upgrade (idempotent) and test
for env in dev prod; do
  helm upgrade --install webapp-$env ./webapp -f environments/$env.yaml \
    -n dso202-$env --create-namespace --wait --timeout 5m
  helm test webapp-$env -n dso202-$env
done

# Dev is a NodePort (30083) — from a node:
docker exec dso202-control-plane curl -s http://localhost:30083
```

## Cleanup

```bash
helm uninstall webapp-dev  -n dso202-dev
helm uninstall webapp-prod -n dso202-prod
# --create-namespace does not make the namespace part of the release
kubectl delete namespace dso202-dev dso202-prod dso202-helm
helm list -A            # expect only the headings
```

All three namespaces and all releases were removed at the end of this run.
The `podinfo` repository entry is still in the local Helm config
(`helm repo remove podinfo` removes it).
