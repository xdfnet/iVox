import AppKit
import CoreGraphics
import Foundation
import iVoxKit

// 快速操作：Finder 与终端的组合键。

/// QuickActions —— 从 Finder 当前目录出发做一件事：开终端、拉起编码工具、复制路径。
///
/// 对应五个热键：
/// - `Opt+Q` 在 Finder 当前目录打开终端
/// - `Opt+A` / `Opt+X` / `Opt+S` 打开终端并分别执行 `claude` / `codex` / `pi`
/// - `Opt+C` 把 Finder 选中项的路径写进剪贴板
///
/// 它和划词翻译同为「用户按了组合键」的入口，但**是两个能力域**：`Translation/` 管文本工具，
/// `QuickActions/` 管这类系统快捷，`Daemon` 只按归属分派。
///
/// 开终端走 **Ghostty**：它的 `--working-directory` + `-e` 是原生 CLI 参数，一条
/// LaunchServices 调用就够了，不需要临时文件、也不需要 Terminal 的 Automation 授权。
/// （用 Terminal.app 时这两样总得沾一样：AppleScript `do script` 要多一份 Automation 授权
/// 且 iDict 时代有双窗问题；写临时 `.command` 则要额外做回收和 mtime 竞态处理。Ghostty
/// 把这条路直接打通了。）
/// 取 Finder 路径仍走 AppleScript——这是唯一需要 Automation 的地方，面积很小。
@MainActor
final class QuickActionsService {
    private static let ghosttyApp = URL(fileURLWithPath: "/Applications/Ghostty.app")

    func handle(_ hotKey: HotKeyAction, at location: CGPoint) async {
        switch hotKey {
        case .translate:
            break   // 不属于本域；Daemon 分派时已排除，这里只是穷举
        case .openTerminal:
            // 在 Finder 选中项处新开一个终端窗口。早先这里有个「Ghostty 已在跑就只聚焦、
            // 不开新窗口」的分支（怕连按五下开五个终端），但它不切目录——用户选了文件夹按
            // Opt+Q 却只看到老窗口被叫到前面，等于「没反应」（2026-10-25 实测反馈）。
            // 这一档的语义就是「在哪儿选就在哪儿开」，复用老窗口反而丢了这个语义。
            await openTerminal(running: nil)
        case .openTerminalClaude:
            await openTerminal(running: "claude")
        case .openTerminalCodex:
            await openTerminal(running: "codex")
        case .openTerminalPi:
            await openTerminal(running: "pi")
        case .copyPath:
            copySelectedPath()
        case .skipAll:
            break   // 不属于本域；Daemon 分派时已处理打断，这里只是穷举
        case .skipBucket, .skipPage:
            break   // 不属于本域；Daemon 分派时已处理跳桶/跳句，这里只是穷举
        }
    }

    // MARK: - 开终端

