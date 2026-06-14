#!/usr/bin/env python3
"""安装 iVox hook 到 Claude/Codex/Pi，已存在则跳过。"""
import json, os, sys

HOOK_SH = os.path.expanduser(sys.argv[1])
IVOX_TS = os.path.expanduser(sys.argv[2])

# ── Claude ──
claude_path = os.path.expanduser("~/.claude/settings.json")
if os.path.isfile(claude_path):
    with open(claude_path) as f:
        d = json.load(f)
    existing = d.get("hooks", {}).get("Stop", [])
    if any("hook-speak.sh" in str(h) for h in existing):
        print("[i] Claude hook 已存在")
    else:
        d.setdefault("hooks", {})["Stop"] = [
            {"hooks": [{"command": f"bash {HOOK_SH} claude", "timeout": 10, "type": "command"}]}
        ]
        with open(claude_path, "w") as f:
            json.dump(d, f, indent=2)
            f.write("\n")
        print("✓  Claude hook")

# ── Codex ──
codex_hooks = os.path.expanduser("~/.codex/hooks.json")
os.makedirs(os.path.dirname(codex_hooks), exist_ok=True)
if not os.path.isfile(codex_hooks):
    with open(codex_hooks, "w") as f:
        f.write("{}\n")

with open(codex_hooks) as f:
    d = json.load(f)
existing = d.get("hooks", {}).get("Stop", [])
if any("hook-speak.sh" in str(h) for h in existing):
    print("[i] Codex hook 已存在")
else:
    d.setdefault("hooks", {})["Stop"] = [
        {"hooks": [{"command": f"bash {HOOK_SH} codex", "timeout": 30, "type": "command"}]}
    ]
    with open(codex_hooks, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    print("✓  Codex hook（首次触发时授权即可）")

# ── Pi ──
pi_path = os.path.expanduser("~/.pi/agent/settings.json")
if os.path.isfile(pi_path):
    with open(pi_path) as f:
        d = json.load(f)
    exts = d.get("extensions", [])
    if any(kw in e.lower() for e in exts for kw in ["iaura", "ivox", "ivoice"]):
        print("[i] Pi extension 已存在")
    else:
        exts = [e for e in exts if not any(x in e.lower() for x in ["ispeak", "ivoice", "ivox", "iaura"])]
        exts.append(IVOX_TS)
        d["extensions"] = exts
        with open(pi_path, "w") as f:
            json.dump(d, f, indent=2)
            f.write("\n")
        print("✓  Pi extension")
