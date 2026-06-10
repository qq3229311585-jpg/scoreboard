import SwiftUI

@main
struct ScoreboardWatchApp: App {
    @StateObject private var workoutManager = WorkoutManager()
    @StateObject private var phoneSession  = PhoneSessionManager()
    @StateObject private var matchManager = WatchMatchManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(workoutManager)
                .environmentObject(phoneSession)
                .environmentObject(matchManager)
                .onAppear {
                    phoneSession.workoutManager = workoutManager
                    phoneSession.matchManager = matchManager
                    matchManager.configure(workoutManager: workoutManager, phoneSession: phoneSession)
                    workoutManager.onHeartRate = { [weak phoneSession] bpm, ts in
                        phoneSession?.pushHR(bpm: bpm, ts: ts)
                        matchManager.recordHeartRate(bpm: bpm, timestamp: ts)
                    }
                    // 启动时检查最新的 applicationContext，
                    // 如果手机端有正在进行的比赛就自动跳转到记分页
                    phoneSession.applyContextOnLaunch()
                }
        }
    }
}
