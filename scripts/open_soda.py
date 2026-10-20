#!/usr/bin/env python3
"""打开汽水音乐 —— 走 ESP32 真实 HID 事件。

为什么不用 `open -a`：汽水音乐的命令行启动会「主进程起来就退」，无窗口无日志；
只有像人那样点（聚焦搜索 → 打字 → 回车）才起得来。
为什么不用 CGEvent 合成键：汽水音乐会丢弃合成来源的键盘事件（实测音量键毫无反应）。

脚本只做这四步，成没成由人自己看：Cmd+Space → 打字 → 等 2 秒 → 回车。

用法:
    python3 scripts/open_soda.py
"""

import sys
import time

sys.path.insert(0, "/Users/admin/iCode/esp32-hid-lab/mcp")
from hid_mcp import device  # noqa: E402

SEARCH = "qishuiyinyue"


def main() -> int:
    device.press_keys(["cmd", "space"])
    device.type_text(SEARCH)
    time.sleep(2)
    device.press_keys(["enter"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
