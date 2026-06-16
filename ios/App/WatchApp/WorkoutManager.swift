import HealthKit
import Combine

class WorkoutManager: NSObject, ObservableObject {
    let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var heartRateQuery: HKAnchoredObjectQuery?
    private var heartRateQueryAnchor: HKQueryAnchor?
    private var lastHeartRateSampleDate: Date?

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

    /// 是否读取/上报心率。false 时 workout 照常跑（保后台保活、记分稳），但不开心率流、不回报心率。
    private var trackHR = true

    /// 在 workout 已活跃时切换心率追踪状态（连续开赛、上一场没停干净时用）
    private func updateHRTracking(_ track: Bool) {
        guard track != trackHR else { return }
        trackHR = track
        if track {
            startHeartRateStreaming(from: Date())
        } else {
            stopHeartRateStreaming()
            DispatchQueue.main.async { self.heartRate = 0 }
        }
    }

    // MARK: - 开始
    func start(sport: String, trackHR: Bool = true) {
        if isActive {
            // 上一场 workout 还活着（连续开赛没干净结束）：至少把心率追踪状态更新对，
            // 否则会沿用上一场的 trackHR（典型 bug：上一场含 HJT 在采心率，下一场不含也继续采）。
            updateHRTracking(trackHR)
            return
        }
        self.trackHR = trackHR
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
                self.lastHeartRateSampleDate = nil
                self.heartRateQueryAnchor = nil
                self.session?.startActivity(with: now)
                self.builder?.beginCollection(withStart: now) { _, _ in }
                if trackHR { self.startHeartRateStreaming(from: now) }
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
        stopHeartRateStreaming()
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

    private func startHeartRateStreaming(from startDate: Date) {
        guard let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) else { return }
        stopHeartRateStreaming()
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: nil, options: .strictStartDate)
        let query = HKAnchoredObjectQuery(type: heartRateType,
                                          predicate: predicate,
                                          anchor: heartRateQueryAnchor,
                                          limit: HKObjectQueryNoLimit) { [weak self] _, samples, _, anchor, _ in
            self?.heartRateQueryAnchor = anchor
            self?.handleHeartRateSamples(samples)
        }
        query.updateHandler = { [weak self] _, samples, _, anchor, _ in
            self?.heartRateQueryAnchor = anchor
            self?.handleHeartRateSamples(samples)
        }
        heartRateQuery = query
        healthStore.execute(query)
    }

    private func stopHeartRateStreaming() {
        if let heartRateQuery {
            healthStore.stop(heartRateQuery)
        }
        heartRateQuery = nil
        heartRateQueryAnchor = nil
    }

    private func handleHeartRateSamples(_ samples: [HKSample]?) {
        guard let quantitySamples = samples as? [HKQuantitySample], !quantitySamples.isEmpty else { return }
        let latestSample = quantitySamples.max(by: { $0.endDate < $1.endDate })
        guard let latestSample else { return }
        let bpm = latestSample.quantity.doubleValue(for: HKUnit(from: "count/min"))
        publishHeartRate(bpm, at: latestSample.endDate)
    }

    private func publishHeartRate(_ bpm: Double, at date: Date = Date()) {
        guard trackHR else { return }   // 不追踪佩戴者时不上报心率（builder 仍会采集，但这里拦掉）
        guard bpm > 0 else { return }
        if let lastHeartRateSampleDate, date <= lastHeartRateSampleDate {
            return
        }
        lastHeartRateSampleDate = date
        let ts = date.timeIntervalSince1970 * 1000
        DispatchQueue.main.async { self.heartRate = bpm }
        onHeartRate?(Int(bpm.rounded()), ts)
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
                        self?.stopHeartRateStreaming()
                        self?.session = nil
                        self?.builder = nil
                    }
                }
            }
        }
    }
    func workoutSession(_ session: HKWorkoutSession, didFailWithError error: Error) {
        print("[WorkoutManager] session error: \(error)")
        stopHeartRateStreaming()
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
        publishHeartRate(bpm)
    }
}
