import ArgumentParser
import Foundation
import iVoxKit

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "查看守护进程运行状态：功能开关与权限"
    )

    func run() throws {
        let socketPath = AppPaths.socketPath

        if SocketClient.isRunning(path: socketPath) {
            do {
                let header = Data("{type:status}\n".utf8)
                let json = try SocketClient.sendWithReply(header: header, body: Data(), to: socketPath)
                if let data = json.data(using: .utf8),
                   let status = try? JSONDecoder().decode(DaemonStatus.self, from: data) {
                    render(status)
                } else {
                    print("运行中（状态解析失败）")
                }
            } catch {
                print("运行中（状态查询失败：\(error.localizedDescription)）")
            }
        } else {
            print("未运行")
        }

        renderConfig()
    }

    // MARK: 本地配置静态体检（守护进程未运行也能查）

    private func renderConfig() {
        print()
        print("配置")
        let cfg: Config
        do {
            cfg = try loadConfig()
        } catch {
            print("  ✗ 配置无法解析（\(error)）")
            return
        }

        let ttsPath = cfg.models?.ttsPath ?? "~/.config/ivox/model/Qwen3-TTS-12Hz-1.7B-Base-8bit"
        modelCheck(name: "TTS 模型", path: ttsPath)

        if cfg.speechInput?.enabled ?? SpeechInputConfig.default.enabled {
            let asrPath = cfg.models?.asrPath ?? "~/.config/ivox/model/Qwen3-ASR-1.7B-8bit"
            modelCheck(name: "ASR 模型", path: asrPath)
        }

        for v in cfg.voices {
            guard let ref = v.refAudio, !ref.isEmpty else { continue }
            let exists = FileManager.default.fileExists(atPath: (ref as NSString).expandingTildeInPath)
            print("  音色 \(v.id)\(exists ? "    ✓ 正常" : "    ✗ 参考音频缺失（\(ref)）")")
        }
    }

    /// 模型目录判活：目录存在且含 config.json + 至少一个 safetensors
    private func modelCheck(name: String, path: String) {
        let dir = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            print("  \(name)    ✗ 目录不存在（\(path)）")
            return
        }
        let items = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        guard items.contains("config.json"), items.contains(where: { $0.hasSuffix(".safetensors") }) else {
            print("  \(name)    ✗ 模型文件不完整（\(path)）")
            return
        }
        print("  \(name)    ✓ 正常")
    }

    private func render(_ s: DaemonStatus) {
        print("iVox \(s.version)")
        print()
        print("功能")
        // 顺序与 README 功能表一致
        print("  自动播报    \(health(s.features.playback))")
        print("  媒体控制    \(health(s.features.mediaControl))")
        print("  语音输入    \(health(s.features.speechInput))")
        print("  划词翻译    \(health(s.features.translation))")
        print("  快速操作    \(health(s.features.quickActions))")
        print("  微信桥接    \(health(s.features.wechat))")
        print()
        print("权限")
        print("  麦克风      \(micText(s.permissions.microphone))")
        print("  设备控制    \(s.permissions.deviceControl ? "已授权" : "未授权")")
    }

    /// ok → 正常；off → 未启用；loading → 加载中；error:xxx → 异常(xxx)
    private func health(_ value: String) -> String {
        if value == "ok" { return "✓ 正常" }
        if value == "off" { return "— 未启用" }
        if value == "loading" { return "… 加载中" }
        if value.hasPrefix("error:") { return "✗ 异常（\(value.dropFirst(6))）" }
        return value
    }

    private func micText(_ value: String) -> String {
        switch value {
        case "authorized": return "已授权"
        case "denied": return "未授权"
        case "notDetermined": return "未决定"
        case "restricted": return "受限"
        default: return value
        }
    }
}
