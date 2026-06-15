import SwiftUI

@main
struct ScoreboardWatchApp: App {
    @StateObject private var workoutManager = WorkoutManager()
    @StateObject private var phoneSession  = PhoneSessionManager()
    @StateObject private var matchManager = WatchMatchManager()
    @StateObject private var swingDetector = SwingDetector()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(workoutManager)
                .environmentObject(phoneSession)
                .environmentObject(matchManager)
                .environmentObject(swingDetector)
                .onAppear {
                    phoneSession.workoutManager = workoutManager
                    phoneSession.matchManager = matchManager
                    matchManager.configure(workoutManager: workoutManager, phoneSession: phoneSession)
                    matchManager.swingDetector = swingDetector
                    workoutManager.onHeartRate = { [weak phoneSession] bpm, ts in
                        phoneSession?.pushHR(bpm: bpm, ts: ts)
                        matchManager.recordHeartRate(bpm: bpm, timestamp: ts)
                    }
                    phoneSession.applyContextOnLaunch()
                }
        }
    }
}
