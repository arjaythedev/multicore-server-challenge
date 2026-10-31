
#!/usr/bin/env bash
set -euo pipefail

NODE_VERSION="26.13.0"
INSTALL_ROOT="/opt/nodejs"

log() {
  printf '[install] %s\n' "$*"
}

if (( EUID != 0 )); then
  echo "[install] Run as root" >&2
  exit 1
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "[install] Linux is required" >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "[install] Ubuntu/Debian with apt-get is required" >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64|amd64)
    NODE_ARCH="linux-x64"
    ;;
  aarch64|arm64)
    NODE_ARCH="linux-arm64"
    ;;
  *)
    echo "[install] Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

INSTALL_DIR="${INSTALL_ROOT}/v${NODE_VERSION}-${NODE_ARCH}"
ARCHIVE="node-v${NODE_VERSION}-${NODE_ARCH}.tar.xz"
BASE_URL="https://nodejs.org/dist/v${NODE_VERSION}"

log "Architecture: ${NODE_ARCH}"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  xz-utils \
  libatomic1

install -d -m 0755 "${INSTALL_ROOT}"

if [[ ! -x "${INSTALL_DIR}/bin/node" ]]; then
  TEMP_DIR="$(mktemp -d "${INSTALL_ROOT}/.install.XXXXXX")"
  trap 'rm -rf -- "${TEMP_DIR}"' EXIT

  log "Downloading Node.js ${NODE_VERSION}..."

  curl -fLsS --retry 3 \
    "${BASE_URL}/${ARCHIVE}" \
    -o "${TEMP_DIR}/${ARCHIVE}"

  curl -fLsS --retry 3 \
    "${BASE_URL}/SHASUMS256.txt" \
    -o "${TEMP_DIR}/SHASUMS256.txt"

  log "Verifying archive..."

  (
    cd "${TEMP_DIR}"
    grep -F "  ${ARCHIVE}" SHASUMS256.txt \
      | sha256sum --check --status
  )

  tar -xJf "${TEMP_DIR}/${ARCHIVE}" -C "${TEMP_DIR}"

  mv \
    "${TEMP_DIR}/node-v${NODE_VERSION}-${NODE_ARCH}" \
    "${INSTALL_DIR}"
else
  log "Existing installation found."
fi

ACTUAL_VERSION="$("${INSTALL_DIR}/bin/node" --version)"

if [[ "${ACTUAL_VERSION}" != "v${NODE_VERSION}" ]]; then
  echo "[install] Unexpected Node.js version: ${ACTUAL_VERSION}" >&2
  exit 1
fi

for executable in node npm npx; do
  ln -sfn \
    "${INSTALL_DIR}/bin/${executable}" \
    "/usr/local/bin/${executable}"
done

log "Node.js: $("${INSTALL_DIR}/bin/node" --version)"
log "npm: $("${INSTALL_DIR}/bin/npm" --version)"
log "Installation completed successfully."
