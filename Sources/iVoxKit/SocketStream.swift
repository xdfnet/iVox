import Darwin
import Foundation

// socket 读取与「多久算断流」的时间口径。
//
// 为什么单独成文件：读超时的**语义**曾是全 iVox 唯一的暗坑——控制 socket 与合成流
// 共用同一个 10 秒上限，于是「合成慢」被当成「对端断了」，整块内容被丢弃
// （2026-10-24 实测：真对话里连丢 4 块，52~76 字，一字没念）。判「断了」的标准
// 与「等多久」的标准必须分开写在这里一处，别再散进调用方。

/// socket 超时的时间口径。**所有 socket 的超时值都从这里取**——别在调用点写裸数字。
public enum SocketTimeout {
    /// 控制类 socket（请求-应答型）的读写超时（秒）。
    ///
    /// 10 秒足够，且能防住「对端异常时无限阻塞」。合成流不用它——合成慢不等于对端挂了。
    public static let control: TimeInterval = 10

    /// 合成流的**单次**读超时（秒）——这只是粒度，不是整块的上限。
    ///
    /// 超过它只是这一趟 read 空手回来（EAGAIN），不是断流：接着等就是了。
    public static let synthesisRead: TimeInterval = 30

    /// 合成一整块的**总**时限（秒）。
    ///
    /// 兜底「对端活着但不再吐数据」——那种情况没有 EOF，只能靠时间收手，
    /// 否则队列会被永久卡在这一块上。
    public static let synthesisDeadline: TimeInterval = 120
}

/// 从 socket 读流。
public enum SocketReader {
    /// 整段读取到时限用尽。
    public enum ReadError: Error { case deadlineExceeded }

    /// 一直读到对端关闭（EOF）为止，每读到一段就交给 `onData`。
    ///
    /// **读超时（EAGAIN）不算断流**：SO_RCVTIMEO 只保证「这一趟 read 最多等这么久」，
    /// 合成慢（MLX 首帧慢、GPU 被抢）就会空转一次 EAGAIN——那不是对方挂了，继续等。
    /// 真正算「断了」的只有两样：对端关闭（EOF）与 socket 报错。
    ///
    /// - Parameters:
    ///   - fd: 已连接、且设好 `SO_RCVTIMEO` 的 socket。
    ///   - deadlineSeconds: 整段读取的总时限（秒），到点抛 `ReadError.deadlineExceeded`。
    ///   - onData: 每段数据的消费者（同步调用，不逃逸）。
    public static func readToEnd(fd: Int32,
                                 deadlineSeconds: Double,
                                 onData: (Data) -> Void) throws {
        let deadline = Date().addingTimeInterval(deadlineSeconds)
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            if Date() >= deadline { throw ReadError.deadlineExceeded }
            let n = Darwin.read(fd, &buf, buf.count)
            if n > 0 {
                onData(Data(buf[0..<n]))
                continue
            }
            if n == 0 { return }              // 对端关闭：真的读完了
            if errno == EINTR { continue }
            // 读超时（EAGAIN）：**这一趟没等到，不是断流**。合成慢时会反复走到这里。
            if errno == EAGAIN || errno == EWOULDBLOCK { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
