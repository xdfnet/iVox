# iVox 的构建、安装与发布入口。各目标用途见 CLAUDE.md 的「编译」「发布流程」两节。

.PHONY: all install update check check-tts init models voices build package uninstall run sign test version clean help

SWIFT := xcrun --toolchain swift-latest swift
SWIFT_RELEASE_FLAGS := -c release -Xswiftc -Osize
MODEL_DIR := $(HOME)/.config/ivox/model
RUNTIME := scripts/runtime.sh
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
	SED_INPLACE := sed -i ''
else
	SED_INPLACE := sed -i
endif

all: install

install:
	@$(MAKE) check
	@$(MAKE) init
	@$(MAKE) models
	@$(MAKE) build voices
	@$(RUNTIME) deploy-bin
	@$(RUNTIME) start
	@echo "✓  iVox 已就绪并已启动"

# update 就是字面的「off → 干活 → on」。先停干净再覆盖再起：在进程活着时 cp 覆盖
# 二进制会让 macOS 判签名失配（OS_REASON_CODESIGNING）把进程杀掉，极端情况 launchd
# 还可能拉起到写了一半的文件。停/起交给 CLI 的 `ivox off` / `ivox on`，不在这里各写一套。
#
# **失败要回滚**（含被 Ctrl-C/中断打断）：先 snapshot 留一份当前部署态，任何一步没过
# （编译失败、部署失败、或新二进制起不来）都走 trap 还原上一版并把服务拉回来——否则
# `stop` 已经把服务停了，人一走神就是「服务不见了 + 自启也关了」。全部成功才丢掉备份。
update:
	@ok=0; \
	trap 'if [ "$$ok" != "1" ]; then $(RUNTIME) rollback; fi' EXIT INT TERM; \
	$(RUNTIME) snapshot && \
	$(RUNTIME) stop && \
	$(MAKE) build voices && \
	$(RUNTIME) deploy-bin && \
	$(RUNTIME) start && \
	$(RUNTIME) discard-snapshot && \
	ok=1; \
	[ "$$ok" = "1" ] && echo "✓  iVox 已更新"

check:
	@$(RUNTIME) check-env

init:
	@$(RUNTIME) init

models:
	@scripts/download-models.sh "$(MODEL_DIR)"

voices:
	@$(RUNTIME) voices

build:
	$(SWIFT) build $(SWIFT_RELEASE_FLAGS)

# 打发布包：二进制 + 自包含集成资产（install/upgrade 解包后自动分发 hook/pi）
VERSION ?= $(shell sed -n 's/.*iVoxVersion = "\(.*\)"/\1/p' Sources/iVox/Version.swift)
PKG := ivox-v$(VERSION)-macos-arm64
package: build
	@rm -rf /tmp/$(PKG) && mkdir -p /tmp/$(PKG)/scripts/pi /tmp/$(PKG)/voices
	@cp .build/release/ivox /tmp/$(PKG)/ivox
	@cp scripts/hook.sh scripts/install-hooks.sh /tmp/$(PKG)/scripts/
	@cp scripts/pi/ivox.ts /tmp/$(PKG)/scripts/pi/
	@cp Sources/iVox/Resources/voices/*.wav /tmp/$(PKG)/voices/
	@for b in iVox_iVox.bundle mlx-swift_Cmlx.bundle; do \
	  src="$(CURDIR)/.build/out/Products/Release/$$b"; \
	  if [[ ! -d "$$src" ]]; then src=$$(find "$(CURDIR)/.build" -type d -name "$$b" -path "*elease*" | head -1); fi; \
	  if [[ -n "$$src" && -d "$$src" ]]; then cp -R "$$src" /tmp/$(PKG)/; \
	  else echo "⚠️  未找到 $$b（Web UI / TTS shader 会缺）"; fi; \
	done
	@cd /tmp/$(PKG) && tar czf $(CURDIR)/.build/release/$(PKG).tar.gz ivox scripts voices iVox_iVox.bundle mlx-swift_Cmlx.bundle
	@rm -rf /tmp/$(PKG)
	@echo "✓  .build/release/$(PKG).tar.gz"

uninstall:
	@$(RUNTIME) uninstall

run: build
	@echo "●  前台启动（Ctrl-C 停止）"
	.build/release/iVox serve

sign:
	@$(RUNTIME) sign

test:
	$(SWIFT) test

# 播报黑盒自检（压真实 daemon，需先 ivox on 且模型就绪）。用法: make check-tts / ARGS="-f protocol"
check-tts:
	@scripts/tts-check.sh $(ARGS)

version:
	@if [ -z "$(V)" ]; then \
		echo "用法: make version V=v1.x.x"; exit 1; \
	fi
	@echo "$(V)" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$$' || { echo "格式错误：需要 vX.Y.Z"; exit 1; }
	$(SED_INPLACE) 's/let iVoxVersion = ".*"/let iVoxVersion = "$(subst v,,$(V))"/' Sources/iVox/Version.swift
	git add Sources/iVox/Version.swift
	git commit -m "chore: 版本号 $(V)"
	-git tag -d "$(V)" 2>/dev/null; true
	git tag "$(V)"
	@echo "✓ 版本 $(V) 已就绪，运行 git push origin main --tags 发布"

clean:
	rm -rf .build

help:
	@echo "iVox 构建系统"
	@echo ""
	@echo "  make / make install = 首次安装"
	@echo "  make update         = 停服 + 编译 + 部署 + 启动（失败/中断自动回滚）"
	@echo "  make run            = 编译 + 前台调试"
	@echo "  make test           = 运行测试"
	@echo "  make check-tts      = 播报黑盒自检（真实 daemon，发版前手动跑）"
	@echo "  make build          = 编译 release"
	@echo "  make version        = 发版"
	@echo "  make uninstall      = 停服务 + 删 runtime"
	@echo "  make clean          = 删除 .build"
