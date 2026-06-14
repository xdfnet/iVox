import Foundation
import iVoxKit

struct MediaController {
    private let config: MediaControlConfig

    init(config: MediaControlConfig) {
        self.config = config
    }

    func pause() async {
        Log.info("媒体控制: 暂停")
        await send(config.pausePath)
    }

    func resume() async {
        Log.info("媒体控制: 恢复")
        Log.info("---------------------END----------------------")
        await send(config.resumePath)
    }

    private func send(_ path: String) async {
        guard config.enabled else { return }
        guard let url = URL(string: config.baseURL + path) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                Log.error("媒体控制返回非 200: \(http.statusCode)")
            }
        } catch {
            Log.error("媒体控制请求失败: \(error.localizedDescription)")
        }
    }
}
