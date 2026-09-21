import threading
from typing import Callable, Optional

import rclpy
from rclpy.node import Node

from aimdk_msgs.msg import EventProbeInfoArray


MC_TOPIC = "/aima/internal/event/probe/soc0/mc"
MC_EVENT_ID = 5004
MC_EVENT_NAME = "MC运动状态"


class MCStateCollector(Node):
    """
    读取机器人 MC 当前行动状态。

    数据来源：
        /aima/internal/event/probe/soc0/mc

    只关注：
        event_id = 5004
        event_name = MC运动状态
        attr key = mc_action
        attr type = 2
        attr value_string = 当前行动状态
    """

    def __init__(
        self,
        on_state_change: Optional[Callable[[str], None]] = None,
    ):
        super().__init__("robot_platform_mc_agent")

        self._on_state_change = on_state_change

        self._current_state: Optional[str] = None

        self._subscription = self.create_subscription(
            EventProbeInfoArray,
            MC_TOPIC,
            self._on_event,
            10,
        )

        self.get_logger().info(
            f"MC collector started: {MC_TOPIC}"
        )

    @property
    def current_state(self) -> Optional[str]:
        """
        获取当前 MC 行动状态。
        """
        return self._current_state

    def _on_event(self, message: EventProbeInfoArray):
        """
        处理 MC EventProbeInfoArray。
        """

        for event in message.list:

            # 只关注 MC 运动状态事件
            if event.event_id != MC_EVENT_ID:
                continue

            if event.event_name != MC_EVENT_NAME:
                continue

            mc_action = self._extract_mc_action(event)

            if not mc_action:
                continue

            # 第一次获取状态
            if self._current_state is None:

                self._current_state = mc_action

                self.get_logger().info(
                    f"[MC] Current state: {mc_action}"
                )

                if self._on_state_change:
                    self._on_state_change(mc_action)

                continue

            # 状态发生变化
            if mc_action != self._current_state:

                old_state = self._current_state

                self._current_state = mc_action

                self.get_logger().info(
                    f"[MC] State changed: "
                    f"{old_state} -> {mc_action}"
                )

                if self._on_state_change:
                    self._on_state_change(mc_action)

    @staticmethod
    def _extract_mc_action(event) -> Optional[str]:
        """
        从 MC 事件中提取：

            key = mc_action
            type = 2
            value_string

        """

        for attr in event.attrs:

            if attr.key != "mc_action":
                continue

            # EventProbeAttr:
            # EA_TYPE_STRING = 2
            if attr.type != 2:
                continue

            value = attr.value_string.strip()

            if value:
                return value

        return None


def start_mc_collector(
    on_state_change: Optional[Callable[[str], None]] = None,
):
    """
    启动 MC ROS 2 Collector。

    返回：
        collector
        ros_thread
    """

    rclpy.init()

    collector = MCStateCollector(
        on_state_change=on_state_change,
    )

    ros_thread = threading.Thread(
        target=rclpy.spin,
        args=(collector,),
        daemon=True,
    )

    ros_thread.start()

    return collector, ros_thread