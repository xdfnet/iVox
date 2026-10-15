import ArgumentParser
import Foundation
import iVoxKit

// CLI 子命令 ivox upgrade：从 GitHub Release 自升级。

/// 检查 GitHub 最新 release 并自动升级：下载适配 macos-arm64 的 tarball →
/// 停守护进程 → 备份旧版 → 解包替换 → ad-hoc 重签 → （原本在运行则）重启。
struct UpgradeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upgrade",
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
        // 1. 拉取最新 release
        print("正在检查最新版本…")
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("iVox-Upgrade", forHTTPHeaderField: "User-Agent")  // GitHub API 要求 UA
        request.timeoutInterval = 20
        let data: Data
        do {
            data = try await URLSession.shared.data(for: request).0
        } catch {
            print("错误: 无法访问 GitHub（\(error.localizedDescription)）。网络受限时可临时设置 https_proxy 后重试。")
            throw ExitCode.failure
        }

        let release: Release
        do {
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            print("错误: 解析 release 信息失败：\(error)")
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
        print("发现新版本 v\(latest)（当前 v\(iVoxVersion)），开始下载 \(asset.name)")

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
            let dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ivox-upgrade-\(safeTag).tar.gz")
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
            try? SocketClient.send("__IVOX_STOP__", to: socketPath)
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

        // 6. 定向解包：ivox → binDir，integrations/ → 配置目录（自包含发布包）
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
        // 集成资产（旧包可能不含，解包失败不阻断二进制升级）
        let tarInt = Process()
        tarInt.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tarInt.arguments = ["xzf", tarURL.path, "-C", configDir, "integrations"]
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

        // 7.5 同步集成资产（hook/pi）到各 agent；幂等，失败仅告警不阻断升级
        let installer = configDir + "/integrations/install-hooks.sh"
        if FileManager.default.fileExists(atPath: installer) {
            let sync = Process()
            sync.executableURL = URL(fileURLWithPath: "/bin/bash")
            sync.arguments = [installer, configDir + "/hook.sh"]
            try? sync.run()
            sync.waitUntilExit()
            if sync.terminationStatus == 0 {
                print("✓ 集成资产已同步（hook / pi）")
            } else {
                print("警告: 集成资产同步失败（退出码 \(sync.terminationStatus)），可稍后重跑安装脚本")
            }
        }

        // 8. 原本在运行则重启
        if wasRunning {
            print("重新启动守护进程…")
            try? FileManager.default.removeItem(atPath: socketPath)
            try AutostartCommand.On().run()
        }
        print("✓ 已升级到 v\(latest)")
        if !wasRunning {
            print("守护进程此前未运行，需要时执行 ivox autostart on 启动")
        }
    }

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
