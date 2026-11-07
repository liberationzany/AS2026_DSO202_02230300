# =============================================================================
# File    : Dockerfile
# Purpose : A minimal image containing bash and kubectl, used to run
#           reconcile.sh inside the cluster (Stage 10).
# Build   : docker build -t dso202/staticsite-controller:1.0 .
# Load    : kind load docker-image dso202/staticsite-controller:1.0 --name dso202
# =============================================================================
FROM alpine:3.22

# Change amd64 to arm64 on Apple Silicon or other 64-bit ARM hosts.
RUN apk add --no-cache bash curl \
 && curl -fsSLo /usr/local/bin/kubectl \
      https://dl.k8s.io/release/v1.36.0/bin/linux/amd64/kubectl \
 && chmod +x /usr/local/bin/kubectl

# Run as an unprivileged user; the controller needs no root access.
USER 65532:65532
