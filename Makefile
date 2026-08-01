.PHONY: all install update check init models voices assets build uninstall run sign test version clean help

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
	@$(RUNTIME) launchd
	@echo "✓  iVox 已就绪"

update:
	@$(MAKE) build voices
	@$(RUNTIME) deploy-bin
	@$(RUNTIME) launchd
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
	@echo "$(V)" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$$' || { echo "格式错误：需要 vX.Y.Z"; exit 1; }
	$(SED_INPLACE) 's/let iVoxVersion = ".*"/let iVoxVersion = "$(subst v,,$(V))"/' Sources/iVox/Utilities/Version.swift
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
	@echo "  make / make install = 首次安装"
	@echo "  make update         = 编译 + 部署 + 重启"
	@echo "  make run            = 编译 + 前台调试"
	@echo "  make test           = 运行测试"
	@echo "  make build          = 编译 release"
	@echo "  make version        = 发版"
	@echo "  make uninstall      = 停服务 + 删 runtime"
	@echo "  make clean          = 删除 .build"
