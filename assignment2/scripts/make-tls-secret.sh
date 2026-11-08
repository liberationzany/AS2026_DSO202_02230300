#!/usr/bin/env bash
# make-tls-secret.sh - create the Ingress TLS Secret (tasktracker-tls).
#
# Usage: scripts/make-tls-secret.sh [namespace] [host]
#   defaults: dso202-assignment-2  tasktracker.localhost
#
# Generates a self-signed certificate whose Subject Alternative Name is the
# Ingress host, then creates a kubernetes.io/tls Secret from it. The key is
# written to a temporary directory OUTSIDE the repository and deleted
# afterwards, so it never reaches Git. In production, cert-manager would
# issue and renew this certificate instead (Unit II 2.2.6).
set -euo pipefail

NS="${1:-dso202-assignment-2}"
HOST="${2:-tasktracker.localhost}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Git Bash on Windows: openssl (MinGW) and kubectl.exe are native Windows
# programs. With MSYS_NO_PATHCONV=1 (needed so "/CN=..." is not rewritten
# into a Windows path), they would receive "/tmp/..." untranslated and fail
# to open it, so the directory is converted to a Windows path first.
# cygpath exists only in Git Bash; elsewhere the path is used as it is.
if command -v cygpath >/dev/null 2>&1; then K="$(cygpath -m "$TMP")"; else K="$TMP"; fi

MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout "$K/tls.key" -out "$K/tls.crt" \
  -subj "/CN=${HOST}/O=dso202" \
  -addext "subjectAltName=DNS:${HOST}"

# create --dry-run | apply makes the script safe to re-run.
kubectl create secret tls tasktracker-tls -n "$NS" \
  --cert="$K/tls.crt" --key="$K/tls.key" --dry-run=client -o yaml \
  | kubectl apply -f -

MSYS_NO_PATHCONV=1 openssl x509 -in "$K/tls.crt" -noout -subject -ext subjectAltName -enddate
