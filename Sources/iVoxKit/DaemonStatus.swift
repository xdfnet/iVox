import Foundation

/// 守护进程状态快照（ivox status 经 socket 查询）
public struct DaemonStatus: Codable, Sendable {
    /// 运行中 daemon 的版本号
    public var version: String

    /// 每项功能的健康结论：ok(正常) | off(未启用) | 以 "error:" 开头的异常原因
    public struct Features: Codable, Sendable {
        public var speechInput: String
        public var wechat: String
        public var mediaControl: String
        public var mediaHTTP: String

        public init(speechInput: String, wechat: String, mediaControl: String, mediaHTTP: String) {
            self.speechInput = speechInput
            self.wechat = wechat
            self.mediaControl = mediaControl
            self.mediaHTTP = mediaHTTP
        }
    }

    public struct Permissions: Codable, Sendable {
        /// 麦克风：authorized | denied | notDetermined | restricted
        public var microphone: String
        /// 设备控制与数据访问（旧称辅助功能）
        public var deviceControl: Bool

        public init(microphone: String, deviceControl: Bool) {
            self.microphone = microphone
            self.deviceControl = deviceControl
        }
    }

    public var features: Features
    public var permissions: Permissions

    public init(version: String, features: Features, permissions: Permissions) {
        self.version = version
        self.features = features
        self.permissions = permissions
    }
}
