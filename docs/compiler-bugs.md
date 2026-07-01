# Swift 编译器 Bug 记录

## Bug 1: Swift 6.4 快照 — SIL 处理栈溢出 (MLXAudioTTS)

### 症状

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

Swift 6.4 开发快照中存在编译器回归 bug，在 SIL 优化阶段（`performSILProcessing`）有栈溢出。

**官方相关 Issue：**

- [\[6.4 regression\] SILGenCleanup ownership crash #89787](https://github.com/swiftlang/swift/issues/89787) — typed-throws + enum-case pattern 导致 SILGenCleanup 崩溃
- [RedundantLoadElimination: insert a `drop_deinit` #89601](https://github.com/swiftlang/swift/pull/89601) — 修复了一类 SIL 验证器崩溃，但未完全解决

截至 2026-07-01，`release/6.4.x` 分支最新快照仍为 `2026-06-15`，未发布修复版本。

### 解决方案

**使用 Swift 6.3.2 稳定版工具链编译 release：**

```bash
TOOLCHAINS=swift-6.3.2-RELEASE swift build -c release
```

Swift 6.3.2（Xcode 26.x 内置）不受此 bug 影响，可正常编译 release 构建。

### 项目配置

iVox 的构建系统已固定为 6.3.2：

- `Makefile`：`SWIFT := TOOLCHAINS=swift-6.3.2-RELEASE swift`
- `.swift-version`：已删除（避免与 `TOOLCHAINS` 环境变量冲突）

### 后续

- 关注 [swiftlang/swift Issue #89787](https://github.com/swiftlang/swift/issues/89787)
- 当 Swift 6.4 发布正式版或修复版快照后，可以切回

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
