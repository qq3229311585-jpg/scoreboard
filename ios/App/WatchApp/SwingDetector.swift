import Foundation
import CoreMotion

/// 单次挥拍事件的原始特征，用于后续动作分类训练
struct SwingEvent: Codable {
    let ts: Double        // 事件结束时刻（ProcessInfo.systemUptime 秒）
    let dur: Double       // 持续时长（秒）
    let peakGyro: Double  // 事件内陀螺仪合向量²最大值（rad²/s²）
    let peakAccel: Double // 事件内线性加速度最大值（g）
}

final class SwingDetector: ObservableObject {
    @Published var swingCount = 0
    @Published var events: [SwingEvent] = []   // 本场/本次采集的所有事件

    /// 挂载音频门控；nil 表示无音频确认（直接计数）
    weak var audioGate: AudioGate?

    private let processingQueue = DispatchQueue(label: "SwingDetector.q", qos: .userInteractive)
    private var sensorManager: CMBatchedSensorManager?
    private var isRunning = false

    // ──────────────────────────────────────────────────────
    // 算法参数
    // ──────────────────────────────────────────────────────
    private let targetHz: Double = 100

    // 进入"挥拍中"需同时满足：
    //   gyro 合向量² > highGyro  AND  线性加速度 > accelStart
    // accelStart 过滤"抬腕看表"：看表时手腕转动加速度通常 <1g，真实挥拍 >2g
    private let highGyroThreshold: Double = 10.0   // rad²/s²（↓ 从15，捕捉正手右区轻推）
    private let lowGyroThreshold: Double  =  3.0   // rad²/s²，陀螺仪平息阈值
    private let accelStartThreshold: Double = 1.5  // g（userAcceleration，仅用于开始事件）

    private let quietDuration: Double    = 0.20    // 连续低于 low 多久算事件结束（↑ 避免头顶后场双计）
    private let minEventDuration: Double = 0.05    // 过短 = 噪声
    private let maxEventDuration: Double = 1.8     // 过长 = 不是挥拍
    private let cooldown: Double         = 0.8     // 上次计数结束后的冷却（↓ 支持快速来回）
    private let audioConfirmWindow: Double = 0.6   // 等待音频确认的时间窗口（秒）

    // ──────────────────────────────────────────────────────
    // 状态机变量（仅在 processingQueue 上读写）
    // ──────────────────────────────────────────────────────
    private enum SwingState { case idle, swinging, quieting }
    private var state: SwingState = .idle
    private var swingStartTime: Double = 0
    private var quietStartTime:  Double = 0
    private var lastCountTime:   Double = 0
    private var sampleCounter = 0

    // 音频确认 pending：gyro 事件已完成但在等音频
    private var pendingEventTime: Double = 0
    private var pendingDeadline:  Double = 0

    // 事件内峰值追踪
    private var currentPeakGyro: Double = 0
    private var currentPeakAccel: Double = 0
    private var currentEventDur: Double = 0