    /// 不带命令的 Opt+Q：**在 Finder 选中项处新开一个终端窗口**。
    private func openTerminal(running command: String?) async {
        guard let dir = finderPath(preferContainer: true), !dir.isEmpty else {
            Log.warn("QuickActions: 取不到 Finder 目录")
            return
        }
        // 参数经 `NSWorkspace.OpenConfiguration` 下发（等价于 `open -na Ghostty.app --args …`，
        // macOS 上官方就这一条路——Ghostty 不支持直接从 CLI 启动终端）。
        // **必须配 createsNewApplicationInstance**：复用已运行的 Ghostty 实例时参数会被
        // 静默忽略（实测：带 -n 生效、不带则命令根本不跑），只有新实例收得到。
        // wait-after-command：命令退出后**保留窗口**（Ghostty 默认 false＝直接关窗）。
        // 开 claude/codex/pi 退出时要能看见最后的输出——原 Terminal.app + `.command`
        // 的行为就是留着窗口，这里对齐它。
        var args = ["--working-directory=\(dir)", "--wait-after-command=true"]
        if let command {
            // 用 `--command=shell:<cmd>`（Ghostty 官方写法）而非 `-e`：**`-e` 每次都会弹 macOS 的
            // 「Allow Ghostty to execute "/bin/zsh"?」确认框**（Ghostty 的安全机制，
            // 目前没有配置项能关，issue #8648 仍在讨论），`--command` 不走那条通道。
            // 实测 1.3.1：`shell:` 后的命令在**真 tty**（/dev/ttyNN）里跑，cwd 即
            // `--working-directory`。
            args.append("--command=shell:\(command)")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = args
        config.createsNewApplicationInstance = true
        // PATH 必须显式给过去：daemon 由 launchd 启动，继承的 PATH 只有系统那几项
        // （`/usr/bin:/bin:/usr/sbin:/sbin`），不含 `~/.local/bin`（claude）与 Homebrew 的
        // bin（codex/pi）；而 Ghostty 在 macOS 上经 `/usr/bin/login` + `--noprofile --norc`
        // 启动 shell，**不读 profile**，PATH 只能由发起方给。
        // ⚠️ 别改成「套 `zsh -lc` 让它自己读 profile」：那是绕路，且 `codex`/`pi` 是
        // `#!/usr/bin/env node` 的脚本，`env node` 照样要在 PATH 里找 node。
        config.environment = Self.ghosttyEnvironment()
        do {
            try await NSWorkspace.shared.openApplication(at: Self.ghosttyApp, configuration: config)
            if let command {
                // 只报「窗口开了、命令交给登录 shell」，不报「执行了 command」——
                // 真正的执行在 Ghostty 的 zsh 里，此刻还没发生。若 PATH 里没有该命令，
                // 窗口照常弹出但报 not found，写「执行了」就是一条骗人的日志。
                // 排查时看下面 DEBUG 的完整 args。
                Log.info("QuickActions: 已在 \(dir) 打开终端（命令: \(command)，是否装有该命令以终端输出为准）")
                Log.debug("QuickActions: Ghostty args = \(args.joined(separator: " "))")
            } else {
                Log.info("QuickActions: 在 \(dir) 打开终端")
            }
        } catch {
            Log.warn("QuickActions: 打开 Ghostty 失败（装了没？brew install --cask ghostty）: \(error.localizedDescription)")
        }
    }

    /// Ghostty 子进程的环境变量：继承 daemon 自己的环境，只把 PATH 补上用户自装工具的目录。
    ///
    /// 为什么要补：daemon 由 launchd 启动，PATH 只有系统那几项；Ghostty 在 macOS 上又
    /// 明令不读 profile，`claude`（`~/.local/bin`）、`codex`/`pi`（Homebrew 的 bin）就都找不到。
    /// 目录清单的唯一真源在 `AppPaths.userBinDirs`（按 `HOME` 展开，不写死用户名）。
    private static func ghosttyEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let base = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let extra = AppPaths.userBinDirs.filter { !base.split(separator: ":").contains(Substring($0)) }
        env["PATH"] = ([base] + extra).joined(separator: ":")
        return env
    }

    // MARK: - 复制路径

    private func copySelectedPath() {
        guard let path = finderPath(preferContainer: false), !path.isEmpty else {
            Log.warn("QuickActions: 取不到 Finder 选中项")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        Log.info("QuickActions: 已复制路径 \(path)")
    }

    // MARK: - Finder 取路径

    /// - Parameter preferContainer: 选中项是文件时，是否取其所在目录（开终端用 true，复制路径用 false）
    private func finderPath(preferContainer: Bool) -> String? {
        let inner: String
        if preferContainer {
            inner = """
            set sel to selection
            if sel ≠ {} then
                set theItem to item 1 of sel
                if class of theItem is folder then
                    return POSIX path of (theItem as alias)
                else
                    return POSIX path of (container of theItem as alias)
                end if
            else
                try
                    return POSIX path of (target of front Finder window as alias)
                on error
                    return POSIX path of (path to desktop folder)
                end try
            end if
            """
        } else {
            inner = """
            set sel to selection
            if sel = {} then
                try
                    set sel to {target of front Finder window as alias}
                on error
                    set sel to {path to desktop folder}
                end try
            end if
            return POSIX path of (item 1 of sel as alias)
            """
        }

        let source = "tell application \"Finder\"\n\(inner)\nend tell"
        guard let script = NSAppleScript(source: source) else {
            Log.warn("QuickActions: AppleScript 构造失败")
            return nil
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            Log.warn("QuickActions: 读取 Finder 失败（可能未授予自动化权限）\(error)")
            return nil
        }
        return result.stringValue
    }
}
