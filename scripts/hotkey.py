#!/usr/bin/env python3
"""用 ESP32 那块常驻硬件键盘，按下 iVox 的热键。

为什么要有它：iVox 的热键走 CGEvent tap，而**有些 app 会丢弃合成来源的键盘事件**
（汽水音乐就丢，音量键毫无反应）。要真测热键，得有真键盘——ESP32-S3 通过 USB
把自己枚举成 macOS 的 HID 键盘，按下去的是**真硬件事件**，跟人手按的一模一样。

键位从 `~/.config/ivox/config.toml` 的 `[hotkeys]` 段读——那是用户改过的那份，
也是 daemon 真正在用的那份。**脚本不另抄一份默认键位**（抄了就会漂：改了一处
另一处不跟着变，是这类小工具最常见的毛病）。

用法:
    python3 scripts/hotkey.py                # 列出所有热键：动作 → 键位
    python3 scripts/hotkey.py skipBucket     # 按下「跳整摞」那个键
    python3 scripts/hotkey.py ctrl+2         # 直接按一组键（不查配置）
    python3 scripts/hotkey.py --list         # 同上第一行

⚠️ 会**真的按键**：测试期间手别放在键盘上，被按下的键会打到当前前台的 App。
"""

from __future__ import annotations

import pathlib
import re
import sys

# 动作名 → 中文说明。**只给人看**（列表里的一行字），不参与任何判断，
# 所以改词不会影响行为；真源仍是 iVox 里的 `HotKeyAction`。
ACTION_LABELS = {
    "translate": "划词翻译",
    "openTerminal": "开终端",
    "openTerminalClaude": "开终端并跑 claude",
    "openTerminalCodex": "开终端并跑 codex",
    "openTerminalPi": "开终端并跑 pi",
    "copyPath": "复制 Finder 选中路径",
    "skipPage": "掀页（掐 + 掀掉当前页）",
    "skipBucket": "掀摞（掐 + 掀掉当前摞）",
    "skipAll": "全掀（停当前 + 清空排队）",
    "voice": "按住说话（长按 150ms 才算，脚本按不出来）",
}

# iVox 的修饰键叫法 → 板子认识的叫法。
# 语音键（右⌘ / 右⌃）不在 chord 词汇里，但板子认 rgui / rctrl，一并映射。
MOD_ALIASES = {
    "cmd": "cmd", "command": "cmd", "⌘": "cmd",
    "ctrl": "ctrl", "control": "ctrl", "⌃": "ctrl",
    "opt": "alt", "option": "alt", "alt": "alt", "⌥": "alt",
    "shift": "shift", "⇧": "shift",
    "rightcmd": "rgui", "rightcommand": "rgui", "rcmd": "rgui",
    "rightctrl": "rctrl", "rightcontrol": "rctrl",
    "rightshift": "rshift", "rightalt": "ralt",
}

CONFIG_PATH = pathlib.Path.home() / ".config" / "ivox" / "config.toml"


def read_hotkeys() -> dict[str, str]:
    """读 config.toml 的 `[hotkeys]` 段：动作 → 键位串。

    只取这一段、只认 `名字 = "值"` 这一种写法——配置文件是人写的，
    遇到看不懂的行就跳过，不猜（猜错了会按出一串意料之外的键）。
    """
    if not CONFIG_PATH.exists():
        return {}
    section = ""
    out: dict[str, str] = {}
    for line in CONFIG_PATH.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            continue
        if section != "hotkeys":
            continue
        m = re.match(r'^([A-Za-z][A-Za-z0-9_]*)\s*=\s*"([^"]*)"', line)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def chord_to_tokens(chord: str) -> list[str]:
    """iVox 的键位串 → 板子认的按键序列。

    例：`ctrl+2` → `["ctrl", "2"]`；`opt+z` → `["alt", "z"]`。
    """
    tokens: list[str] = []
    for part in chord.lower().split("+"):
        part = part.strip()
        if not part:
            continue
        if part in MOD_ALIASES:
            tokens.append(MOD_ALIASES[part])
        else:
            tokens.append(part)   # 主键：字母/数字/esc/f1…板子自己认
    if not tokens:
        raise ValueError(f"键位串是空的：{chord!r}")
    return tokens


def press(chord: str) -> None:
    """按下这组键（真硬件事件）。"""
    try:
        from hid_mcp import device
    except ImportError as e:
        sys.exit(
            f"找不到 hid_mcp（{e}）。它是 esp32-lab 仓里的板子客户端，"
            f"装法：/Users/admin/iCode/services/.venv/bin/python -m pip install -e "
            f"/Users/admin/iCode/esp32-lab/mcp/"
        )
    try:
        device.press_keys(chord_to_tokens(chord))
    except Exception as e:   # 板子不可达 / token 不对 / 队列满
        sys.exit(f"按键失败：{e}")


def main(argv: list[str]) -> int:
    hotkeys = read_hotkeys()
    args = [a for a in argv if a != "--list"]

    if not args:
        print("iVox 热键（来自 ~/.config/ivox/config.toml 的 [hotkeys] 段）：")
        for name, chord in hotkeys.items():
            label = ACTION_LABELS.get(name, "")
            print(f"  {name:<20} {chord:<16} {label}")
        print()
        print("按下其中某个：python3 scripts/hotkey.py <动作名>")
        return 0

    target = args[0]
    if target in hotkeys:
        chord = hotkeys[target]
    else:
        chord = target          # 直接给键位串（ctrl+2 这样的）
    print(f"按下 {target} → {chord}")
    press(chord)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
