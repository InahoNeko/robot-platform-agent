#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_ROOT}"

APP_NAME="robot-platform-agent"

VERSION="$(cat VERSION | tr -d '[:space:]')"

if [ -z "${VERSION}" ]; then
    echo "[ERROR] VERSION is empty."
    exit 1
fi

PACKAGE_NAME="${APP_NAME}-v${VERSION}.tar.gz"

DIST_DIR="${PROJECT_ROOT}/dist"

rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

echo "======================================"
echo " Build Robot Platform Agent"
echo "======================================"
echo
echo "Version: ${VERSION}"
echo

# ------------------------------------------------------------
# Check files
# ------------------------------------------------------------

test -f agent/main.py
test -f agent/mc.py
test -f agent/start.sh
test -f agent/config.json

# ------------------------------------------------------------
# Build temporary package directory
# ------------------------------------------------------------

BUILD_DIR="$(mktemp -d)"

mkdir -p "${BUILD_DIR}/${APP_NAME}"

cp agent/main.py \
    "${BUILD_DIR}/${APP_NAME}/"

cp agent/mc.py \
    "${BUILD_DIR}/${APP_NAME}/"

cp agent/start.sh \
    "${BUILD_DIR}/${APP_NAME}/"

cp agent/config.json \
    "${BUILD_DIR}/${APP_NAME}/"

chmod +x \
    "${BUILD_DIR}/${APP_NAME}/start.sh"

# ------------------------------------------------------------
# Create package
# ------------------------------------------------------------

tar -czf \
    "${DIST_DIR}/${PACKAGE_NAME}" \
    -C "${BUILD_DIR}" \
    "${APP_NAME}"

# ------------------------------------------------------------
# SHA256
# ------------------------------------------------------------

cd "${DIST_DIR}"

sha256sum \
    "${PACKAGE_NAME}" \
    > "${PACKAGE_NAME}.sha256"

rm -rf "${BUILD_DIR}"

echo
echo "[OK] Build completed."
echo
echo "Files:"
echo
ls -lh "${DIST_DIR}"
echo