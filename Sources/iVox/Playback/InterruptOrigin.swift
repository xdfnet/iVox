import Foundation

// 打断归因：一次打断「是谁干的、动了哪一档」——档位只写一处，入口由调用方带下来。

/// 打断的**档位**：动了哪一层内容。
enum InterruptTier: Sendable, CustomStringConvertible {
    /// 掀页（Ctrl+1）：丢当前正在听的那一页剩下的块。
    case skipPage
    /// 掀摞（Ctrl+2）：丢当前正在听的那一摞的全部内容。
    case skipStack
    /// 全掀（Ctrl+3）：清空全部排队内容。
    case skipAll
    /// 取消本轮（接入方自己发的 `{cancel}`）：丢那一轮的内容，不掐在播。
    case cancelTurn
    /// 关播报（`ivox playback off`）：掐在播 + 清空排队，之后进来的内容一律丢弃。
    case disablePlayback
    /// 退出清场：守护进程退出时的系统级清场。
    case shutdown

    var description: String {
        switch self {
        case .skipPage: return "掀页"
        case .skipStack: return "掀摞"
        case .skipAll: return "全掀"
        case .cancelTurn: return "取消本轮"
        case .disablePlayback: return "关播报"
        case .shutdown: return "退出清场"
        }
    }
}

/// 打断的**入口**：是谁、按什么干的。
enum InterruptTrigger: Sendable, CustomStringConvertible {
    /// 键盘热键。带**实际生效的键位**（如 "ctrl+2"）——键位可配，写死 "Ctrl+2" 就是句假话。
    case hotkey(String)
    /// 外部请求（socket 帧）。带请求方**自报**的身份（如 "ivox-skip"、自检脚本名）。
    case request(String)
    /// 系统级动作（守护进程退出清场）。
    case system

    var description: String {
        switch self {
        case .hotkey(let chord): return "键盘 \(chord)"
        case .request(let who): return "请求方 \(who)"
        case .system: return "系统"
        }
    }
}

/// 一次打断的完整身份：**档位** × **入口**。
///
/// 日志里合成一句写：`掀摞·键盘 ctrl+2` —— 一眼看出谁按的什么键、掀的是哪一档。
///
/// **为什么拆成两维**（2026-10-26 飞哥反馈「那摞被打断却查不到谁打断了」）：
/// 旧实现只记**档位**（掀页/掀摞/全掀），而每一档都有好几个入口——键盘热键、
/// 命令行 `ivox skip`、外部 socket 帧（自检脚本等）——记的是同一个值，事后无从分辨。
/// **档位**（动了哪一层）与**入口**（谁按的什么）是两件独立的事，分开记才答得上
/// 「谁按的什么键、把哪一摞的哪一页掀了」。
///
/// **档位只写一处**：它由「调用哪个方法」决定（掀摞的方法配了掀页的档位就是自相矛盾），
/// 所以档位在 `PlaybackQueue` 的各个打断方法里落定，别的层只负责把**入口**带下来。
struct InterruptOrigin: Sendable, CustomStringConvertible {
    let tier: InterruptTier
    let trigger: InterruptTrigger

    init(_ tier: InterruptTier, _ trigger: InterruptTrigger) {
        self.tier = tier
        self.trigger = trigger
    }

    var description: String { "\(tier.description)·\(trigger.description)" }
}
