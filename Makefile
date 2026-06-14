.PHONY: all build deploy init model launchd uninstall sign run clean

RUNTIME    := $(HOME)/.local/share/ivox/runtime
BIN        := $(RUNTIME)/iVox
LAUNCHER   := $(HOME)/.local/bin/ivox
LABEL      := com.user.ivox
PLIST      := $(HOME)/Library/LaunchAgents/com.user.ivox.plist
CONFIG     := $(HOME)/.config/ivox/config.json
HOOK_SH    := $(HOME)/.config/ivox/hook-speak.sh
IVOX_TS    := $(HOME)/.config/ivox/ivox.ts
LOG        := $(HOME)/.config/ivox/daemon.log

# 代码签名 (macOS 要求可执行文件有效签名)
SIGN_HASH  := 4A287668E97BC130AA6D19F4D64799394CAACBAD

# ─── 全流程 ──────────────────────────────────────────
all: init deploy launchd
	@echo "✓  iVox 已就绪"

# ─── 第 1 层：无依赖，可并行 ────────────────────────
init:
	@mkdir -p $(HOME)/.config/ivox
	# config.json
	@if [ ! -f $(CONFIG) ]; then \
		cp Sources/iVox/Resources/config.example.json $(CONFIG); \
		sed -i '' 's|"~|"$(HOME)|g' $(CONFIG); \
		echo "✓  已生成配置: $(CONFIG)"; \
	else \
		echo "[i] 配置已存在: $(CONFIG)"; \
	fi
	# hook 脚本
	@cp Sources/iVox/Resources/hook-speak.sh $(HOOK_SH)
	@chmod 755 $(HOOK_SH)
	@echo "✓  hook: $(HOOK_SH)"
	# Pi extension
	@cp Sources/iVox/Resources/ivox.ts $(IVOX_TS)
	@echo "✓  Pi extension: $(IVOX_TS)"
	# ── Hook 安装（已存在则跳过）──
	@python3 scripts/install-hooks.py "$(HOOK_SH)" "$(IVOX_TS)" 

# ─── 第 2 层：依赖 build ──────────────────────────
build:
	swift build -c release -Xswiftc -Osize

deploy: build
	@mkdir -p $(RUNTIME) $(HOME)/.local/bin
	cp .build/release/iVox $(BIN)
	chmod 755 $(BIN)
	@printf '#!/bin/bash\nexec "%s" "$$@"\n' "$(BIN)" > $(LAUNCHER)
	chmod 755 $(LAUNCHER)
	codesign --force --sign $(SIGN_HASH) $(BIN) 2>/dev/null && echo "✓  签名完成" || echo "⚠️  签名失败"

# ─── 第 3 层：注册 + 启动 daemon ──────────────────
launchd:
	@{ echo '<?xml version="1.0" encoding="UTF-8"?>'; \
	   echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'; \
	   echo '<plist version="1.0"><dict>'; \
	   echo '  <key>Label</key><string>$(LABEL)</string>'; \
	   echo '  <key>ProgramArguments</key><array>'; \
	   echo '    <string>$(LAUNCHER)</string>'; \
	   echo '    <string>serve</string>'; \
	   echo '  </array>'; \
	   echo '  <key>WorkingDirectory</key><string>$(RUNTIME)</string>'; \
	   echo '  <key>RunAtLoad</key><true/>'; \
	   echo '  <key>KeepAlive</key><true/>'; \
	   echo '  <key>StandardOutPath</key><string>$(LOG)</string>'; \
	   echo '  <key>StandardErrorPath</key><string>$(LOG)</string>'; \
	   echo '  <key>EnvironmentVariables</key><dict>'; \
	   echo '    <key>HOME</key><string>$(HOME)</string>'; \
	   echo '  </dict>'; \
	   echo '</dict></plist>'; } > $(PLIST)
	-launchctl bootout gui/$(shell id -u)/$(LABEL) 2>/dev/null
	launchctl bootstrap gui/$(shell id -u) $(PLIST)
	@sleep 1
	launchctl kickstart -k gui/$(shell id -u)/$(LABEL)
	@echo "✓  守护进程已启动"

# ─── 辅助命令 ──────────────────────────────────────
install: all

uninstall:
	-launchctl bootout gui/$(shell id -u)/$(LABEL) 2>/dev/null
	@rm -f $(PLIST)
	@rm -rf $(RUNTIME)
	@rm -f $(LAUNCHER)
	@echo "✓  已卸载（保留 ~/.config/ivox/）"

run: deploy
	@echo "●  前台启动（Ctrl-C 停止）"
	.build/release/iVox serve

sign:
	codesign --force --sign $(SIGN_HASH) .build/release/iVox && echo "✓  签名完成" || echo "⚠️  签名失败"

# ─── 版本 ──────────────────────────────────────────
# make version V=v1.2.0
version:
	@if [ -z "$(V)" ]; then \
		echo "用法: make version V=v1.x.x"; exit 1; \
	fi
	@echo "$(V)" | grep -q '^v[0-9]\+\.[0-9]\+\.[0-9]\+$$' || { echo "格式错误：需要 vX.Y.Z"; exit 1; }
	sed -i '' 's/let iVoxVersion = ".*"/let iVoxVersion = "$(subst v,,$(V))"/' Sources/iVox/Utilities/Version.swift
	git add Sources/iVox/Utilities/Version.swift
	git commit -m "chore: 版本号 $(V)"
	-git tag -d "$(V)" 2>/dev/null; true
	git tag "$(V)"
	@echo "✓ 版本 $(V) 已就绪，运行 git push origin main --tags 发布"

clean:
	rm -rf .build

help:
	@echo "iVox 构建系统"
	@echo ""
	@echo "  make            = 全流程（init → build → deploy → launchd）"
	@echo "  make init       = 配置、hook（第 1 层）"
	@echo "  make build      = 编译（第 2 层）"
	@echo "  make deploy     = 编译 + 部署文件（第 2 层）"
	@echo "  make launchd    = 注册自启 + 启动 daemon（第 3 层）"
	@echo "  make uninstall  = 停服务 + 删文件"
	@echo "  make run        = 前台调试"
	@echo "  make version    = 发版（make version V=v1.2.0）"
	@echo "  make clean      = 删除 .build"
