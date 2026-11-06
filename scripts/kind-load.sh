#!/usr/bin/env bash
# Loads local Docker images into the kind node.
# Usage: scripts/kind-load.sh <image> [<image> ...]
#
# `kind load` imports every platform in an image's index. Docker keeps only one platform of a
# pulled image, so that fails with "content digest not found". Exporting one platform works.
set -euo pipefail

NODE="${KIND_CLUSTER:-leadpipe}-control-plane"
platform="linux/$(docker version --format '{{.Server.Arch}}')"

for image in "$@"; do
  echo "    ${image}"
  docker save --platform "${platform}" "${image}" \
    | docker exec --interactive "${NODE}" \
      ctr --namespace=k8s.io images import --digests --snapshotter=overlayfs - >/dev/null
done
