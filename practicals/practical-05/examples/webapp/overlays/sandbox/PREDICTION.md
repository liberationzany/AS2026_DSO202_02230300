# Sandbox overlay - prediction written BEFORE rendering

`namePrefix: sandbox-` on top of the base. Predicted rendered names and references:

| Field | Base value | Predicted after prefix | Why |
|---|---|---|---|
| Deployment `metadata.name` | `webapp` | `sandbox-webapp` | object name, prefixed |
| Service `metadata.name` | `webapp` | `sandbox-webapp` | object name, prefixed |
| ConfigMap `metadata.name` | `web-content-<hash>` | `sandbox-web-content-<hash>` | prefix first, then hash suffix |
| Deployment `volumes[].configMap.name` | `web-content-<hash>` | `sandbox-web-content-<hash>` | a reference to the ConfigMap: must follow the rename |
| Deployment `volumes[].name` | `web-content` | `web-content` (unchanged) | a local volume name, not an object reference |
| `volumeMounts[].name` | `web-content` | `web-content` (unchanged) | refers to the local volume name |
| Container name | `webapp` | `webapp` (unchanged) | not an object name |
| Labels / selectors `app.kubernetes.io/name` | `webapp` | `webapp` (unchanged) | label values are not names; Service still selects the Pods |
| Hash value | base hash | **same** as base hash | content is identical to the base page; prefix should not change the content hash (uncertain) |

## Result after rendering (`evidence/challenge-nameprefix.txt`)

Every prediction held:

- `sandbox-webapp` (Deployment and Service) and `sandbox-web-content-d5t9kfg4d9` (ConfigMap).
- The volume's `configMap.name` was rewritten to `sandbox-web-content-d5t9kfg4d9`, so the reference stayed consistent.
- Volume name, mount name, container name and every label/selector value stayed unchanged.
- The hash `d5t9kfg4d9` is identical to the base's. The prefix is applied to the name; the hash is computed from the content, which did not change.

**Side observation:** the sandbox page is the base's "an overlay forgot to replace web-content" text. That is correct, because this overlay has no `configMapGenerator` replace, and it is exactly the mistake that placeholder text is there to expose.