    func start() {
        processingQueue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self._resetState()
        }
        guard CMBatchedSensorManager.isDeviceMotionSupported else {
            startFallback(); return
        }
        sensorManager = CMBatchedSensorManager()
        guard let sm = sensorManager else { return }
        Task {
            do {
                for try await batch in sm.deviceMotionUpdates() {
                    let alive = processingQueue.sync { isRunning }
                    guard alive else { break }
                    processingQueue.async { [weak self] in self?.processBatch(batch) }
                }
            } catch {
                print("[SwingDetector] batch error: \(error)，切换 fallback")
                startFallback()
            }
        }
        print("[SwingDetector] 启动 (CMBatchedSensorManager)")
    }

    func stop() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
        }
        sensorManager = nil
        fallbackManager?.stopDeviceMotionUpdates()
        fallbackManager = nil
        print("[SwingDetector] 停止，总挥拍=\(swingCount)")
    }

    func reset() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self._resetState()
            DispatchQueue.main.async {
                self.swingCount = 0
                self.events.removeAll()
            }
        }
    }

    /// AudioGate 检测到击球声时调用（可从任意线程调用）
    func onAudioImpact(at ts: TimeInterval) {
        processingQueue.async { [weak self] in
            self?._onAudioImpact(at: ts)
        }
    }

    // ──────────────────────────────────────────────────────
    // MARK: - 内部（均在 processingQueue 上执行）
    // ──────────────────────────────────────────────────────

    private func _resetState() {
        state = .idle
        swingStartTime = 0
        quietStartTime = 0
        lastCountTime = 0
        pendingEventTime = 0
        pendingDeadline = 0
        currentPeakGyro = 0
        currentPeakAccel = 0
        currentEventDur = 0
        sampleCounter = 0
    }

    private func processBatch(_ batch: [CMDeviceMotion]) {
        for sample in batch {
            sampleCounter += 1
            guard sampleCounter % 2 == 0 else { continue }   // 200Hz → 100Hz
            let r = sample.rotationRate
            let a = sample.userAcceleration
            let gyroSq   = r.x*r.x + r.y*r.y + r.z*r.z
            let accelMag = (a.x*a.x + a.y*a.y + a.z*a.z).squareRoot()
            processSample(gyroSq: gyroSq, accelMag: accelMag, ts: sample.timestamp)
        }
    }

    private func processSample(gyroSq: Double, accelMag: Double, ts: TimeInterval) {
        // 检查 pending 超时（音频门控开启但超时无击球声）
        if pendingDeadline > 0 && ts > pendingDeadline {
            let gate = audioGate   // 在 processingQueue 读（weak ref 安全）
            if gate?.isEnabled == true {
                print("[SwingDetector] audio 超时无击球声，丢弃")
            }
            pendingEventTime = 0
            pendingDeadline = 0
        }

        switch state {
        case .idle:
            guard (ts - lastCountTime) > cooldown else { return }
            if gyroSq > highGyroThreshold && accelMag > accelStartThreshold {
                state = .swinging
                swingStartTime = ts
                currentPeakGyro = gyroSq
                currentPeakAccel = accelMag
            }

        case .swinging:
            if gyroSq > currentPeakGyro { currentPeakGyro = gyroSq }
            if accelMag > currentPeakAccel { currentPeakAccel = accelMag }
            if gyroSq < lowGyroThreshold {
                state = .quieting
                quietStartTime = ts
            }

        case .quieting:
            if gyroSq > highGyroThreshold {
                // 陀螺仪反弹（随挥或击球后大幅减速再加速），继续同一事件
                state = .swinging
            } else if (ts - quietStartTime) >= quietDuration {
                let duration = ts - swingStartTime
                if duration >= minEventDuration && duration <= maxEventDuration {
                    currentEventDur = duration
                    onSwingEventCompleted(at: ts)
                }
                state = .idle
                currentPeakGyro = 0
                currentPeakAccel = 0
            }
        }
    }

    private func onSwingEventCompleted(at ts: TimeInterval) {
        let gate = audioGate
        guard let gate, gate.isEnabled else {
            // 无音频门控，直接计数
            commitCount(eventTime: ts)
            return
        }
        // 有音频门控：先查历史缓冲
        if gate.hasImpactNear(ts, window: audioConfirmWindow) {
            commitCount(eventTime: ts)
        } else {
            // 等待后续音频
            pendingEventTime = ts
            pendingDeadline  = ts + audioConfirmWindow
            print("[SwingDetector] gyro 事件完成，等待音频确认 deadline=\(String(format:"%.3f",pendingDeadline))")
        }
    }

    private func _onAudioImpact(at ts: TimeInterval) {
        guard pendingDeadline > 0 && ts <= pendingDeadline else { return }
        commitCount(eventTime: pendingEventTime)
        pendingEventTime = 0
        pendingDeadline  = 0
    }

    private func commitCount(eventTime: TimeInterval) {
        lastCountTime = eventTime
        let ev = SwingEvent(ts: eventTime, dur: currentEventDur,
                            peakGyro: currentPeakGyro, peakAccel: currentPeakAccel)
        DispatchQueue.main.async {
            self.swingCount += 1
            self.events.append(ev)
        }
        print("[SwingDetector] 计数=\(swingCount+1) dur=\(String(format:"%.2f",ev.dur))s peakGyro=\(String(format:"%.1f",ev.peakGyro)) peakAccel=\(String(format:"%.2f",ev.peakAccel))g")
    }

    // ──────────────────────────────────────────────────────
    // MARK: - CMMotionManager fallback（旧 watchOS / 模拟器）
    // ──────────────────────────────────────────────────────

    private var fallbackManager: CMMotionManager?

    private func startFallback() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.isRunning = true
            self._resetState()
        }
        let mm = CMMotionManager()
        mm.deviceMotionUpdateInterval = 1.0 / targetHz
        fallbackManager = mm
        guard mm.isDeviceMotionAvailable else {
            print("[SwingDetector] 设备不支持 motion")
            return
        }
        mm.startDeviceMotionUpdates(to: OperationQueue()) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.processingQueue.async {
                guard self.isRunning else { return }
                let r = motion.rotationRate
                let a = motion.userAcceleration
                let gyroSq   = r.x*r.x + r.y*r.y + r.z*r.z
                let accelMag = (a.x*a.x + a.y*a.y + a.z*a.z).squareRoot()
                self.processSample(gyroSq: gyroSq, accelMag: accelMag, ts: motion.timestamp)
            }
        }
        print("[SwingDetector] 启动 (CMMotionManager fallback)")
    }
}
