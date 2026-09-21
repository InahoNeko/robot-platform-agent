#!/bin/bash

set -e

# ============================================================
# Robot Platform Agent
# One-click installer / updater
# ============================================================

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

GITHUB_OWNER="YOUR_GITHUB_USERNAME"
GITHUB_REPO="robot-platform-agent"

APP_NAME="robot-platform-agent"

INSTALL_ROOT="/agibot/flag/agent"
VERSIONS_DIR="${INSTALL_ROOT}/versions"
CURRENT_LINK="${INSTALL_ROOT}/current"
CONFIG_DIR="${INSTALL_ROOT}/config"
BACKUP_DIR="${INSTALL_ROOT}/backup"

SERVICE_NAME="robot-platform-agent"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

API_URL="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest"

TEMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "${TEMP_DIR}"
}

trap cleanup EXIT


# ============================================================
# Helper
# ============================================================

log() {
    echo "[INFO] $1"
}

ok() {
    echo "[OK] $1"
}

warn() {
    echo "[WARN] $1"
}

error() {
    echo "[ERROR] $1"
}


# ============================================================
# Root check
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    error "Installer must be run as root."
    echo
    echo "Usage:"
    echo
    echo "curl -fsSL https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/main/install.sh | sudo bash"
    echo
    exit 1
fi


# ============================================================
# Header
# ============================================================

echo
echo "============================================================"
echo " Robot Platform Agent Installer"
echo "============================================================"
echo


# ============================================================
# Check dependencies
# ============================================================

log "Checking dependencies..."

if ! command -v curl >/dev/null 2>&1; then
    error "curl is required."
    exit 1
fi

if ! command -v tar >/dev/null 2>&1; then
    error "tar is required."
    exit 1
fi

if ! command -v sha256sum >/dev/null 2>&1; then
    error "sha256sum is required."
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    error "systemctl is required."
    exit 1
fi

ok "Dependencies available."


# ============================================================
# Check ROS 2 Humble
# ============================================================

if [ ! -d "/opt/ros/humble" ]; then
    error "ROS 2 Humble was not found."
    error "This Agent is designed for the robot environment."
    exit 1
fi

ok "ROS 2 Humble found."


# ============================================================
# Create directories
# ============================================================

mkdir -p "${INSTALL_ROOT}"
mkdir -p "${VERSIONS_DIR}"
mkdir -p "${CONFIG_DIR}"
mkdir -p "${BACKUP_DIR}"


# ============================================================
# Get latest GitHub release
# ============================================================

log "Checking latest Agent release..."

RELEASE_JSON="${TEMP_DIR}/release.json"

curl -fsSL \
    --retry 3 \
    --connect-timeout 10 \
    "${API_URL}" \
    -o "${RELEASE_JSON}"

LATEST_TAG="$(
    grep '"tag_name":' "${RELEASE_JSON}" |
    head -n 1 |
    sed -E 's/.*"tag_name": "([^"]+)".*/\1/'
)"

if [ -z "${LATEST_TAG}" ]; then
    error "Unable to determine latest release."
    exit 1
fi

LATEST_VERSION="${LATEST_TAG#v}"

log "Latest release: ${LATEST_TAG}"


# ============================================================
# Determine current version
# ============================================================

CURRENT_VERSION=""

if [ -L "${CURRENT_LINK}" ]; then
    CURRENT_TARGET="$(readlink "${CURRENT_LINK}")"
    CURRENT_VERSION="$(basename "${CURRENT_TARGET}")"
fi

if [ -n "${CURRENT_VERSION}" ]; then
    log "Current version: ${CURRENT_VERSION}"
else
    log "Current version: not installed"
fi


# ============================================================
# Already latest
# ============================================================

if [ "${CURRENT_VERSION}" = "${LATEST_VERSION}" ]; then

    echo
    ok "Agent ${LATEST_VERSION} is already installed."
    echo
    echo "Nothing to do."
    echo

    exit 0
fi


# ============================================================
# Find release assets
# ============================================================

PACKAGE_NAME="${APP_NAME}-v${LATEST_VERSION}.tar.gz"
CHECKSUM_NAME="${PACKAGE_NAME}.sha256"

PACKAGE_URL="$(
    grep '"browser_download_url":' "${RELEASE_JSON}" |
    grep "${PACKAGE_NAME}" |
    head -n 1 |
    sed -E 's/.*"browser_download_url": "([^"]+)".*/\1/'
)"

CHECKSUM_URL="$(
    grep '"browser_download_url":' "${RELEASE_JSON}" |
    grep "${CHECKSUM_NAME}" |
    head -n 1 |
    sed -E 's/.*"browser_download_url": "([^"]+)".*/\1/'
)"

if [ -z "${PACKAGE_URL}" ]; then
    error "Agent package not found in release."
    error "Expected: ${PACKAGE_NAME}"
    exit 1
fi

if [ -z "${CHECKSUM_URL}" ]; then
    error "SHA256 file not found in release."
    error "Expected: ${CHECKSUM_NAME}"
    exit 1
fi


# ============================================================
# Download package
# ============================================================

PACKAGE_FILE="${TEMP_DIR}/${PACKAGE_NAME}"
CHECKSUM_FILE="${TEMP_DIR}/${CHECKSUM_NAME}"

echo
log "Downloading ${PACKAGE_NAME}..."

curl -fL \
    --retry 3 \
    --connect-timeout 10 \
    "${PACKAGE_URL}" \
    -o "${PACKAGE_FILE}"

ok "Package downloaded."


# ============================================================
# Download checksum
# ============================================================

log "Downloading SHA256 checksum..."

