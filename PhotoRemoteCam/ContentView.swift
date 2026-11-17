import SwiftUI

struct ContentView: View {
    @EnvironmentObject var camera: CameraManager
    @EnvironmentObject var server: HTTPServer

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    // 连接信息卡片
                    VStack(spacing: 6) {
                        Text("电脑端连接地址").font(.caption).foregroundColor(.secondary)
                        Text(localIP).font(.system(.title2, design: .monospaced)).bold()
                            .textSelection(.enabled)
                        Text("端口 8080 · 确保手机与电脑在同一 WiFi").font(.caption).foregroundColor(.secondary)
                        HStack(spacing: 4) {
                            Circle().fill(server.status.hasPrefix("运行") ? .green : .orange).frame(width: 8, height: 8)
                            Text(server.status).font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))

                    // 预览
                    ZStack {
                        if let img = camera.previewImage {
                            Image(uiImage: img).resizable().scaledToFit()
                        } else {
                            VStack {
                                Image(systemName: "camera.fill").font(.largeTitle).foregroundColor(.secondary)
                                Text("相机预览").foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(height: 280)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.black))

                    // 状态
                    VStack(alignment: .leading, spacing: 8) {
                        StatusRow(icon: "camera.aperture", label: "相机", value: camera.status)
                        StatusRow(icon: "photo", label: "分辨率", value: camera.resolutionText)
                        StatusRow(icon: "focusinterface", label: "对焦", value: camera.focusText)
                        StatusRow(icon: "number", label: "已拍张数", value: "\(camera.shotCount)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))

                    // 测试按钮
                    HStack(spacing: 12) {
                        Button {
                            camera.triggerFocus(wait: true)
                        } label: {
                            Label("测试对焦", systemImage: "focusinterface")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            camera.captureFullResolution { _ in }
                        } label: {
                            Label("测试拍照", systemImage: "camera")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Text("本 App 保持在前台即可；电脑端点“开始拍摄”会自动调用对焦与拍照。")
                        .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                }
                .padding()
            }
            .navigationTitle("远程拍摄相机")
        }
        .onAppear {
            server.start { camera }
        }
    }

    private var localIP: String {
        var address = "未获取到 IP"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return address }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            if flags & IFF_UP == 0 { continue }
            let family = p.pointee.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: p.pointee.ifa_name)
                if name == "en0" || name.hasPrefix("en") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(p.pointee.ifa_addr,
                                socklen_t(p.pointee.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, 0, NI_NUMERICHOST)
                    let ip = String(cString: hostname)
                    if ip.hasPrefix("192.168") || ip.hasPrefix("10.") || ip.hasPrefix("172.") {
                        return ip
                    }
                }
            }
        }
        return address
    }
}

struct StatusRow: View {
    let icon: String
    let label: String
    let value: String
    var body: some View {
        HStack {
            Image(systemName: icon).foregroundColor(.accentColor).frame(width: 24)
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).bold().lineLimit(1)
        }
    }
}
