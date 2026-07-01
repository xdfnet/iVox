.PHONY: all install update check init models voices assets build deploy launchd restart uninstall run sign test version clean help

SWIFT := TOOLCHAINS=swift-6.3.2-RELEASE swift
SWIFT_RELEASE_FLAGS := -c release -Xswiftc -Osize
MODEL_DIR := $(HOME)/.config/ivox/model
RUNTIME := scripts/runtime.sh

all: install

install:
	@$(MAKE) check
	@$(MAKE) init
	@$(MAKE) models
	@$(MAKE) deploy
	@$(MAKE) launchd
	@echo "✓  iVox 已就绪"

update:
	@$(MAKE) deploy
	@$(MAKE) launchd
	@echo "✓  iVox 已更新"

check:
	@$(RUNTIME) check-env

init:
	@$(RUNTIME) init

models:
	@scripts/download-models.sh "$(MODEL_DIR)"

voices:
	@$(RUNTIME) voices

assets: voices

build:
	$(SWIFT) build $(SWIFT_RELEASE_FLAGS)

deploy: build voices
	@$(RUNTIME) deploy-bin

launchd:
	@$(RUNTIME) launchd

restart: update

uninstall:
	@$(RUNTIME) uninstall

run: build
	@echo "●  前台启动（Ctrl-C 停止）"
	.build/release/iVox serve

sign:
	@$(RUNTIME) sign

test:
	$(SWIFT) test

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
	@echo "✓ 版本 $(V) 已就绪，运行 git push origin master --tags 发布"

clean:
	rm -rf .build

help:
	@echo "iVox 构建系统"
	@echo ""
	@echo "  make / make install = 首次安装（检查 → 配置 → 模型 → 构建 → 部署 → 启动）"
	@echo "  make update         = 更新代码后的部署（构建 → 参考音频 → 部署 → 重启）"
	@echo "  make restart        = make update 的兼容别名"
	@echo ""
	@echo "  make models         = 从 ModelScope 下载默认 MLX 模型（已存在则跳过）"
	@echo "  make voices         = 初始化默认参考音频（已存在则跳过）"
	@echo "  make build          = 编译 release"
	@echo "  make deploy         = 构建 + 参考音频 + 部署二进制"
	@echo "  make launchd        = 写入 launchd plist 并启动 daemon"
	@echo ""
	@echo "  make run            = 编译 + 前台调试"
	@echo "  make test           = 运行测试"
	@echo "  make version        = 发版（make version V=v1.2.0）"
	@echo "  make uninstall      = 停服务 + 删 runtime"
	@echo "  make clean          = 删除 .build"
