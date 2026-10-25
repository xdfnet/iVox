import AppKit
import iVoxKit

// 划词译文的浮层内容。

/// 划词译文这一路的内容来源：只说「哪几行字」与「什么时候收」。
///
/// 浮窗（`OverlayService`）负责外观、排版、落点与去重；这一路只管**什么时候有字、什么时候没字**：
/// 译完就交上去，等鼠标移开（或到点）就收回来。
///
/// 译文两行：原文（半透明）与译文（白）。曾与播报字幕各占一个窗口、靠一个手写死的
/// 「96 点间隙」错开；合成一块浮窗后，上下次序由容器的排列保证，不再靠魔法数字。
///
/// **刻意不做**：拖拽移动、点击外部关闭、文本选择。这三样都要 key window / 输入焦点，
/// 当前 daemon 形态给不了；替代是「再按一次 Opt+Z 覆盖 + 到点自己消失」。
@MainActor
final class TranslationPanel {
    private let service: OverlayService
    /// 兜底定时器：鼠标一直不动时的最后保险（正常靠鼠标移动收起）
    private var hideWorkItem: DispatchWorkItem?
    /// 显示时的鼠标位置；此后鼠标一动就认为「看完了」
    private var anchorPoint: NSPoint = .zero
    private var mouseWatchTask: Task<Void, Never>?

    init(service: OverlayService) {
        self.service = service
    }

    /// 在浮窗里显示译文（`original` 为空串表示只显示一段，如出错提示）。
    ///
    /// - Parameters:
    ///   - original: 选中的原文；传空串表示只显示一段（如出错提示）
    ///   - translated: 译文
    ///   - timeoutSeconds: 兜底隐藏秒数（鼠标一动就提前收起）
    func show(original: String, translated: String, timeoutSeconds: Double) {
        var lines: [OverlayService.Line] = []
        if !original.isEmpty {
            lines.append(.init(text: original, style: .dim))
        }
        lines.append(.init(text: translated, style: .normal))
        service.show(.translation, lines: lines)

        // 划完词手就停在鼠标上，眼睛看着浮窗；一旦手移开（要滚动、点别处、打字），
        // 就说明看完了。比「固定几秒」准得多——读到什么时候就留到什么时候。
        anchorPoint = NSEvent.mouseLocation
        startWatchingMouse()
        scheduleHide(after: timeoutSeconds)   // 兜底：鼠标一直不动时的最后保险
    }

    func dismiss() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        mouseWatchTask?.cancel()
        mouseWatchTask = nil
        service.hide(.translation)
    }

    // MARK: - 内部

    /// 轮询鼠标：相对显示时位移超过 5px 就收起。
    /// 5px 足够大，能手抖/微漂不误触；也足够小，真人一动手就跨过去了。
    private func startWatchingMouse() {
        mouseWatchTask?.cancel()
        mouseWatchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self else { return }
                let now = NSEvent.mouseLocation
                let dx = now.x - self.anchorPoint.x
                let dy = now.y - self.anchorPoint.y
                if dx * dx + dy * dy > 25 {
                    self.dismiss()
                    return
                }
            }
        }
    }

    private func scheduleHide(after seconds: Double) {
        hideWorkItem?.cancel()
        guard seconds > 0 else { return }
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.dismiss() }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }
}
