import Foundation

// {type:status} 的返回体。

/// 守护进程状态快照（ivox status 经 socket 查询）
public struct DaemonStatus: Codable, Sendable {
    /// 运行中 daemon 的版本号
    public var version: String

    /// 每项功能的健康结论：ok(正常) | off(未启用) | 以 "error:" 开头的异常原因
    /// 六个能力域，彼此平级——它们之间有协作（语音输入会打断播报并独占麦克风、
    /// 划词翻译借播报念译文…），但没有主从，所以这里也是六项并列。
    public struct Features: Codable, Sendable {
        public var playback: String
        public var speechInput: String
        public var translation: String
        public var quickActions: String
        public var wechat: String
        public var mediaControl: String

        public init(playback: String = "off", speechInput: String, translation: String = "off", quickActions: String = "off", wechat: String, mediaControl: String) {
            self.playback = playback
            self.speechInput = speechInput
            self.translation = translation
            self.quickActions = quickActions
            self.wechat = wechat
            self.mediaControl = mediaControl
        }
    }

    public struct Permissions: Codable, Sendable {
        /// 麦克风：authorized | denied | notDetermined | restricted
        public var microphone: String
        /// 设备控制与数据访问（旧称辅助功能）
        public var deviceControl: Bool
        /// 键盘注入（向别的 app 投递合成按键；macOS 单独记的 PostEvent 授权）
        public var postEvent: Bool

        public init(microphone: String, deviceControl: Bool, postEvent: Bool) {
            self.microphone = microphone
            self.deviceControl = deviceControl
            self.postEvent = postEvent
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
