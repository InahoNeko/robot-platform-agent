#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_ROOT="/agibot/flag/agent"
CONFIG_FILE="${INSTALL_ROOT}/config/config.json"


echo "======================================"
echo " Robot Platform Agent"
echo "======================================"

echo "[INFO] Agent directory:"
echo "       ${SCRIPT_DIR}"

echo "[INFO] Config:"
echo "       ${CONFIG_FILE}"


# ============================================================
# ROS 2 Humble
# ============================================================

if [ -f /opt/ros/humble/setup.bash ]; then
    source /opt/ros/humble/setup.bash
else
    echo "[ERROR] ROS 2 Humble not found."
    exit 1
fi


# ============================================================
# Agibot common environment
# ============================================================

export AMENT_PREFIX_PATH="/agibot/software/common:/opt/ros/humble"

export PYTHONPATH="/agibot/software/common/local/lib/python3.10/dist-packages:/opt/ros/humble/local/lib/python3.10/dist-packages:/opt/ros/humble/lib/python3.10/site-packages:${PYTHONPATH}"

export LD_LIBRARY_PATH="/agibot/software/common/lib:/agibot/software/common/bin:/opt/ros/humble/lib/aarch64-linux-gnu:/opt/ros/humble/lib:${LD_LIBRARY_PATH}"


# ============================================================
# Python
# ============================================================

echo "[INFO] Python:"
python3 --version


# ============================================================
# ROS dependencies
# ============================================================

python3 -c "import rclpy" 2>/dev/null || {
    echo "[ERROR] rclpy import failed."
    exit 1
}

python3 -c "from aimdk_msgs.msg import EventProbeInfoArray" 2>/dev/null || {
    echo "[ERROR] aimdk_msgs import failed."
    exit 1
}

echo "[INFO] ROS environment OK."


# ============================================================
# Configuration
# ============================================================

if [ ! -f "${CONFIG_FILE}" ]; then
    echo "[ERROR] Config file not found:"
    echo "        ${CONFIG_FILE}"
    exit 1
fi


# ============================================================
# Start Agent
# ============================================================

cd "${SCRIPT_DIR}"

echo "[INFO] Starting Robot Platform Agent..."
echo

exec python3 main.py

