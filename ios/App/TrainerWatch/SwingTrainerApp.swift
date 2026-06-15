import SwiftUI

@main
struct SwingTrainerApp: App {
    @StateObject private var session = RecordingSession()

    var body: some Scene {
        WindowGroup {
            RootNavView()
                .environmentObject(session)
        }
    }
}

/// 把 NavigationStack 仅限于 .setup 阶段，避免与 phase 切换冲突
struct RootNavView: View {
    @EnvironmentObject var session: RecordingSession
    @State private var path: [StrokeType] = []

    var body: some View {
        switch session.phase {
        case .setup:
            NavigationStack(path: $path) {
                SetupView()
                    .navigationDestination(for: StrokeType.self) { type in
                        StartView(strokeType: type, onStart: {
                            path = []
                            session.strokeType = type
                            session.startRecording()
                        })
                    }
            }
        case .recording: RecordingView()
        case .paused:    PausedView()
        case .done:      SummaryView(onRetry: {
            path = []
        })
        }
    }
}
