#!/usr/bin/env bash
# Build script for Kubernetes LTS components.
# Pitfall notes baked in:
#   - Uses setup-go on runner (not docker), so rsync is available.
#   - Never uses bash -lc (strips PATH).
#   - GOFLAGS=-mod=vendor (kubernetes vendors all deps).
#   - -buildvcs=false (Go 1.18+ embeds VCS info, fails without git state).
#   - nfpm installed via apt, not tarball (tarball URLs 404 frequently).
set -euo pipefail

COMPONENT=""
KIND=""
TAG=""
REGISTRY_PATH=""
BASE_IMAGE=""
SOURCE_DIR="."

usage() {
  echo "Usage: $0 --component <name> --kind image|deb --tag <vX.Y.Z-lts.N> \\"
  echo "          --registry-path <path> [--base-image <image>] [--source-dir <dir>]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --component)     COMPONENT="$2";      shift 2 ;;
    --kind)          KIND="$2";           shift 2 ;;
    --tag)           TAG="$2";            shift 2 ;;
    --registry-path) REGISTRY_PATH="$2"; shift 2 ;;
    --base-image)    BASE_IMAGE="$2";     shift 2 ;;
    --source-dir)    SOURCE_DIR="$2";     shift 2 ;;
    *) echo "Unknown flag: $1"; usage ;;
  esac
done

[[ -z "$COMPONENT" || -z "$KIND" || -z "$TAG" || -z "$REGISTRY_PATH" ]] && usage
[[ "$KIND" == "image" && -z "$BASE_IMAGE" ]] && { echo "ERROR: --base-image required for kind=image"; exit 1; }

BIN_DIR="/tmp/lts-bin/${COMPONENT}"
mkdir -p "${BIN_DIR}"

echo "==> Building ${COMPONENT} (${KIND}) @ ${TAG}"

# Build binary – must run in subshell so env vars don't leak
(
  cd "${SOURCE_DIR}"
  export GOFLAGS="-mod=vendor -trimpath -buildvcs=false"
  export GOPROXY=off
  export GOSUMDB=off
  export CGO_ENABLED=0
  export GOOS=linux
  export GOARCH=amd64
  go build -o "${BIN_DIR}/${COMPONENT}" "./cmd/${COMPONENT}/"
)

echo "==> Binary built: ${BIN_DIR}/${COMPONENT} ($(du -sh "${BIN_DIR}/${COMPONENT}" | cut -f1))"

if [[ "$KIND" == "image" ]]; then
  RUN_ID="${GITHUB_RUN_ID:-local}"
  IMAGE_TAG="${REGISTRY_PATH}:${TAG}"
  CANDIDATE_TAG="${REGISTRY_PATH}:candidate-${RUN_ID}"

  # Write Dockerfile to temp file
  DOCKERFILE=$(mktemp /tmp/Dockerfile.XXXXXX)
  cat > "${DOCKERFILE}" <<DOCKERFILE_CONTENT
FROM ${BASE_IMAGE}
COPY bin/${COMPONENT} /usr/local/bin/${COMPONENT}
LABEL net.lts.component="${COMPONENT}"
LABEL net.lts.tag="${TAG}"
LABEL net.lts.bundle="kubernetes-lts"
LABEL net.lts.source-repo="oleksandr-minakov/k8s-test-sonnet"
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/${COMPONENT}"]
DOCKERFILE_CONTENT

  # Build context: only the binary
  CTX_DIR=$(mktemp -d /tmp/docker-ctx-XXXXXX)
  mkdir -p "${CTX_DIR}/bin"
  cp "${BIN_DIR}/${COMPONENT}" "${CTX_DIR}/bin/"

  docker build -f "${DOCKERFILE}" \
    -t "${IMAGE_TAG}" \
    -t "${CANDIDATE_TAG}" \
    "${CTX_DIR}/"

  docker push "${IMAGE_TAG}"
  docker push "${CANDIDATE_TAG}"

  # Write outputs for calling workflow
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "image_ref=${IMAGE_TAG}" >> "${GITHUB_OUTPUT}"
  fi

  echo "==> Image pushed: ${IMAGE_TAG}"
  echo "==> Candidate: ${CANDIDATE_TAG}"

elif [[ "$KIND" == "deb" ]]; then
  # Install nfpm via apt (tarball URLs are unreliable – see pitfall #6)
  if ! command -v nfpm &>/dev/null; then
    echo "==> Installing nfpm via apt"
    echo 'deb [trusted=yes] https://repo.goreleaser.com/apt/ /' \
      | sudo tee /etc/apt/sources.list.d/goreleaser.list
    sudo apt-get update -q
    sudo apt-get install -y nfpm
  fi

  DIST_DIR="dist"
  mkdir -p "${DIST_DIR}"

  # Strip leading 'v' for the deb package version
  VERSION_NOPREFIX="${TAG#v}"

  # Write nfpm config to temp file (not /dev/stdin – may not be supported)
  NFPM_CFG=$(mktemp /tmp/nfpm-XXXXXX.yaml)
  cat > "${NFPM_CFG}" <<NFPM_CONTENT
name: "${COMPONENT}"
version: "${VERSION_NOPREFIX}"
arch: "amd64"
maintainer: "Mirantis LTS <dtag@mirantis.com>"
description: "Kubernetes ${COMPONENT} LTS build ${TAG}"
license: "Apache-2.0"
contents:
  - src: "${BIN_DIR}/${COMPONENT}"
    dst: "/usr/bin/${COMPONENT}"
    file_info:
      mode: 0755
NFPM_CONTENT

  nfpm package --config "${NFPM_CFG}" --packager deb --target "${DIST_DIR}/"

  echo "==> Deb package built:"
  ls -lh "${DIST_DIR}/"

else
  echo "ERROR: Unknown kind: ${KIND}"; exit 1
fi
