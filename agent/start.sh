#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_ROOT="/agibot/data/var/agent"
CONFIG_FILE="${INSTALL_ROOT}/config/config.json"


echo "======================================"
echo " Robot Platform Agent"
echo "======================================"

echo "[INFO] Agent directory:"
echo "       ${SCRIPT_DIR}"

echo "[INFO] Config:"
echo "       ${CONFIG_FILE}"


# ============================================================
# ROS 2 distribution
# ============================================================
#
# 同时兼容：
#   humble  机器人环境（Ubuntu 22.04 / Python 3.10）
#   jazzy   新机器    （Ubuntu 24.04 / Python 3.12）
#
# 选择顺序：
#   1. 环境变量 ROS_DISTRO（当 /opt/ros/<distro> 存在时）
#   2. /opt/ros/jazzy
#   3. /opt/ros/humble
#   4. /opt/ros 下任意已安装的发行版
#

ROS_DISTRO_NAME=""

if [ -n "${ROS_DISTRO:-}" ] &&
   [ -f "/opt/ros/${ROS_DISTRO}/setup.bash" ]; then

    ROS_DISTRO_NAME="${ROS_DISTRO}"

else

    for candidate in jazzy humble; do

        if [ -f "/opt/ros/${candidate}/setup.bash" ]; then
            ROS_DISTRO_NAME="${candidate}"
            break
        fi

    done

fi


if [ -z "${ROS_DISTRO_NAME}" ]; then
    ROS_DISTRO_NAME="$(
        ls -1 /opt/ros 2>/dev/null | head -n 1
    )"
fi


ROS_SETUP="/opt/ros/${ROS_DISTRO_NAME}/setup.bash"

if [ -z "${ROS_DISTRO_NAME}" ] || [ ! -f "${ROS_SETUP}" ]; then

    echo "[ERROR] No ROS 2 installation found in /opt/ros."
    echo "        Install ROS 2 Humble or Jazzy,"
    echo "        or set ROS_DISTRO to the desired distribution."
    exit 1

fi


echo "[INFO] ROS 2 distribution:"
echo "       ${ROS_DISTRO_NAME}"

# shellcheck disable=SC1090
source "${ROS_SETUP}"


# ============================================================
# ROS Python version
# ============================================================
#
# 从 ROS 安装目录推导 Python 版本，避免写死：
#   humble -> python3.10
#   jazzy  -> python3.12
#

ROS_PYTHON_VERSION="$(
    ls -d /opt/ros/"${ROS_DISTRO_NAME}"/lib/python3.* 2>/dev/null |
        sed -n '1s#.*/python##p'
)"

if [ -z "${ROS_PYTHON_VERSION}" ]; then
    ROS_PYTHON_VERSION="$(
        python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])'
    )"
fi

echo "[INFO] ROS Python version:"
echo "       ${ROS_PYTHON_VERSION}"


# ============================================================
# Agibot common environment (robot only)
# ============================================================
#
# /agibot/software/common 只存在于机器人上。
# 普通 Jazzy 开发机没有该目录，此时直接使用 ROS 默认环境。
#

AGIBOT_COMMON="/agibot/software/common"

if [ -d "${AGIBOT_COMMON}" ]; then

    export AMENT_PREFIX_PATH="${AGIBOT_COMMON}:/opt/ros/${ROS_DISTRO_NAME}"

    export PYTHONPATH="${AGIBOT_COMMON}/local/lib/python${ROS_PYTHON_VERSION}/dist-packages:/opt/ros/${ROS_DISTRO_NAME}/local/lib/python${ROS_PYTHON_VERSION}/dist-packages:/opt/ros/${ROS_DISTRO_NAME}/lib/python${ROS_PYTHON_VERSION}/site-packages:${PYTHONPATH}"

    export LD_LIBRARY_PATH="${AGIBOT_COMMON}/lib:${AGIBOT_COMMON}/bin:/opt/ros/${ROS_DISTRO_NAME}/lib/aarch64-linux-gnu:/opt/ros/${ROS_DISTRO_NAME}/lib:${LD_LIBRARY_PATH}"

    echo "[INFO] Agibot common environment applied."

else

    echo "[INFO] Agibot common environment not found;"
    echo "       using default ROS 2 ${ROS_DISTRO_NAME} environment."

fi


# ============================================================
# Python
# ============================================================

echo "[INFO] Python:"
python3 --version


# ============================================================
# ROS dependencies
# ============================================================

python3 -c "import rclpy" 2>/dev/null || {
    echo "[ERROR] rclpy import failed for ROS 2 ${ROS_DISTRO_NAME}."
    exit 1
}

if ! python3 -c "from aimdk_msgs.srv import GetMcAction" 2>/dev/null; then
    echo "[WARN] aimdk_msgs not available;"
    echo "       MC motion-state collection will be disabled."
fi

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
