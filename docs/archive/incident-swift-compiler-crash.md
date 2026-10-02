# Swift 编译器 Bug 记录

## Bug 1: Swift 6.4 快照 — SIL 处理栈溢出 (MLXAudioTTS)

**状态：已修复** ✅（自 Swift 6.4 快照 `2026-06-15` 起，`release/6.4.x` 分支已修复）

### 症状（已不存在）

`swift build -c release` 编译包含 `mlx-audio-swift` 的项目时崩溃：

```
#0 0x0000000100f7da68 llvm::sys::PrintStackTrace(llvm::raw_ostream&, int)
#1 0x0000000100f7b6a8 llvm::sys::RunSignalHandlers()
#2 0x0000000100f7d6f8 SignalHandler(int)
#3 0x00000001b5808e4c _sigtramp
...
#27 0x0000000107f5096c performSILProcessing()
Stack overflow
```

完整调用栈显示 `performSILProcessing()` 阶段栈溢出，发生在 **SIL 优化处理**期间。

### 环境

| 项 | 值 |
|---|---|
| 工具链 | `swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-06-15-a` |
| Swift 版本 | Apple Swift version 6.4-dev (LLVM 0aa1511f1bca4a6, Swift 80702ec6ad4159b) |
| Xcode | Swift 6.4 (swiftlang-6.4.0.20.104) |
| macOS | 27.0 (26A5368g) — Apple Silicon |
| 触发模块 | `MLXAudioTTS` (mlx-audio-swift commit `3f6b055`) |
| 编译模式 | `-c release -Xswiftc -Osize`（`-O` 也可复现） |
| Debug 模式 | `-c debug`（`-Onone`）正常 |

### 复现

```bash
swift build -c release
```

### 影响

`-c release` 无法编译。Debug 模式正常，但性能极差（用户反馈"为什么这么卡"），无法用于生产部署。

### 根本原因

Swift 6.4 开发快照中存在编译器回归 bug，在 SIL 优化阶段（`performSILProcessing`）有栈溢出。此 bug 已在 `release/6.4.x` 分支的 `2026-06-15` 快照中**修复**，官方在约 6 月后推送了修复，但未公开关联到具体 issue。

### 解决方案

**使用 Swift 6.4 开发快照编译 release：**

```bash
xcrun --toolchain swift-latest swift build -c release -Xswiftc -Osize
```

本地 `swift-latest` 工具链指向 `swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-06-15-a`（安装在 `~/Library/Developer/Toolchains/`）。

### 项目配置

iVox 的构建系统已更新为 6.4：

- `Makefile`：`SWIFT := xcrun --toolchain swift-latest swift`
- 不再需要指定 `TOOLCHAINS` 环境变量

### 后续

- ✅ 此 bug 已在 `release/6.4.x` 分支的 `2026-06-15` 快照中修复
- 早前怀疑相关的两个 issue 已确认是不同 bug：
  - [#89787](https://github.com/swiftlang/swift/issues/89787) — typed-throws + catch 的 SILGenCleanup ownership crash（已由 PR #90330 修复，合入 `main`）
  - [#89601](https://github.com/swiftlang/swift/pull/89601) — RedundantLoadElimination 的 SIL verifier crash（已合入 `release/6.4.x`，但与此栈溢出无关）
- 自 2026-06-15 后未发布过新的 6.4 快照；等正式版发布后可再次验证

---

## Bug 2: macOS 27 — ad-hoc 签名触发 SIGKILL

### 症状

重建二进制后启动立即被 `taskgated` 以 `SIGKILL (Code Signature Invalid)` 杀死。

### 原因

- iVox 使用 ad-hoc 自签（`codesign -f -s -`）
- Swift 每次重建生成不同的签名 hash
- TCC（透明度、同意与控制）数据库按签名 hash 记录权限
- 新签名的 hash 不在 TCC 数据库中 → `taskgated` 判定签名无效 → SIGKILL

### 解决方案

每次部署后重新签名：

```bash
codesign -f -s - /path/to/ivox
```

`make deploy` 已自动包含此步骤（通过 `runtime.sh deploy-bin` 调用 `sign` target）。
