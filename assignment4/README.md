# DSO202 — Assignment 4: GitOps Delivery of the Task Tracker with Argo CD

The brief requires a separate public repository, so the submission lives at:

**<https://github.com/liberationzany/dso202-gitops>**

| Submission item | Value |
|---|---|
| Repository | `https://github.com/liberationzany/dso202-gitops` (public) |
| Commit SHA of `main` at submission | `5fcb23e` (`git ls-remote https://github.com/liberationzany/dso202-gitops.git main`) |
| Tags | `v1.0.0` (baseline), `v1.1.0` (frontend 1.1), `v1.2.0` (backend 1.1 with `APP_ENV`) |
| README | rebuild sequence, pinned versions, cleanup, credential handling, deviations, answers Q1–Q6 |
| Evidence | `docs/evidence.md` (Tasks 1–9) and `docs/screenshots/` |
| Pull requests | #1–#6 (Task 7: release, promotion, faulty release, revert, fix forward, promotion); #7 (Task 10) |

Task 10 (bonus) is done: `tasktracker-dev` is a two-source Application (chart + `$values`), merged as PR #7, with evidence in `docs/evidence.md` and a README section.

## What is in this folder

`stand-in-images/` — the source of the local images the GitOps repository
deploys. On 2026-11-19 the tutor's `sarojsanyasi/dso202-{frontend,backend,db}`
repositories offered only tag `1.0`, only for `linux/arm64` (as found in
Assignment 1), and tag `1.1` did not exist. The stand-ins are:

| Image | Built from | Behaviour |
|---|---|---|
| `local/dso202-{frontend,backend,db}:1.0` | the Assignment 1 images, re-tagged | baseline |
| `local/dso202-frontend:1.1` | 1.0 + `frontend-1.1/index.html` | header shows "release 1.1" (the release note) |
| `local/dso202-backend:1.1` | 1.0 + `backend-1.1/src/config.js`, `server.js` | "configuration loading refactored" — and, undocumented, refuses to start without `APP_ENV` (the Task 7 fault, diagnosed from its log) |

Build with `stand-in-images/build.sh`, then `kind load docker-image …`
(commands in the GitOps repository's README). The images are never pushed.

The sealing-key backup and the `reviewer` password are kept outside both
repositories, in `C:\Users\zeroe\dso202-keys` (not on the OneDrive-synced
Desktop), readable only by the owner.

## Assessment mapping (module descriptor)

Assessed under *B. Assignments* of the DSO202 module descriptor
(`Module_Descriptor_Resequenced.docx`), out of 10 marks; the brief's own
rubric (section 12) splits the same five criteria further.

| Criterion (descriptor) | Marks | Where it is evidenced (in `dso202-gitops`) |
|---|---|---|
| Code Organization & Readability | 1 | Layout of brief section 7; one concern per directory (`bootstrap/`, `argocd/`, `platform/`, `charts/`, `environments/`); Application files share one structure |
| Code Comments & Documentation | 1 | Header (path, assignment, descriptor, purpose) on every file; README; `docs/evidence.md` |
| Configuration Requirements | 2 | Chart contract C1–C11 table (evidence, Task 1); least-privilege `dso202` project; credentials only as SealedSecrets, key backed up outside Git; answers Q1–Q6 |
| Configuration Implementation | 5 | Tasks 2–8 in `docs/evidence.md`: pinned Argo CD install; projects and root; Sealed Secrets and platform layer; waves, smoke test, dev automated / staging manual; reviewer RBAC; release, faulty release, revert, fix forward, promotion; four drills |
| Deployment & Configuration | 1 | Task 9: cluster deleted and rebuilt from the repository and the key backup; both environments working (44 s from the root Application to a Healthy dev) |
