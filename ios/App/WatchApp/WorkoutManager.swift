import HealthKit
import Combine

class WorkoutManager: NSObject, ObservableObject {
    let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    @Published var heartRate: Double = 0
    @Published var isActive = false
    @Published var sportName = "比赛中"

    /// 心率更新回调 → PhoneSessionManager 用来转发给 iPhone
    var onHeartRate: ((Int, Double) -> Void)?

    // MARK: - 授权
    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else { completion(false); return }
        let share: Set<HKSampleType> = [HKObjectType.workoutType(),
                                         HKQuantityType(.heartRate)]
        let read:  Set<HKObjectType> = [HKObjectType.workoutType(),
                                         HKQuantityType(.heartRate)]
        healthStore.requestAuthorization(toShare: share, read: read) { ok, _ in
            DispatchQueue.main.async { completion(ok) }
        }
    }

    // MARK: - 开始
    func start(sport: String) {
        if isActive {
            return
        }
        sportName = displayName(for: sport)
        requestAuthorization { [weak self] _ in
            guard let self else { return }
            let config = HKWorkoutConfiguration()
            config.activityType = activityType(for: sport)
            config.locationType  = .indoor
            do {
                self.session = try HKWorkoutSession(healthStore: self.healthStore,
                                                    configuration: config)
                self.builder = self.session?.associatedWorkoutBuilder()
                self.builder?.dataSource = HKLiveWorkoutDataSource(
                    healthStore: self.healthStore, workoutConfiguration: config)
                self.session?.delegate = self
                self.builder?.delegate = self
                let now = Date()
                self.session?.startActivity(with: now)
                self.builder?.beginCollection(withStart: now) { _, _ in }
                DispatchQueue.main.async {
                    self.isActive = true
                    self.heartRate = 0
                }
            } catch {
                print("[WorkoutManager] start error: \(error)")
            }
        }
    }

    // MARK: - 结束
    /// 让 workout session 收尾。会发起 end()，真正的 endCollection/finishWorkout
    /// 在 didChangeTo .ended 回调里完成；这里不直接置空 session/builder，
    /// 否则系统稍后调用的回调拿不到对象，训练记录会"烂尾"。
    func stop() {
        guard let session else { return }
        session.end()
        DispatchQueue.main.async {
            self.isActive = false
        }
    }

    private func displayName(for sport: String) -> String {
        switch sport {
        case "badminton":    return "羽毛球"
        case "tabletennis":  return "乒乓球"
        case "tennis":       return "网球"
        case "basketball":   return "篮球"
        case "football":     return "足球"
        default:             return sport
        }
    }

    private func activityType(for sport: String) -> HKWorkoutActivityType {
        switch sport {
        case "badminton":    return .badminton
        case "tabletennis":  return .tableTennis
        case "tennis":       return .tennis
        case "basketball":   return .basketball
        case "football":     return .soccer
        default:             return .badminton
        }
    }
}

// MARK: - HKWorkoutSessionDelegate
extension WorkoutManager: HKWorkoutSessionDelegate {
    func workoutSession(_ session: HKWorkoutSession,
                        didChangeTo to: HKWorkoutSessionState,
                        from: HKWorkoutSessionState,
                        date: Date) {
        if to == .ended {
            builder?.endCollection(withEnd: date) { [weak self] _, _ in
                self?.builder?.finishWorkout { [weak self] _, _ in
                    DispatchQueue.main.async {
                        self?.session = nil
                        self?.builder = nil
                    }
                }
            }
        }
    }
    func workoutSession(_ session: HKWorkoutSession, didFailWithError error: Error) {
        print("[WorkoutManager] session error: \(error)")
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate
extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ builder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(_ builder: HKLiveWorkoutBuilder,
                        didCollectDataOf types: Set<HKSampleType>) {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate),
              types.contains(hrType) else { return }
        let bpm = builder.statistics(for: hrType)?
            .mostRecentQuantity()?
            .doubleValue(for: HKUnit(from: "count/min")) ?? 0
        guard bpm > 0 else { return }
        let ts = Date().timeIntervalSince1970 * 1000
        DispatchQueue.main.async { self.heartRate = bpm }
        onHeartRate?(Int(bpm.rounded()), ts)
    }
}
