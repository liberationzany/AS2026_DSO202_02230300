#!/usr/bin/env bash
# host-proxy.sh - make the Ingress controller reachable from the Windows host.
#
# The kind provider manifest for ingress-nginx publishes the controller on
# hostPort 80/443 of whichever node it runs on. The dso202 cluster was
# created (Practical 1) with only host port 30080 mapped, and recreating it
# would destroy the other labs. As in Assignment 1, a small socat container
# on the "kind" Docker network forwards host ports to that node instead:
#   https://tasktracker.localhost:8443  ->  <node>:443
#   http://tasktracker.localhost:8081   ->  <node>:80
# Re-run it if the controller Pod moves to another node.
set -euo pipefail

NODE_NAME="$(kubectl get pods -n ingress-nginx \
  -l app.kubernetes.io/component=controller \
  -o jsonpath='{.items[0].spec.nodeName}')"

# Kubernetes node names (control-plane, worker-node-1, ...) differ from the
# Docker container names (dso202-control-plane, dso202-worker, ...), so use
# the node's InternalIP on the kind network.
NODE_IP="$(kubectl get node "$NODE_NAME" \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
echo "ingress controller runs on ${NODE_NAME} (${NODE_IP})"

for pair in "8443:443" "8081:80"; do
  host_port="${pair%%:*}"; node_port="${pair##*:}"
  name="dso202-ingress-proxy-${host_port}"
  docker rm -f "$name" >/dev/null 2>&1 || true
  # Bound to IPv4 loopback only, never to the LAN. Not to [::1] as well:
  # Docker Desktop accepted IPv6 loopback connections but the TLS handshake
  # through it failed. With nothing listening on ::1, clients that try ::1
  # first get "connection refused" and fall back to 127.0.0.1 at once.
  docker run -d --name "$name" --network kind --restart unless-stopped \
    -p "127.0.0.1:${host_port}:${host_port}" alpine/socat \
    "tcp-listen:${host_port},fork,reuseaddr" "tcp-connect:${NODE_IP}:${node_port}" >/dev/null
  echo "localhost:${host_port} -> ${NODE_IP}:${node_port}  (${name})"
done
