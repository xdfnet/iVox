import ArgumentParser
import Foundation
import iVoxKit

// CLI 子命令 ivox update：从 GitHub Release 自升级。

/// 检查 GitHub 最新 release 并自动升级：下载适配 macos-arm64 的 tarball →
/// 停守护进程 → 备份旧版 → 解包替换 → ad-hoc 重签 → （原本在运行则）重启。
struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "升级到 GitHub 最新版本（自动备份旧版并重启守护进程）"
    )

    private static let repo = "xdfnet/iVox"

    private struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: String
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }

    private struct Release: Decodable {
        let tagName: String
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    func run() async throws {
        // 先报当前版本，**已是最新时也照报**——参照 `claude update` 的节奏：
        // 当前版本 → 检查 → 目标版本 → 结果。上来就给版本号，升级前后的差别一眼可见。
        print("当前版本: v\(iVoxVersion)")
        // 1. 拉取最新 release
        print("正在检查最新版本…")
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("iVox-Update", forHTTPHeaderField: "User-Agent")  // GitHub API 要求 UA
        request.timeoutInterval = 20
        // 未认证的 GitHub API 只有 **60 次/小时、按出口 IP 算**——路由器透明代理下全机共用一个 IP，
        // 配额被别人用完就轮到自己遭殃，返回 `{"message":"API rate limit exceeded…"}`，
        // 而那里面**没有 tag_name**，于是 Swift 报「解析 release 信息失败」，把限流说成了代码坏了
        // （2026-10-19 实测：飞哥机器上配额耗尽，update 直接崩在这个坑上）。
        // 认证后是 5000 次/小时。token 只进请求头，**绝不打印、不写日志**。
        if let token = Self.authToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            print("错误: 无法访问 GitHub（\(error.localizedDescription)）。网络受限时可临时设置 https_proxy 后重试。")
            throw ExitCode.failure
        }

        // 先看 HTTP 状态码再解 JSON：限流/鉴权失败时 GitHub 返回的是**合法 JSON 但没有 tag_name**，
        // 直接丢给 JSONDecoder 只会得到一句误导性的「解析失败」。这里把状态码翻译成人话。
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // GitHub 的错误正文固定是 {"message": "…"}，取出来直接给用户看
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0?["message"] as? String) } ?? String(data: data, encoding: .utf8) ?? ""
            switch http.statusCode {
            case 403, 429:
                print("错误: GitHub 拒绝了请求（HTTP \(http.statusCode)）——多半是 API 限流。")
                if !message.isEmpty { print("  GitHub 说：\(message)") }
                print("  认证后配额是未认证的 80 多倍。设置一个 token 即可，例如在 ~/.zshrc 里：")
                print("    export GITHUB_TOKEN=\(Self.tokenHint)")
                print("  若已装并登录 GitHub CLI，ivox 会自动借用它的登录态，通常无需配置。")
            case 401:
                print("错误: GitHub 拒绝了凭据（401）——环境变量里的 GITHUB_TOKEN 可能已失效。")
            default:
                print("错误: GitHub 返回 HTTP \(http.statusCode)。")
                if !message.isEmpty { print("  GitHub 说：\(message)") }
            }
            throw ExitCode.failure
        }

        let release: Release
        do {
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            print("错误: 解析 release 信息失败（HTTP 成功但内容不是预期的 release 结构）：\(error)")
            throw ExitCode.failure
        }

        let latest = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        guard Self.isNewer(latest, than: iVoxVersion) else {
            print("已是最新版本 v\(iVoxVersion)")
            return
        }

        // 2. 选适配本机（macOS arm64）的 tarball
        guard let asset = release.assets.first(where: { a in
            let n = a.name.lowercased()
            return n.hasSuffix(".tar.gz")
                && (n.contains("macos") || n.contains("darwin"))
                && (n.contains("arm64") || n.contains("aarch64"))
        }) else {
            print("错误: 最新版 v\(latest) 未提供适配本机（macos-arm64）的 .tar.gz 安装包")
            throw ExitCode.failure
        }
        print("正在更新到 v\(latest)…（下载 \(asset.name)）")

        // 3. 下载到临时文件
        guard let downloadURL = URL(string: asset.browserDownloadUrl) else {
            print("错误: Release 里的下载地址无效：\(asset.browserDownloadUrl)")
            throw ExitCode.failure
        }
        // tag 来自远端，别让它带路径分隔符拼进文件名
        let safeTag = latest
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        let tarURL: URL
        do {
            let (tmpURL, _) = try await URLSession.shared.download(for: URLRequest(url: downloadURL))
            let dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ivox-update-\(safeTag).tar.gz")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmpURL, to: dest)
            tarURL = dest
        } catch {
            print("错误: 下载失败：\(error.localizedDescription)")
            throw ExitCode.failure
        }
        defer { try? FileManager.default.removeItem(at: tarURL) }

        // 4. 若守护进程在运行，先停（macOS 不能覆盖正在运行的可执行文件）
        let socketPath = AppPaths.socketPath
        let wasRunning = SocketClient.isRunning(path: socketPath)
        if wasRunning {
            print("停止守护进程…")
            // 发 SIGTERM（正经退出路径）：pid 从实例锁里读——锁还锁着 = 那个进程还活着
            _ = InstanceLock.terminateHolder(path: AppPaths.lockPath(for: socketPath))
            if !Self.waitForStop(path: socketPath) {
                print("错误: 守护进程未退出，请手动执行 pkill -f 'ivox serve' 后重试")
                throw ExitCode.failure
            }
        }

        // 5. 备份旧版
        let binDir = AppPaths.binDir
        try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        let binPath = binDir + "/ivox"
        let backupPath = binDir + "/ivox.bak-\(iVoxVersion)"
        if FileManager.default.fileExists(atPath: binPath) {
            try? FileManager.default.removeItem(atPath: backupPath)
            do {
                try FileManager.default.moveItem(atPath: binPath, toPath: backupPath)
            } catch {
                print("错误: 备份旧版失败：\(error)")
                throw ExitCode.failure
            }
            print("旧版已备份到 \(backupPath)")
        }

        // 6. 定向解包：ivox → binDir，scripts/ → 配置目录（自包含发布包）
        let configDir = AppPaths.configDir
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["xzf", tarURL.path, "-C", binDir, "ivox"]
        do { try tar.run(); tar.waitUntilExit() } catch {
            print("错误: 解包失败：\(error)")
            throw ExitCode.failure
        }
        guard tar.terminationStatus == 0, FileManager.default.fileExists(atPath: binPath) else {
            print("错误: 解包后未找到 \(binPath)，可从备份恢复：\(backupPath)")
            throw ExitCode.failure
        }
        // 接入资产（旧包可能不含，解包失败不阻断二进制升级）
        let tarInt = Process()
        tarInt.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tarInt.arguments = ["xzf", tarURL.path, "-C", configDir, "scripts"]
        try? tarInt.run()
        tarInt.waitUntilExit()

        // 7. 权限 + ad-hoc 重签（每次构建签名会变，不重签可能被 Gatekeeper/TCC 拦）
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binPath)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", binPath]
        try? sign.run()
        sign.waitUntilExit()
        if sign.terminationStatus != 0 {
            print("警告: ad-hoc 重签失败（退出码 \(sign.terminationStatus)），如遇权限异常可手动执行 codesign --force --sign - \(binPath)")
        }

        // 7.5 同步接入资产（hook/pi）到各 agent；幂等，失败仅告警不阻断升级
        let installer = configDir + "/scripts/install-hooks.sh"
        if FileManager.default.fileExists(atPath: installer) {
            let sync = Process()
            sync.executableURL = URL(fileURLWithPath: "/bin/bash")
            sync.arguments = [installer, configDir + "/hook.sh"]
            try? sync.run()
            sync.waitUntilExit()
            if sync.terminationStatus == 0 {
                print("✓ 接入资产已同步（hook / pi）")
            } else {
                print("警告: 集成资产同步失败（退出码 \(sync.terminationStatus)），可稍后重跑安装脚本")
            }
        }

        // 8. 原本在运行则重启
        if wasRunning {
            print("重新启动守护进程…")
            try? FileManager.default.removeItem(atPath: socketPath)
            try OnCommand().run()
        }
        print("✓ 已从 v\(iVoxVersion) 更新到 v\(latest)")
        if !wasRunning {
            print("守护进程此前未运行，需要时执行 ivox on 启动")
        }
    }

    /// 取 GitHub token，按「显式环境变量 → gh CLI 登录态」的顺序。
    ///
    /// 之所以留 `gh` 这条兜底：用户机器上装了 gh 并登录过就天然有 token，
    /// **不必再为一次升级去配环境变量**（本项目的取向是「非必要不让用户操作」）。
    /// 都没有则返回 nil —— 退回未认证的 60 次/小时，那条路径由状态码分支给出可操作的提示。
    /// 注意 token 只回传给调用方进请求头，任何日志/输出都不碰它。
    private static func authToken() -> String? {
        let env = ProcessInfo.processInfo.environment
        for key in ["GITHUB_TOKEN", "GH_TOKEN"] {
            if let t = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                return t
            }
        }
        // `gh auth token` 把 token 打到 stdout；token 在系统钥匙串里，gh 自己会去读
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["gh", "auth", "token"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice   // gh 未登录时会往 stderr 抱怨，别让终端炸出噪音
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0,
                  let t = String(data: data, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !t.isEmpty else { return nil }
            return t
        } catch {
            return nil   // gh 没装、或钥匙串问不出来——都不是错误，退回未认证即可
        }
    }

    /// 提示文案里的占位符，**不是真 token**（拿不到真值也不该在失败路径上泄露）
    private static let tokenHint = "ghp_…（在 github.com/settings/tokens 生成，只需 public repo 读权限）"

    /// 轮询等待守护进程退出（最多 ~10s），已退出返回 true（非 async，用 Thread 阻塞）
    private static func waitForStop(path: String) -> Bool {
        for _ in 0..<40 {
            if !SocketClient.isRunning(path: path) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return !SocketClient.isRunning(path: path)
    }

    /// 比较「x.y.z」数值版本号，remote > current 返回 true（段数不足补 0，非数字段按 0）
    private static func isNewer(_ remote: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0) ?? 0 }
        }
        let r = parts(remote), c = parts(current)
        let n = max(r.count, c.count)
        for i in 0..<n {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv != cv { return rv > cv }
        }
        return false
    }
}
