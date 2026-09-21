import json
import socket
import time
from datetime import datetime, timezone
from pathlib import Path
from threading import Lock, Thread

import requests

from event_store import EventStore
from mc import start_mc_collector


# ============================================================
# Paths
# ============================================================

CONFIG_FILE = Path(
    "/agibot/flag/agent/config/config.json"
)

SN_FILE = Path(
    "/agibot/data/info/sn"
)

SKU_FILE = Path(
    "/agibot/data/info/sku"
)

VERSION_FILE = Path(
    "/agibot/software/firmware_version"
)


# ============================================================
# Config
# ============================================================

def load_config():

    if not CONFIG_FILE.exists():
        raise FileNotFoundError(
            f"Config file not found: {CONFIG_FILE}"
        )

    with CONFIG_FILE.open(
        "r",
        encoding="utf-8",
    ) as file:
        return json.load(file)


CONFIG = load_config()

BACKEND_URL = CONFIG["backend_url"].rstrip("/")

HEARTBEAT_INTERVAL = CONFIG.get(
    "heartbeat_interval",
    1,
)

SYNC_INTERVAL = CONFIG.get(
    "sync_interval",
    2,
)

SYNC_BATCH_SIZE = CONFIG.get(
    "sync_batch_size",
    100,
)


# ============================================================
# Robot Identity
# ============================================================

def get_robot_sn() -> str:

    try:

        sn = SN_FILE.read_text(
            encoding="utf-8"
        ).strip()

    except FileNotFoundError:
        return "SN不存在"

    except OSError:
        return "读取SN失败"

    if not sn:
        return "SN文件为空"

    return sn


def get_robot_sku() -> str:

    try:

        sku = SKU_FILE.read_text(
            encoding="utf-8"
        ).strip()

    except FileNotFoundError:
        return "SKU不存在"

    except OSError:
        return "读取SKU失败"

    if not sku:
        return "SKU文件为空"

    return sku


def get_robot_version() -> str:

    try:

        version = VERSION_FILE.read_text(
            encoding="utf-8"
        ).strip()

    except FileNotFoundError:
        return "版本不存在"

    except OSError:
        return "读取版本失败"

    if not version:
        return "版本文件为空"

    return version


ROBOT_SN = get_robot_sn()
ROBOT_SKU = get_robot_sku()
ROBOT_VERSION = get_robot_version()


# ============================================================
# Runtime State
# ============================================================

_runtime_state = "unknown"

_runtime_state_lock = Lock()


def get_runtime_state() -> str:

    with _runtime_state_lock:
        return _runtime_state


def now_iso() -> str:
    """
    使用 UTC 时间保存事件时间。

    例如：
    2026-09-21T02:30:15.123456+00:00
    """

    return datetime.now(
        timezone.utc
    ).isoformat()


def on_mc_state_change(state: str):

    global _runtime_state

    with _runtime_state_lock:
        _runtime_state = state

    print(
        f"[MC] Current action state: {state}"
    )


# ============================================================
# Network
# ============================================================

def get_local_ip() -> str:

    sock = socket.socket(
        socket.AF_INET,
        socket.SOCK_DGRAM,
    )

    try:

        sock.connect(
            ("8.8.8.8", 80)
        )

        return sock.getsockname()[0]

    except OSError:

        return "127.0.0.1"

    finally:

        sock.close()


def get_mac() -> str:
    """
    从 Linux /sys/class/net/<iface>/address
    读取真实网卡 MAC 地址。

    优先选择 operstate=up 的物理网卡，
    排除常见虚拟网卡。
    """

    net_dir = Path("/sys/class/net")

    excluded_prefixes = (
        "lo",
        "docker",
        "veth",
        "br-",
        "virbr",
    )

    if not net_dir.exists():
        return "MAC读取失败"

    interfaces = sorted(net_dir.iterdir())

    # 第一轮：优先选择处于 UP 状态的网卡
    for interface in interfaces:
        name = interface.name

        if any(
            name == prefix
            or name.startswith(prefix)
            for prefix in excluded_prefixes
        ):
            continue

        operstate_file = interface / "operstate"
        address_file = interface / "address"

        try:
            operstate = operstate_file.read_text(
                encoding="utf-8"
            ).strip().lower()

            if operstate != "up":
                continue

            mac = address_file.read_text(
                encoding="utf-8"
            ).strip().lower()

        except OSError:
            continue

        if (
            mac
            and mac != "00:00:00:00:00:00"
            and len(mac.split(":")) == 6
        ):
            return mac

    # 第二轮：如果没有 UP 网卡，则尝试其他符合条件的网卡
    for interface in interfaces:
        name = interface.name

        if any(
            name == prefix
            or name.startswith(prefix)
            for prefix in excluded_prefixes
        ):
            continue

        address_file = interface / "address"

        try:
            mac = address_file.read_text(
                encoding="utf-8"
            ).strip().lower()
        except OSError:
            continue

        if (
            mac
            and mac != "00:00:00:00:00:00"
            and len(mac.split(":")) == 6
        ):
            return mac

    return "MAC读取失败"


# ============================================================
# Event Store
# ============================================================

event_store = EventStore()


# ============================================================
# Local Event Recording
# ============================================================

