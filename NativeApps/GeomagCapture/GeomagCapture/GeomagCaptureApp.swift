import SwiftUI

@main
struct GeomagCaptureApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder = MotionRecorder()

    var body: some Scene {
        WindowGroup {
            ContentView(recorder: recorder)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background, recorder.isRecording {
                Task {
                    await recorder.stopRecording(
                        reason: "App 进入后台，已自动停止并保存当前数据"
                    )
                }
            }
        }
    }
}
