import Darwin
import XCTest
@testable import iVox
@testable import iVoxKit

// 端到端钉住「合成慢不丢字」。
//
// 2026-10-24 现场：合成流沿用控制 socket 的 10 秒读超时，合成一慢就被当成断流，
// 整块内容被丢弃（真对话里连丢 4 块）。这里用一个「慢吐 PCM」的假誊清员复现那条
// 路径：修复前应报 truncated（内容没了），修复后应完整收到 PCM。
final class TSPRemoteSlowSynthesisTests: XCTestCase {

    /// 誊清员慢：3 秒后才吐 PCM，而单次读超时只有 1 秒 → 仍要完整送达。
    func testSlowSynthesisStillDeliversFullAudio() async throws {
        let pcm = Data(repeating: 7, count: 320)
        let server = try TestSocketServer { fd, request in
            guard !request.isEmpty else { return }   // isRunning 的探测连接：连上就走
            if request.range(of: Data("type:status".utf8)) != nil {
                writeAllToSocket(fd: fd, data: Data("state:ready\n".utf8))
                return
            }
            Thread.sleep(forTimeInterval: 3)       // 比单次读超时长
            var out = Data()
            out.append(StreamFrame.chunk(pcm))
            out.append(StreamFrame.end)
            writeAllToSocket(fd: fd, data: out)
        }
        defer { server.stop() }

        let remote = TSPRemote(socketPath: server.path, readTimeout: 1, deadline: 30)
        var frames: [Data] = []
        for try await frame in await remote.synthesizeStream(text: "慢一点", voiceID: "taozi", trace: nil) {
            frames.append(frame)
        }
        XCTAssertEqual(frames, [pcm], "慢合成也要完整送达，一帧都不能少")
    }

    /// 誊清员中途断流（EOF，没吐完就关）→ 这一块作废并报错，不当正常结束。
    ///
    /// 这条是 R1「誊清员崩了 → 这块作废」的语义底座：断流必须与「慢」区分开，
    /// 否则真崩溃会被当成慢而重发，掩盖故障。
    func testTruncatedStreamThrows() async throws {
        let server = try TestSocketServer { fd, request in
            guard !request.isEmpty else { return }   // isRunning 的探测连接：连上就走
            if request.range(of: Data("type:status".utf8)) != nil {
                writeAllToSocket(fd: fd, data: Data("state:ready\n".utf8))
                return
            }
            // 吐半截就关：没有结束标志
            writeAllToSocket(fd: fd, data: StreamFrame.chunk(Data(repeating: 1, count: 64)))
        }
        defer { server.stop() }

        let remote = TSPRemote(socketPath: server.path, readTimeout: 1, deadline: 5)
        var frames: [Data] = []
        var thrown: Error?
        do {
            for try await frame in await remote.synthesizeStream(text: "半句", voiceID: "taozi", trace: nil) {
                frames.append(frame)
            }
        } catch {
            thrown = error
        }
        XCTAssertNotNil(thrown, "断流必须报错，不能当念完了")
        XCTAssertEqual(frames.count, 1, "已送出的半截仍要交出去（播报员已收到）")
    }
}