curl -fL \
    --retry 3 \
    --connect-timeout 10 \
    "${CHECKSUM_URL}" \
    -o "${CHECKSUM_FILE}"

ok "Checksum downloaded."


# ============================================================
# Verify SHA256
# ============================================================

log "Verifying package integrity..."

cd "${TEMP_DIR}"

EXPECTED_CHECKSUM="$(
    awk '{print $1}' "${CHECKSUM_FILE}"
)"

ACTUAL_CHECKSUM="$(
    sha256sum "${PACKAGE_FILE}" |
    awk '{print $1}'
)"

if [ "${EXPECTED_CHECKSUM}" != "${ACTUAL_CHECKSUM}" ]; then
    error "SHA256 verification failed."
    error "Expected: ${EXPECTED_CHECKSUM}"
    error "Actual:   ${ACTUAL_CHECKSUM}"
    exit 1
fi

ok "SHA256 verification passed."


# ============================================================
# Prepare new version
# ============================================================

NEW_VERSION_DIR="${VERSIONS_DIR}/${LATEST_VERSION}"

if [ -d "${NEW_VERSION_DIR}" ]; then
    log "Removing incomplete existing version..."
    rm -rf "${NEW_VERSION_DIR}"
fi

mkdir -p "${NEW_VERSION_DIR}"


# ============================================================
# Extract new version
# ============================================================

log "Installing version ${LATEST_VERSION}..."

tar -xzf \
    "${PACKAGE_FILE}" \
    -C "${NEW_VERSION_DIR}" \
    --strip-components=1

chmod +x "${NEW_VERSION_DIR}/start.sh"


# ============================================================
# Verify required files
# ============================================================

if [ ! -f "${NEW_VERSION_DIR}/main.py" ]; then
    error "main.py not found."
    rm -rf "${NEW_VERSION_DIR}"
    exit 1
fi

if [ ! -f "${NEW_VERSION_DIR}/start.sh" ]; then
    error "start.sh not found."
    rm -rf "${NEW_VERSION_DIR}"
    exit 1
fi

ok "Agent package verified."


# ============================================================
# Preserve config
# ============================================================

# First installation:
# Copy config.json from package to persistent config directory.

if [ ! -f "${CONFIG_DIR}/config.json" ]; then

    if [ -f "${NEW_VERSION_DIR}/config.json" ]; then
        cp \
            "${NEW_VERSION_DIR}/config.json" \
            "${CONFIG_DIR}/config.json"

        ok "Initial configuration installed."
    else
        warn "No config.json found in package."
    fi

fi


# ============================================================
# Prepare systemd service
# ============================================================

log "Installing systemd service..."

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Robot Platform Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

WorkingDirectory=${INSTALL_ROOT}/current

ExecStart=/bin/bash ${INSTALL_ROOT}/current/start.sh

Restart=always
RestartSec=5

User=root

Environment=PYTHONUNBUFFERED=1

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

systemctl enable "${SERVICE_NAME}" >/dev/null

ok "systemd service ready."


# ============================================================
# Save old version
# ============================================================

OLD_VERSION="${CURRENT_VERSION}"


# ============================================================
# Stop current Agent
# ============================================================

if systemctl is-active --quiet "${SERVICE_NAME}"; then

    log "Stopping current Agent..."

    systemctl stop "${SERVICE_NAME}"

    ok "Current Agent stopped."

fi


# ============================================================
# Switch current symlink
# ============================================================

log "Switching Agent version..."

ln -sfn \
    "${NEW_VERSION_DIR}" \
    "${CURRENT_LINK}"

ok "Current version -> ${LATEST_VERSION}"


# ============================================================
# Start new Agent
# ============================================================

log "Starting Agent ${LATEST_VERSION}..."

systemctl start "${SERVICE_NAME}"


# ============================================================
# Health check
# ============================================================

log "Checking Agent health..."

HEALTH_OK=false

for i in $(seq 1 10); do

    sleep 1

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        HEALTH_OK=true
        break
    fi

done


# ============================================================
# Successful installation
# ============================================================

if [ "${HEALTH_OK}" = true ]; then

    echo
    echo "============================================================"
    echo " Installation successful"
    echo "============================================================"
    echo
    echo "Agent version : ${LATEST_VERSION}"
    echo "Install path  : ${NEW_VERSION_DIR}"
    echo "Current       : ${CURRENT_LINK}"
    echo
    echo "Service:"
    echo "  systemctl status ${SERVICE_NAME}"
    echo
    echo "Logs:"
    echo "  journalctl -u ${SERVICE_NAME} -f"
    echo
    echo "============================================================"
    echo

    exit 0

fi


# ============================================================
# New version failed
# ============================================================

error "Agent ${LATEST_VERSION} failed to start."

if [ -n "${OLD_VERSION}" ] &&
   [ -d "${VERSIONS_DIR}/${OLD_VERSION}" ]; then

    echo
    warn "Rolling back to ${OLD_VERSION}..."

    systemctl stop "${SERVICE_NAME}" || true

    ln -sfn \
        "${VERSIONS_DIR}/${OLD_VERSION}" \
        "${CURRENT_LINK}"

    systemctl start "${SERVICE_NAME}"

    sleep 3

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        ok "Rollback successful."
        warn "Restored Agent ${OLD_VERSION}."
    else
        error "Rollback failed."
    fi

else

    warn "No previous version available."
    error "Agent is not running."

fi


# ============================================================
# Error information
# ============================================================

echo
echo "Recent Agent logs:"
echo

journalctl \
    -u "${SERVICE_NAME}" \
    -n 50 \
    --no-pager

echo

exit 1

