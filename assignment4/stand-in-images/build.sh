#!/usr/bin/env bash
# build.sh - build the local stand-ins for the tutor's Assignment 4 images.
#
# Why: sarojsanyasi/dso202-{frontend,backend,db} on Docker Hub publish only
# tag 1.0, and only for linux/arm64 (checked 2026-11-19); tag 1.1 does not
# exist. This machine and its kind nodes are linux/amd64.
#
#   1.0  = the Assignment 1 images, built natively from the given source
#          (assignment1/Assignment-1-app-code), re-tagged.
#   1.1  = 1.0 plus exactly what the brief's release notes describe:
#          frontend: the page header shows the release number;
#          backend:  configuration loading refactored - and, undocumented,
#                    APP_ENV is now required (the Task 7 fault).
#
# The images are loaded into kind and never pushed. The "local/" prefix
# keeps them apart from the tutor's names and from Assignment 2's
# dso202-backend:1.1 (a different fix).
set -euo pipefail
cd "$(dirname "$0")"

docker tag dso202-frontend:1.0 local/dso202-frontend:1.0
docker tag dso202-backend:1.0  local/dso202-backend:1.0
docker tag dso202-db:1.0       local/dso202-db:1.0

docker build -q -t local/dso202-frontend:1.1 frontend-1.1
docker build -q -t local/dso202-backend:1.1  backend-1.1

docker images --format '{{.Repository}}:{{.Tag}}  {{.ID}}  {{.Size}}' | grep '^local/dso202-'
