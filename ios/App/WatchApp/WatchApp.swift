import SwiftUI

@main
struct ScoreboardWatchApp: App {
    @StateObject private var workoutManager = WorkoutManager()
    @StateObject private var phoneSession  = PhoneSessionManager()
    @StateObject private var matchManager = WatchMatchManager()
    @StateObject private var swingDetector = SwingDetector()
    @StateObject private var audioGate     = AudioGate()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(workoutManager)
                .environmentObject(phoneSession)
                .environmentObject(matchManager)
                .environmentObject(swingDetector)
                .environmentObject(audioGate)
                .onAppear {
                    phoneSession.workoutManager = workoutManager
                    phoneSession.matchManager = matchManager
                    matchManager.configure(workoutManager: workoutManager, phoneSession: phoneSession)
                    matchManager.swingDetector = swingDetector
                    matchManager.audioGate     = audioGate

                    // 连接音频门控与挥拍检测器
                    swingDetector.audioGate = audioGate
                    audioGate.onImpact = { [weak swingDetector] ts in
                        swingDetector?.onAudioImpact(at: ts)
                    }

                    workoutManager.onHeartRate = { [weak phoneSession] bpm, ts in
                        phoneSession?.pushHR(bpm: bpm, ts: ts)
                        matchManager.recordHeartRate(bpm: bpm, timestamp: ts)
                    }
                    phoneSession.applyContextOnLaunch()
                }
        }
    }
}
