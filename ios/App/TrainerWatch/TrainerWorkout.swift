import HealthKit

/// 极简运动会话管理器。
/// 唯一目的：在采集 IMU 期间维持一个活跃的 HKWorkoutSession，
/// 否则 CMBatchedSensorManager 的 800Hz 高频加速度不会出数据（Apple 要求高频批量
/// 传感器必须在活跃运动会话期间才工作）。不记录心率、不保存训练记录。
///
/// 关键：CMBatchedSensorManager 要求 session 真正进入 .running 状态才出数据。
/// 因此通过 onReady 回调在 .running（或失败）时才通知调用方启动采集，
/// 不能在 startActivity 后立即开流——否则 session 还没 running 就被拒、丢高频数据。
final class TrainerWorkout: NSObject, ObservableObject {
    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    @Published private(set) var isActive = false

    /// 在 session 进入 .running（true）或启动失败（false）时回调一次。
    private var onReady: ((Bool) -> Void)?
    private var readyFired = false
    /// stop() 后为 true——授权回调若晚于 stop 到达，不再启动 session（否则会泄漏一个后台 workout）
    private var stopped = false

    /// 请求授权并启动运动会话。onReady 在主线程回调：true=已 running 可采集，false=失败（仅 100Hz）。
    func start(onReady: @escaping (Bool) -> Void) {
        self.onReady = onReady
        readyFired = false
        stopped = false
        guard HKHealthStore.isHealthDataAvailable() else {
            print("[TrainerWorkout] HealthKit 不可用")
            fireReady(false); return
        }
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        healthStore.requestAuthorization(toShare: share, read: []) { [weak self] _, err in
            guard let self else { return }
            if let err { print("[TrainerWorkout] 授权失败 \(err)") }
            DispatchQueue.main.async { self.beginSession() }
        }
    }

    private func fireReady(_ ok: Bool) {
        guard !readyFired else { return }
        readyFired = true
        let cb = onReady; onReady = nil
        DispatchQueue.main.async { cb?(ok) }
    }

    private func beginSession() {
        guard !stopped else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .badminton
        config.locationType = .indoor
        do {
            session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            builder = session?.associatedWorkoutBuilder()
            builder?.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore,
                                                          workoutConfiguration: config)
            session?.delegate = self
            let now = Date()
            session?.startActivity(with: now)
            builder?.beginCollection(withStart: now) { _, _ in }
            print("[TrainerWorkout] startActivity 已发起，等待 .running")
            // onReady 在 didChangeTo .running 里触发，不在这里
        } catch {
            print("[TrainerWorkout] 启动失败 \(error)")
            fireReady(false)
        }
    }

    func stop() {
        stopped = true
        isActive = false
        guard let session else { return }
        session.end()
    }
}

extension TrainerWorkout: HKWorkoutSessionDelegate {
    func workoutSession(_ session: HKWorkoutSession,
                        didChangeTo to: HKWorkoutSessionState,
                        from: HKWorkoutSessionState,
                        date: Date) {
        switch to {
        case .running:
            print("[TrainerWorkout] session 已进入 .running，可采集 800Hz")
            isActive = true
            fireReady(true)
        case .ended:
            builder?.endCollection(withEnd: date) { [weak self] _, _ in
                self?.builder?.finishWorkout { [weak self] _, _ in
                    DispatchQueue.main.async {
                        self?.session = nil
                        self?.builder = nil
                    }
                }
            }
        default:
            break
        }
    }

    func workoutSession(_ session: HKWorkoutSession, didFailWithError error: Error) {
        print("[TrainerWorkout] 会话出错 \(error)")
        fireReady(false)
    }
}
