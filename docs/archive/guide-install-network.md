# 安装网络层问题记录

## 问题 1: HTTP/2 截断（git upload-pack POST）

**状态：已知 + 兜底** ✅（HF / 子模块已走 tarball fallback）

### 症状

`git clone` / `git fetch` 走 git smart 协议（POST `git-upload-pack`）时偶发截断：

```
错误：RPC 失败。curl 18 Transferred a partial file
错误：预期仍然需要 N 字节的正文
致命错误：在引用列表之后应该有一个 flush 包
```

或：

```
错误：RPC 失败。curl 16 Error in the HTTP2 framing layer
致命错误：预期 'packfile'
```

普通 HTTPS GET（ref advertisement）200 OK 正常，只有大包 POST 走 HTTP/2 多路复用时出问题。`http.version=HTTP/1.1` 不生效（git 客户端/libgit2 限制）。

### 影响

1. **HuggingFace 模型下载**：HF 在国内经常 SSL 握手失败
2. **mlx-swift 子模块**：clone 必失败（pack 较大，触发截断）
3. **SwiftPM fetch**：偶发卡住

### 兜底

**1. 模型三级 fallback** —— `scripts/download-models.sh`：

```
HuggingFace → hf-mirror.com → ModelScope
```

每级失败自动切下一级。

**2. mlx 子模块 tarball 预填** —— `scripts/fetch-mlx-submodules.sh`：

```bash
bash scripts/fetch-mlx-submodules.sh
```

下载 GitHub tarball API、解压到 `.build/checkouts/mlx-swift/Source/Cmlx/{mlx,mlx-c}/`、touch `.git` 占位文件让 git submodule fetch 跳过。

**3. SwiftPM --skip-update**：

```bash
swift build --skip-update
```

跳过依赖 fetch（依赖首次已 clone 到 `.build/repositories/`，build 阶段不再发起网络请求）。

## 问题 2: Metal Toolchain 缺失

**状态：需手动安装** ✅（一次性 ~838MB）

### 症状

`.metal` 文件编译失败：

```
error: cannot execute tool 'metal' due to missing Metal Toolchain;
use: xcodebuild -downloadComponent MetalToolchain
```

### 修复

```bash
xcodebuild -downloadComponent MetalToolchain
```

仅首次需要，下载到 `/System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/`，以后 build 不再需要。

## 问题 3: `GH_TOKEN` 环境变量压过 `gh auth login`

**状态：已知** ⚠️

### 症状

`gh auth login --with-token` 成功执行，但 `gh auth status` 仍报 `Failed to log in to github.com using token (GH_TOKEN)`，`~/.config/gh/hosts.yml` 不生成。

### 原因

`GH_TOKEN` 环境变量优先级 > `~/.config/gh/hosts.yml` 里的 token。如果 shell 启动文件或 Claude Code 进程环境里有 `GH_TOKEN=...`（哪怕旧值失效），gh 会一直用它。

### 修复

```bash
unset GH_TOKEN
gh auth login --with-token --hostname github.com
```

并清理 `~/.zshrc` / `~/.zshenv` 里的 `export GH_TOKEN=...`（如果存在）。