def record_heartbeat():

    event_time = now_iso()

    payload = {
        "sn": ROBOT_SN,
        "ip": get_local_ip(),
        "mac": get_mac(),
        "status": "online",
        "runtime_state": get_runtime_state(),
        "version": ROBOT_VERSION,
    }

    event_store.append(
        event_type="heartbeat",
        event_time=event_time,
        payload=payload,
    )


def record_state_change(
    state: str,
):

    event_time = now_iso()

    payload = {
        "sn": ROBOT_SN,
        "state": state,
        "source": "mc_event_probe",
        "event_id": 5004,
    }

    event_store.append(
        event_type="state",
        event_time=event_time,
        payload=payload,
    )

    print(
        f"[LocalStore] State saved: {state}"
    )


# ============================================================
# Backend Registration
# ============================================================

def register():

    data = {
        "sn": ROBOT_SN,
        "sku": ROBOT_SKU,
        "ip": get_local_ip(),
        "mac": get_mac(),
        "version": ROBOT_VERSION,
    }

    response = requests.post(
        f"{BACKEND_URL}/api/robots/register",
        json=data,
        timeout=5,
    )

    response.raise_for_status()

    print(
        "[Register] "
        f"SN={ROBOT_SN} "
        f"SKU={ROBOT_SKU} "
        f"VERSION={ROBOT_VERSION}"
    )


# ============================================================
# Backend Sync
# ============================================================

def sync_events_once() -> bool:
    """
    向后端补传本地事件。

    返回：
        True  = 成功
        False = 后端不可用/同步失败
    """

    events = event_store.get_batch(
        limit=SYNC_BATCH_SIZE
    )

    if not events:
        return True

    data = {
        "sn": ROBOT_SN,
        "events": events,
    }

    try:

        response = requests.post(
            f"{BACKEND_URL}/api/robots/"
            f"{ROBOT_SN}/events/sync",
            json=data,
            timeout=5,
        )

        response.raise_for_status()

        result = response.json()

        acknowledged_id = result.get(
            "acknowledged_id"
        )

        if acknowledged_id is not None:

            event_store.delete_until(
                int(acknowledged_id)
            )

        print(
            "[Sync] "
            f"Uploaded {len(events)} events"
        )

        return True

    except requests.RequestException as exc:

        print(
            "[Sync] Backend unavailable: "
            f"{exc}"
        )

        return False

    except Exception as exc:

        print(
            "[Sync] Unexpected error: "
            f"{exc}"
        )

        return False


def sync_loop():

    print(
        "[Sync] Offline event sync started"
    )

    while True:

        try:

            sync_events_once()

        except Exception as exc:

            print(
                "[Sync] Error: "
                f"{exc}"
            )

        time.sleep(
            SYNC_INTERVAL
        )


# ============================================================
# MC State Callback
# ============================================================

def handle_mc_state_change(
    state: str,
):

    on_mc_state_change(state)

    # 先写本地数据库。
    #
    # 不管 Backend 是否在线，
    # 状态变化都不会丢。
    record_state_change(state)


# ============================================================
# Heartbeat Loop
# ============================================================

def heartbeat_loop():

    print(
        "[Heartbeat] Loop started"
    )

    while True:

        try:

            # 每秒先写本地事件。
            #
            # 后台 Sync 线程负责上传。
            record_heartbeat()

            print(
                "[Heartbeat] "
                f"SN={ROBOT_SN} "
                f"STATE={get_runtime_state()}"
            )

        except Exception as exc:

            print(
                "[Heartbeat] Error: "
                f"{exc}"
            )

        time.sleep(
            HEARTBEAT_INTERVAL
        )


# ============================================================
# Main
# ============================================================

def main():

    print("==============================")
    print("Robot Platform Agent")
    print("==============================")
    print(f"SN: {ROBOT_SN}")
    print(f"SKU: {ROBOT_SKU}")
    print(f"Version: {ROBOT_VERSION}")
    print(f"Backend: {BACKEND_URL}")
    print("==============================")

    # --------------------------------------------------------
    # MC Collector
    # --------------------------------------------------------

    try:

        start_mc_collector(
            on_state_change=handle_mc_state_change
        )

        print(
            "[MC] Collector started"
        )

    except Exception as exc:

        print(
            "[ERROR] "
            f"Failed to start MC collector: {exc}"
        )

        print(
            "Agent will continue without MC state."
        )

    # --------------------------------------------------------
    # Backend registration
    #
    # 注册不是数据采集的一部分。
    # Backend 不在线时不会阻止 Agent 工作。
    # --------------------------------------------------------

    try:

        register()

    except requests.RequestException as exc:

        print(
            "[Register] Backend unavailable: "
            f"{exc}"
        )

    # --------------------------------------------------------
    # Offline sync thread
    # --------------------------------------------------------

    sync_thread = Thread(
        target=sync_loop,
        name="event-sync",
        daemon=True,
    )

    sync_thread.start()

    # --------------------------------------------------------
    # Heartbeat thread
    # --------------------------------------------------------

    heartbeat_thread = Thread(
        target=heartbeat_loop,
        name="heartbeat",
        daemon=True,
    )

    heartbeat_thread.start()

    # --------------------------------------------------------
    # Main thread
    #
    # Agent 本身保持运行。
    # ROS spin 在 mc.py 的独立线程。
    # --------------------------------------------------------

    while True:

        time.sleep(60)


if __name__ == "__main__":
    main()