#!/bin/bash

set -e

# ============================================================
# Robot Platform Agent
# One-click installer / updater
# ============================================================

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

GITHUB_OWNER="InahoNeko"
GITHUB_REPO="robot-platform-agent"

APP_NAME="robot-platform-agent"

INSTALL_ROOT="/agibot/flag/agent"
VERSIONS_DIR="${INSTALL_ROOT}/versions"
CURRENT_LINK="${INSTALL_ROOT}/current"
CONFIG_DIR="${INSTALL_ROOT}/config"
DATA_DIR="${INSTALL_ROOT}/data"
BACKUP_DIR="${INSTALL_ROOT}/backup"

SERVICE_NAME="robot-platform-agent"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

RELEASES_API_URL="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases"

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

if ! command -v python3 >/dev/null 2>&1; then
    error "python3 is required."
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
mkdir -p "${DATA_DIR}"
mkdir -p "${BACKUP_DIR}"


# ============================================================
# Get GitHub Releases
# ============================================================

log "Checking GitHub Releases..."

RELEASES_JSON="${TEMP_DIR}/releases.json"

if ! curl -fsSL \
    --retry 3 \
    --connect-timeout 10 \
    --max-time 30 \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${RELEASES_API_URL}" \
    -o "${RELEASES_JSON}"; then

    error "Failed to query GitHub Releases."
    error "URL: ${RELEASES_API_URL}"
    exit 1
fi


# ============================================================
# Validate GitHub API response
# ============================================================

if ! python3 - "${RELEASES_JSON}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as file:
    data = json.load(file)

if not isinstance(data, list):
    raise SystemExit(1)
PY
then
    error "Invalid GitHub Releases response."
    exit 1
fi


# ============================================================
# Find latest stable release
# ============================================================

LATEST_RELEASE_INFO="$(
    python3 - "${RELEASES_JSON}" <<'PY'
import json
import sys
import re


def version_key(tag):
    """
    Convert v1.2.3 into a sortable tuple.
    """

    value = tag.strip()

    if value.startswith(("v", "V")):
        value = value[1:]

    match = re.match(
        r"^(\d+)\.(\d+)\.(\d+)$",
        value,
    )

    if not match:
        return None

    return tuple(
        int(part)
        for part in match.groups()
    )


with open(sys.argv[1], "r", encoding="utf-8") as file:
    releases = json.load(file)

candidates = []

for release in releases:

    if release.get("draft"):
        continue

    if release.get("prerelease"):
        continue

    tag_name = release.get("tag_name")

    if not tag_name:
        continue

    version = version_key(tag_name)

    if version is None:
        continue

    candidates.append(
        (
            version,
            tag_name,
            release,
        )
    )


if not candidates:
    raise SystemExit(1)


candidates.sort(
    key=lambda item: item[0],
    reverse=True,
)

version, tag_name, release = candidates[0]

print(tag_name)
print(release.get("id", ""))
PY
)"

if [ -z "${LATEST_RELEASE_INFO}" ]; then
    error "No stable semantic-version GitHub Release found."
    error "Expected release tag format: v0.1.0"
    exit 1
fi

LATEST_TAG="$(echo "${LATEST_RELEASE_INFO}" | sed -n '1p')"
LATEST_RELEASE_ID="$(echo "${LATEST_RELEASE_INFO}" | sed -n '2p')"

LATEST_VERSION="${LATEST_TAG#v}"

log "Latest stable release: ${LATEST_TAG}"


# ============================================================
# Get release information for selected version
# ============================================================

RELEASE_JSON="${TEMP_DIR}/release.json"

if ! python3 - "${RELEASES_JSON}" "${LATEST_TAG}" "${RELEASE_JSON}" <<'PY'
import json
import sys

releases_file = sys.argv[1]
tag_name = sys.argv[2]
output_file = sys.argv[3]

with open(releases_file, "r", encoding="utf-8") as file:
    releases = json.load(file)

for release in releases:

    if release.get("tag_name") != tag_name:
        continue

    if release.get("draft"):
        continue

    if release.get("prerelease"):
        continue

    with open(
        output_file,
        "w",
        encoding="utf-8",
    ) as output:
        json.dump(
            release,
            output,
            ensure_ascii=False,
            indent=2,
        )

    raise SystemExit(0)

raise SystemExit(1)
PY
then
    error "Unable to locate selected release: ${LATEST_TAG}"
    exit 1
fi


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

ASSET_INFO="$(
    python3 - "${RELEASE_JSON}" "${PACKAGE_NAME}" "${CHECKSUM_NAME}" <<'PY'
import json
import sys

