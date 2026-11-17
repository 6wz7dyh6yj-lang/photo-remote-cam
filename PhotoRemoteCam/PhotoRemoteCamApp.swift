import SwiftUI

@main
struct PhotoRemoteCamApp: App {
    @StateObject private var camera = CameraManager()
    @StateObject private var server = HTTPServer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(camera)
                .environmentObject(server)
        }
    }
}
