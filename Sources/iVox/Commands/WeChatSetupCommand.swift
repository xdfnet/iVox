import ArgumentParser
import Cocoa
import Foundation
import iVoxKit

// MARK: - ivox wechat setup — 微信扫码登录 / 配置 Token

struct WeChatSetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "配置微信 ilink 机器人"
    )

    @Argument(help: "可选: 直接传入 token 跳过扫码")
    var token: String?

    @Option(name: .shortAndLong, help: "ilink API 地址")
    var baseURL: String?

    func run() async throws {
        let configPath = NSString(string: "~/.config/ivox/config.json").expandingTildeInPath
        // 从现有配置加载，没有就建一个空的
        let cfgExists = FileManager.default.fileExists(atPath: configPath)
        var cfg = cfgExists ? (try? loadConfig()) : nil
        if cfg == nil {
            Log.info("未找到配置，新建默认配置")
            // 写入一个带默认值的配置
            let defaults: [String: Any] = [
                "default_voice": "taozi",
                "source_voices": ["claude": "taozi"],
                "voices": [["id": "taozi", "name": "桃子"]]
            ]
            let data = try JSONSerialization.data(withJSONObject: defaults, options: [.prettyPrinted, .sortedKeys])
            var text = String(data: data, encoding: .utf8) ?? "{}"
            text += "\n"
            try? FileManager.default.createDirectory(atPath: NSString(string: "~/.config/ivox").expandingTildeInPath,
                                                      withIntermediateDirectories: true)
            try text.write(toFile: configPath, atomically: true, encoding: .utf8)
            cfg = try? loadConfig()
        }
        guard var cfg else {
            print("❌ 无法创建配置")
            throw ExitCode.failure
        }

        if let token = token, !token.isEmpty {
            // 直接配置 token
            print("验证 token...")
            let base = baseURL ?? cfg.wechat?.baseURL ?? "https://ilinkai.weixin.qq.com"
            let client = WeChatClient(baseURL: base, token: token)
            do {
                try await client.verifyToken()
            } catch {
                print("❌ Token 验证失败: \(error.localizedDescription)")
                throw ExitCode.failure
            }
            print("✅ Token 验证通过")

            if cfg.wechat == nil {
                cfg.wechat = WeChatConfig()
            }
            cfg.wechat?.token = token
            cfg.wechat?.baseURL = base

            try saveConfig(cfg, to: configPath)
            print("✅ 配置已保存: \(configPath)")
            print("🎉 微信已配置完成！")
            return
        }

        // 扫码登录
        print("正在获取二维码...")
        print("步骤 1/3: 获取二维码")

        let base = baseURL ?? cfg.wechat?.baseURL ?? "https://ilinkai.weixin.qq.com"
        let client = WeChatClient(baseURL: base, token: "")
        var qrResp: BotQRResponse
        do {
            qrResp = try await client.getBotQRCode(botType: "3")
        } catch {
            print("❌ 获取二维码失败: \(error.localizedDescription)")
            print("建议:")
            print("- 检查网络后重试")
            throw ExitCode.failure
        }

        print("步骤 2/3: 请扫码登录")
        print("二维码链接:")
        print(qrResp.qrcodeImgContent)
        if let url = URL(string: qrResp.qrcodeImgContent) {
            NSWorkspace.shared.open(url)
            print("已自动在浏览器打开二维码链接")
        }

        // 轮询扫码状态
        let deadline = Date().addingTimeInterval(480)
        var qrKey = qrResp.qrcode
        var refreshCount = 0
        let maxRefresh = 3
        var lastStatus = ""

        repeat {
            try await Task.sleep(nanoseconds: 1_000_000_000)

            let poll: QRStatusResponse
            do {
                poll = try await client.pollQRStatus(qrKey: qrKey)
            } catch {
                if Date() >= deadline { break }
                continue
            }

            let status = poll.status ?? "wait"
            if status != lastStatus {
                switch status {
                case "wait", "": print("等待扫码中...")
                case "scaned": print("已扫码，请在手机上确认登录...")
                case "expired": print("二维码已过期...")
                case "confirmed": print("正在完成登录...")
                default: break
                }
                lastStatus = status
            }

            switch status {
            case "expired":
                refreshCount += 1
                if refreshCount > maxRefresh {
                    print("❌ 二维码多次过期，请重试")
                    throw ExitCode.failure
                }
                let newQR = try await client.getBotQRCode(botType: "3")
                qrKey = newQR.qrcode
                print("请扫描新二维码:")
                print(newQR.qrcodeImgContent)
                lastStatus = ""

            case "confirmed":
                guard let botID = poll.ilinkBotID, !botID.isEmpty,
                      let botToken = poll.botToken, !botToken.isEmpty else {
                    print("❌ 登录确认但缺少 bot_token 或 ilink_bot_id")
                    throw ExitCode.failure
                }

                let apiBase = poll.baseurl?.isEmpty == false ? poll.baseurl! : base

                if cfg.wechat == nil {
                    cfg.wechat = WeChatConfig()
                }
                cfg.wechat?.token = botToken
                cfg.wechat?.baseURL = apiBase
                if let userID = poll.ilinkUserID, !userID.isEmpty,
                   (cfg.wechat?.allowFrom ?? "").isEmpty {
                    cfg.wechat?.allowFrom = userID
                    print("📝 已设置 allow_from = \(userID)")
                }

                try saveConfig(cfg, to: configPath)
                print("✅ 配置已保存: \(configPath)")
                print("✅ 登录成功! bot_id: \(botID)")
                print("🎉 微信配置完成！")

                // 引导辅助功能权限
                await setupAccessibility()

                // 重启 daemon 让配置生效
                print("重启守护进程...")
                restartDaemon()

                return
            default:
                break
            }
        } while Date() < deadline

        print("❌ 等待扫码超时")
        throw ExitCode.failure
    }

    private func setupAccessibility() async {
        print()
        print("🔐 辅助功能权限是必要条件（用于 Cmd+V 键盘注入）")
        print()
        print("   需要将 ivox 添加到辅助功能列表")
        print()

        print("按 Enter 打开系统设置...", terminator: "")
        _ = readLine()

        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )

        print()
        print("   请点击 + 添加 \(NSHomeDirectory())/.local/bin/ivox 并勾选")
        print("   完成后按 Enter 继续...", terminator: "")
        _ = readLine()
        print("🔐 辅助功能权限配置完成")
    }

    private func restartDaemon() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["kickstart", "-k", "gui/\(getuid())/com.user.ivox"]
        try? proc.run()
        proc.waitUntilExit()
    }
}