release_file = sys.argv[1]
package_name = sys.argv[2]
checksum_name = sys.argv[3]

with open(
    release_file,
    "r",
    encoding="utf-8",
) as file:
    release = json.load(file)

package_url = ""
checksum_url = ""

for asset in release.get("assets", []):

    name = asset.get("name", "")
    url = asset.get("browser_download_url", "")

    if name == package_name:
        package_url = url

    elif name == checksum_name:
        checksum_url = url

print(package_url)
print(checksum_url)
PY
)"

PACKAGE_URL="$(echo "${ASSET_INFO}" | sed -n '1p')"
CHECKSUM_URL="$(echo "${ASSET_INFO}" | sed -n '2p')"

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

ok "Release assets found."


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
    --max-time 300 \
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
    --max-time 60 \
    "${CHECKSUM_URL}" \
    -o "${CHECKSUM_FILE}"

ok "Checksum downloaded."


# ============================================================
# Verify SHA256
# ============================================================

log "Verifying package integrity..."

EXPECTED_CHECKSUM="$(
    awk 'NF {print $1; exit}' "${CHECKSUM_FILE}"
)"

ACTUAL_CHECKSUM="$(
    sha256sum "${PACKAGE_FILE}" |
    awk '{print $1}'
)"

if [ -z "${EXPECTED_CHECKSUM}" ]; then
    error "Invalid SHA256 file."
    exit 1
fi

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
    log "Removing existing version directory..."
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


# ============================================================
# Verify required files
# ============================================================

if [ ! -f "${NEW_VERSION_DIR}/main.py" ]; then
    error "main.py not found in package."
    rm -rf "${NEW_VERSION_DIR}"
    exit 1
fi

if [ ! -f "${NEW_VERSION_DIR}/mc.py" ]; then
    error "mc.py not found in package."
    rm -rf "${NEW_VERSION_DIR}"
    exit 1
fi

if [ ! -f "${NEW_VERSION_DIR}/event_store.py" ]; then
    error "event_store.py not found in package."
    rm -rf "${NEW_VERSION_DIR}"
    exit 1
fi

if [ ! -f "${NEW_VERSION_DIR}/start.sh" ]; then
    error "start.sh not found in package."
    rm -rf "${NEW_VERSION_DIR}"
    exit 1
fi

chmod +x "${NEW_VERSION_DIR}/start.sh"

ok "Agent package verified."


# ============================================================
# Preserve config
# ============================================================

if [ ! -f "${CONFIG_DIR}/config.json" ]; then

    if [ -f "${NEW_VERSION_DIR}/config.json" ]; then

        cp \
            "${NEW_VERSION_DIR}/config.json" \
            "${CONFIG_DIR}/config.json"

        ok "Initial configuration installed."

    else

        warn "No config.json found in package."
        warn "Please create:"
        warn "${CONFIG_DIR}/config.json"

    fi

else

    log "Existing configuration preserved."

fi


# ============================================================
# Preserve offline database
# ============================================================

if [ -f "${DATA_DIR}/offline.db" ]; then
    log "Existing offline database preserved."
fi


# ============================================================
# Install systemd service
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

if ! systemctl start "${SERVICE_NAME}"; then
    warn "systemctl start returned an error."
fi


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

echo
warn "Collecting recent Agent logs..."
echo

journalctl \
    -u "${SERVICE_NAME}" \
    -n 50 \
    --no-pager

echo


# ============================================================
# Rollback
# ============================================================

if [ -n "${OLD_VERSION}" ] &&
   [ -d "${VERSIONS_DIR}/${OLD_VERSION}" ]; then

    echo
    warn "Rolling back to ${OLD_VERSION}..."

    systemctl stop "${SERVICE_NAME}" || true

    ln -sfn \
        "${VERSIONS_DIR}/${OLD_VERSION}" \
        "${CURRENT_LINK}"

    if systemctl start "${SERVICE_NAME}"; then

        sleep 3

        if systemctl is-active --quiet "${SERVICE_NAME}"; then

            ok "Rollback successful."
            warn "Restored Agent ${OLD_VERSION}."

        else

            error "Rollback Agent is not running."

        fi

    else

        error "Failed to start rollback Agent."

    fi

else

    warn "No previous version available."
    error "Agent is not running."

fi


# ============================================================
# Final error
# ============================================================

echo
echo "============================================================"
echo " Installation failed"
echo "============================================================"
echo
echo "Current version : ${LATEST_VERSION}"
echo "Previous version: ${OLD_VERSION:-none}"
echo
echo "Check logs:"
echo "  journalctl -u ${SERVICE_NAME} -n 100 --no-pager"
echo
echo "============================================================"
echo

exit 1

