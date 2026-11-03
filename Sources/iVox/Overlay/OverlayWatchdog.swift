import AppKit

// 浮层的「状态对齐」触发器：定时 + 解锁事件，各叫一次对齐。

/// 提醒浮层把状态对齐回真源。
///
/// **为什么需要**：系统会在**锁屏解锁、切 Space、切换用户**时把窗口的「可见 / 位置」
/// **改回去**——而且不经过我们的代码。2026-11-04 实测：锁屏期间字幕被收走了，
/// 解锁后系统按**锁屏时的样子**把浮窗放回屏上（连旧的窗口宽度一起）→
/// 字幕收不掉，内容还被旧宽度切掉一半。
///
/// **真源在浮层自己**：内容空了就该收，内容还在就该摆对。系统改过的东西，对齐一次就回来。
/// 触发器只有这一处：字幕/译文那块浮窗与录音胶囊都用它。
@MainActor
final class OverlayWatchdog {
    /// 对齐的间隔（秒）：锁屏之外的其它干扰（切 Space、快速用户切换）也能兜住。
    private static let interval: TimeInterval = 5

    private let reconcile: @MainActor () -> Void
    private var timer: Timer?
    private var sessionToken: NSObjectProtocol?

    init(reconcile: @escaping @MainActor () -> Void) {
        self.reconcile = reconcile
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        // 解锁那一刻立刻对齐一次：不用等下一个轮询周期。
        sessionToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
    }

    /// 拆掉定时器与通知订阅。`isolated deinit`：这些是主线程上的对象，
    /// 清理也得在主线程（普通 deinit 不是隔离的，碰不了它们）。
    isolated deinit {
        timer?.invalidate()
        if let sessionToken {
            NSWorkspace.shared.notificationCenter.removeObserver(sessionToken)
        }
    }
}
