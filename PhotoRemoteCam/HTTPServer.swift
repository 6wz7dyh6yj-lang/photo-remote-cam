import Foundation
import Network

/// 极简 HTTP 服务（基于 Network.framework，零第三方依赖）
/// 供电脑端通过 WiFi 调用：探测、对焦、预览、全分辨率拍照
final class HTTPServer: ObservableObject {
    @Published var status: String = "未启动"
    @Published var boundPort: UInt16 = 0
    private var listener: NWListener?
    private let port: UInt16 = 8080
    private var cameraProvider: (() -> CameraManager?)?

    func start(cameraProvider: @escaping () -> CameraManager?) {
        self.cameraProvider = cameraProvider
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host.ipv4(.any),
            port: NWEndpoint.Port(rawValue: port)!)
        do {
            listener = try NWListener(using: params)
        } catch {
            DispatchQueue.main.async { self.status = "启动失败: \(error.localizedDescription)" }
            return
        }
        listener?.newConnectionHandler = { [weak self] conn in
            self?.handle(connection: conn)
        }
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    self?.status = "运行中 :\(self?.port ?? 8080)"
                    self?.boundPort = self?.port ?? 8080
                }
            case .failed(let err):
                DispatchQueue.main.async { self?.status = "失败: \(err.localizedDescription)" }
            default:
                break
            }
        }
        listener?.start(queue: .global(qos: .userInitiated))
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        var buffer = Data()
        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let d = data, !d.isEmpty { buffer.append(d) }
                if let req = HTTPServer.parseRequest(buffer) {
                    self.route(req) { (code, contentType, body) in
                        self.respond(connection, code: code, contentType: contentType, body: body)
                    }
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    readMore()
                }
            }
        }
        readMore()
    }

    // MARK: - 路由
    private func route(_ req: HTTPRequest, completion: @escaping (Int, String, Data) -> Void) {
        let path = req.path.components(separatedBy: "?").first ?? req.path
        switch (req.method, path) {
        case ("GET", "/ping"):
            json(["ok": true, "service": "PhotoRemoteCam", "version": "1.0"], code: 200, completion: completion)

        case ("GET", "/status"):
            let cam = cameraProvider?()
            json([
                "ok": true,
                "status": cam?.status ?? "unknown",
                "resolution": cam?.resolutionText ?? "",
                "focus": cam?.focusText ?? "",
                "shots": cam?.shotCount ?? 0,
                "battery": UIDevice.current.batteryLevel
            ], code: 200, completion: completion)

        case ("GET", "/preview"):
            let jpeg = cameraProvider?().flatMap { $0.currentPreviewJPEG() } ?? Data()
            completion(200, "image/jpeg", jpeg)

        case ("POST", "/focus"):
            // body: {"x":0.5,"y":0.5} 可选；空则中心对焦
            var x: Float? = nil, y: Float? = nil
            if let obj = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] {
                if let vx = obj["x"] as? NSNumber, let vy = obj["y"] as? NSNumber {
                    x = vx.floatValue; y = vy.floatValue
                }
            }
            cameraProvider?()?.triggerFocus(x: x, y: y, wait: true)
            json(["ok": true], code: 200, completion: completion)

        case ("POST", "/capture"):
            // 拍照前先触发一次自动对焦，保证清晰
            guard let cam = cameraProvider?() else {
                json(["ok": false, "error": "camera not ready"], code: 503, completion: completion)
                return
            }
            cam.triggerFocus(x: nil, y: nil, wait: true)
            // 等对焦稳定后再拍
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.4) {
                cam.captureFullResolution { data in
                    if let jpeg = data {
                        completion(200, "image/jpeg", jpeg)
                    } else {
                        self.json(["ok": false, "error": "capture failed"], code: 500, completion: completion)
                    }
                }
            }

        default:
            json(["ok": false, "error": "not found"], code: 404, completion: completion)
        }
    }

    // MARK: - HTTP 解析与响应
    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private static func parseRequest(_ data: Data) -> HTTPRequest? {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        guard let sepRange = data.range(of: separator) else { return nil }
        let headerData = data[data.startIndex..<sepRange.lowerBound]
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2 {
                headers[String(kv[0]).lowercased()] = String(kv[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = sepRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let body = Data(data[bodyStart..<(bodyStart + contentLength)])
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private func json(_ dict: [String: Any], code: Int, completion: (Int, String, Data) -> Void) {
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        completion(code, "application/json; charset=utf-8", data)
    }

    private func respond(_ connection: NWConnection, code: Int, contentType: String, body: Data) {
        let reason = code == 200 ? "OK" : (code == 404 ? "Not Found" : "Error")
        var header = "HTTP/1.1 \(code) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "Access-Control-Allow-Origin: *\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
