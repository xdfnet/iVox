import Darwin
import XCTest
@testable import iVoxKit

// 「读超时 ≠ 对端断流」这条语义的钉子。
//
// 2026-10-24 现场：合成流的 socket 沿用控制 socket 的 10 秒读超时，于是合成慢到
// 某一趟 read 空转，就被当成「誊清员崩了」→ 报 truncated → 那一块内容整块丢弃
// （真对话里连丢 4 块，52~76 字，一字没念）。修法是：EAGAIN 继续等，只有 EOF
// 才是断流；另加一个整块总时限兜底「对端活着但不再吐数据」。
final class SocketReaderTests: XCTestCase {

    /// 对端慢：单次读超时（1 秒）之后才发数据 → 应完整收到，不是断流。
    func testSlowPeerIsNotTreatedAsDisconnect() throws {
        let payload = Data("慢一点也要送到".utf8)
        let server = try TestSocketServer { fd, _ in
            Thread.sleep(forTimeInterval: 3)      // 比客户端的单次读超时长
            writeAllToSocket(fd: fd, data: payload)
        }
        defer { server.stop() }

        let fd = try SocketClient.connect(to: server.path, timeout: 1)
        defer { Darwin.close(fd) }

        var received = Data()
        try SocketReader.readToEnd(fd: fd, deadlineSeconds: 20) { received.append($0) }
        XCTAssertEqual(received, payload, "慢对端的数据应完整送达")
    }

    /// 对端活着但一直不吐数据 → 整段总时限到点收手（否则队列永久卡在这一块）。
    func testDeadlineStopsReadingFromSilentPeer() throws {
        let server = try TestSocketServer { _, _ in
            Thread.sleep(forTimeInterval: 30)     // 一直不吐数据
        }
        defer { server.stop() }

        let fd = try SocketClient.connect(to: server.path, timeout: 1)
        defer { Darwin.close(fd) }

        XCTAssertThrowsError(
            try SocketReader.readToEnd(fd: fd, deadlineSeconds: 2) { _ in }
        ) { error in
            XCTAssertTrue(error is SocketReader.ReadError, "应报时限用尽，实际：\(error)")
        }
    }

    /// 对端发完就关 → 正常读完返回，不当断流处理。
    func testEOFReturnsNormally() throws {
        let payload = Data("念完了".utf8)
        let server = try TestSocketServer { fd, _ in
            writeAllToSocket(fd: fd, data: payload)
        }
        defer { server.stop() }

        let fd = try SocketClient.connect(to: server.path, timeout: 5)
        defer { Darwin.close(fd) }

        var received = Data()
        try SocketReader.readToEnd(fd: fd, deadlineSeconds: 10) { received.append($0) }
        XCTAssertEqual(received, payload)
    }
}
