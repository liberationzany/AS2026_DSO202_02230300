#!/usr/bin/env bash
# =============================================================================
# File       : reconcile.sh
# Descriptor : Unit II 2.4.2 - writing controllers
# Purpose    : Maintain one ConfigMap, one Deployment, and one Service for
#              every StaticSite object in the cluster, and report observed
#              state on the object's status subresource.
# Run with   : bash reconcile.sh
# Stop with  : Ctrl+C
# =============================================================================
set -u -o pipefail

GROUP="dso202.cst.edu.bt"
INTERVAL="5"   # seconds between passes

# -----------------------------------------------------------------------------
# reconcile_one: one reconciliation pass for one StaticSite.
#
# The function is idempotent. Desired state is computed from spec alone, and
# 'kubectl apply' creates the objects on the first pass and changes nothing on
# later passes when the spec has not changed. Calling this function a hundred
# times in succession has the same effect as calling it once, which is the
# property required by 2.4.3.
# -----------------------------------------------------------------------------
reconcile_one() {
  local ns="$1" name="$2" uid="$3" generation="$4" replicas="$5" message="$6"

  # Every child object carries an owner reference back to the StaticSite.
  #  - controller: true marks this StaticSite as the managing owner
  #  - blockOwnerDeletion delays removal of the owner until dependants go
  # Because of this block, the controller needs no deletion logic at all:
  # built-in garbage collection removes the children when the owner is deleted.
  local owner
  owner=$(cat <<OWNER
  ownerReferences:
    - apiVersion: ${GROUP}/v1
      kind: StaticSite
      name: ${name}
      uid: ${uid}
      controller: true
      blockOwnerDeletion: true
OWNER
)

  # ---------------------------------------------------------------------------
  # Desired state, computed from spec. Note that nothing here reads the current
  # state of the cluster; the manifest describes the end state, and the API
  # server determines the difference. This is what 'level-triggered' means in
  # practice.
  # ---------------------------------------------------------------------------
  kubectl apply -f - >/dev/null <<MANIFEST
apiVersion: v1
kind: ConfigMap
metadata:
  name: site-${name}
  namespace: ${ns}
  labels:
    app.kubernetes.io/name: staticsite
    app.kubernetes.io/instance: ${name}
    app.kubernetes.io/managed-by: staticsite-controller
${owner}
data:
  index.html: |
    <!DOCTYPE html>
    <html><body><h1>${message}</h1><p>StaticSite: ${name}</p></body></html>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: site-${name}
  namespace: ${ns}
  labels:
    app.kubernetes.io/name: staticsite
    app.kubernetes.io/instance: ${name}
    app.kubernetes.io/managed-by: staticsite-controller
${owner}
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app.kubernetes.io/name: staticsite
      app.kubernetes.io/instance: ${name}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: staticsite
        app.kubernetes.io/instance: ${name}
      annotations:
        # The content is mounted from a ConfigMap, and a ConfigMap change does
        # not restart Pods by itself. Stamping the generation into the Pod
        # template makes a spec change roll the Pods, which is the same
        # technique production operators use for configuration changes.
        ${GROUP}/spec-generation: "${generation}"
    spec:
      containers:
        - name: web
          image: nginx:1.30-alpine
          ports:
            - name: http
              containerPort: 80
          volumeMounts:
            - name: content
              mountPath: /usr/share/nginx/html
              readOnly: true
          resources:
            requests:
              cpu: "25m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
          readinessProbe:
            httpGet:
              path: /
              port: http
            periodSeconds: 5
      volumes:
        - name: content
          configMap:
            name: site-${name}
---
apiVersion: v1
kind: Service
metadata:
  name: site-${name}
  namespace: ${ns}
  labels:
    app.kubernetes.io/name: staticsite
    app.kubernetes.io/instance: ${name}
    app.kubernetes.io/managed-by: staticsite-controller
${owner}
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: staticsite
    app.kubernetes.io/instance: ${name}
  ports:
    - name: http
      port: 80
      targetPort: http
MANIFEST

  # ---------------------------------------------------------------------------
  # Observed state, read from the Deployment the controller itself created, and
  # written to the status subresource. '--subresource=status' is required: a
  # patch without it would be accepted and would change nothing, as shown in
  # Stage 4.6.
  #
  # SIMPLIFICATION: a production controller writes status only when a value has
  # changed, and reports a list of conditions rather than a phase string. This
  # loop patches on every pass, which is acceptable only because it polls.
  # ---------------------------------------------------------------------------
  local ready phase
  ready=$(kubectl get deployment "site-${name}" -n "${ns}" \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  ready="${ready:-0}"
  if [ "${ready}" = "${replicas}" ]; then phase="Ready"; else phase="Progressing"; fi

  kubectl patch staticsite "${name}" -n "${ns}" \
    --subresource=status --type=merge \
    -p "{\"status\":{\"phase\":\"${phase}\",\"readyReplicas\":${ready},\"observedGeneration\":${generation}}}" \
    >/dev/null

  printf '%s reconciled %s/%s replicas=%s ready=%s phase=%s\n' \
    "$(date +%H:%M:%S)" "${ns}" "${name}" "${replicas}" "${ready}" "${phase}"
}

# -----------------------------------------------------------------------------
# The control loop.
#
# SIMPLIFICATION: a real controller opens a watch, caches objects in an
# informer, and enqueues only the namespace and name of changed objects. This
# loop lists every object every five seconds. The behaviour is the same at this
# scale, and it fails at large scale because the cost per pass grows with the
# number of objects rather than with the number of changes.
#
# No deletion branch exists. A StaticSite that has been deleted simply does not
# appear in the list, and its children are removed by garbage collection.
# -----------------------------------------------------------------------------
echo "staticsite-controller started; watching group ${GROUP}"
while true; do
  kubectl get staticsites --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.metadata.uid}{"\t"}{.metadata.generation}{"\t"}{.spec.replicas}{"\t"}{.spec.message}{"\n"}{end}' \
    | while IFS=$'\t' read -r ns name uid generation replicas message; do
        [ -z "${ns:-}" ] && continue
        reconcile_one "$ns" "$name" "$uid" "$generation" "$replicas" "$message"
      done
  sleep "${INTERVAL}"
done
