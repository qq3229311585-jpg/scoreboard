import Foundation
import CoreMotion

/// 双流 IMU 录制器。
/// - accel_raw : CMBatchedSensorManager，最高 800Hz，原始加速度（含重力）
/// - device_motion : CMMotionManager，100Hz，传感器融合（去重力加速度 + 陀螺仪 + 重力矢量 + 姿态角）
final class StreamRecorder: ObservableObject {
    @Published private(set) var accelCount  = 0   // accel_raw 采样点数
    @Published private(set) var motionCount = 0   // device_motion 采样点数
    @Published private(set) var accelStreamActive = false  // 800Hz 流是否真的在出数据（收到首批后为 true）

    private var isRecording = false

    // 平铺存储 — accel_raw stride 4:  t, ax, ay, az
    private var accelSamples:  [Float] = []
    // 平铺存储 — device_motion stride 13: t, uax, uay, uaz, gx, gy, gz, grav_x, grav_y, grav_z, pitch, roll, yaw
    private var motionSamples: [Float] = []
    // 暂停区间（相对录制开始的秒数），写入 JSON 供分析时区分"暂停"和"丢数据"
    private var pauses: [(Float, Float)] = []
    private var pauseStartT: Float? = nil

    private var batched          = CMBatchedSensorManager()
    private let motion           = CMMotionManager()
    private var batchedTask:     Task<Void, Never>?
    private var startDate:       Date?
    private var startUptime:     TimeInterval = 0  // ProcessInfo.systemUptime 基准，用于 CMBatchedSensorManager
    private let motionQueue      = OperationQueue()

    init() {
        motionQueue.name = "imu.motion"
        motionQueue.maxConcurrentOperationCount = 1
    }

    // 向下兼容 — SummaryView 里的简单计数引用
    var sampleCount: Int { accelCount }

    func start() {
        accelSamples.removeAll();  accelSamples.reserveCapacity(240_000 * 4)   // 800Hz × 5min
        motionSamples.removeAll(); motionSamples.reserveCapacity(30_000 * 13)  // 100Hz × 5min
        pauses.removeAll(); pauseStartT = nil
        accelCount = 0; motionCount = 0
        accelStreamActive = false
        startDate   = Date()
        startUptime = ProcessInfo.processInfo.systemUptime
        isRecording = true
        beginUpdates()
    }

    /// 800Hz 流补启。workout session 迟到 .running 时调用：
    /// 首次启动若在 session running 之前，流会被系统拒掉，这里用全新实例重开。
    func ensureAccelStream() {
        guard isRecording, !accelStreamActive else { return }
        startAccelStream()
    }

    private func beginUpdates() {
        guard startDate != nil else { return }
        startAccelStream()
        startMotionStream()
    }

    // ── CMBatchedSensorManager：800Hz 原始加速度 ──────────────────────────
    private func startAccelStream() {
        guard CMBatchedSensorManager.isAccelerometerSupported else {
            print("[StreamRecorder] CMBatchedSensorManager.isAccelerometerSupported = false")
            return
        }
        // 停掉可能残留的旧流；stop 后的实例不再出数据，必须换新实例
        batchedTask?.cancel(); batchedTask = nil
        batched.stopAccelerometerUpdates()
        batched = CMBatchedSensorManager()

        let uptimeBase = startUptime
        batchedTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                for try await batch in self.batched.accelerometerUpdates() {
                    if Task.isCancelled { break }
                    for s in batch {
                        // .timestamp = 设备启动后秒数；减去录制开始时的 uptime 得到相对时间
                        let t = Float(max(0, s.timestamp - uptimeBase))
                        self.accelSamples.append(t)
                        self.accelSamples.append(Float(s.acceleration.x))
                        self.accelSamples.append(Float(s.acceleration.y))
                        self.accelSamples.append(Float(s.acceleration.z))
                    }
                    // 加速度按批到达，每批都刷新计数（不能用 n%800，批长不对齐会永远漏掉）
                    let n = self.accelSamples.count / 4
                    DispatchQueue.main.async { self.accelCount = n; self.accelStreamActive = true }
                }
                // 流正常结束后写入最终计数，确保 Summary 显示准确
                let final = self.accelSamples.count / 4
                DispatchQueue.main.async { self.accelCount = final }
            } catch {
                print("[StreamRecorder] accelerometerUpdates 出错（800Hz 需活跃运动会话）: \(error)")
                DispatchQueue.main.async { self.accelStreamActive = false }
            }
        }
    }

    // ── CMMotionManager：100Hz 传感器融合数据 ─────────────────────────────
    private func startMotionStream() {
        let motionUptimeBase = startUptime
        motion.deviceMotionUpdateInterval = 1.0 / 100.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] d, _ in
            guard let self, let d else { return }
            // .timestamp = 硬件采样时刻（开机秒数），与 accel_raw 同一时钟，两流可毫秒级对齐
            let t = Float(max(0, d.timestamp - motionUptimeBase))
            self.motionSamples.append(t)
            self.motionSamples.append(Float(d.userAcceleration.x))
            self.motionSamples.append(Float(d.userAcceleration.y))
            self.motionSamples.append(Float(d.userAcceleration.z))
            self.motionSamples.append(Float(d.rotationRate.x))
            self.motionSamples.append(Float(d.rotationRate.y))
            self.motionSamples.append(Float(d.rotationRate.z))
            self.motionSamples.append(Float(d.gravity.x))
            self.motionSamples.append(Float(d.gravity.y))
            self.motionSamples.append(Float(d.gravity.z))
            self.motionSamples.append(Float(d.attitude.pitch))
            self.motionSamples.append(Float(d.attitude.roll))
            self.motionSamples.append(Float(d.attitude.yaw))
            let n = self.motionSamples.count / 13
            if n % 100 == 0 {
                DispatchQueue.main.async { self.motionCount = n }
            }
        }
    }

    private func stopUpdates() {
        batchedTask?.cancel(); batchedTask = nil
        batched.stopAccelerometerUpdates()
        motion.stopDeviceMotionUpdates()
    }

    func pause() {
        guard isRecording else { return }
        isRecording = false
        pauseStartT = Float(max(0, ProcessInfo.processInfo.systemUptime - startUptime))
        stopUpdates()
        DispatchQueue.main.async { self.accelStreamActive = false }
    }

    func resume() {
        // 防御：从未真正 start 过（准备阶段被暂停等异常时序）就当作全新开始
        guard startDate != nil else { start(); return }
        if let ps = pauseStartT {
            let pe = Float(max(0, ProcessInfo.processInfo.systemUptime - startUptime))
            pauses.append((ps, pe))
            pauseStartT = nil
        }
        isRecording = true
        beginUpdates()   // startAccelStream 内部会换新 CMBatchedSensorManager 实例
    }

    func stop() {
        isRecording = false
        stopUpdates()
        pauseStartT = nil
        let na = accelSamples.count  / 4
        let nm = motionSamples.count / 13
        DispatchQueue.main.async {
            self.accelCount = na; self.motionCount = nm
            self.accelStreamActive = false
        }
    }

    func reset() {
        accelSamples.removeAll(); motionSamples.removeAll()
        pauses.removeAll(); pauseStartT = nil
        accelCount = 0; motionCount = 0; startDate = nil
        isRecording = false; accelStreamActive = false
    }

    /// 采样数据快照。在录制已停止（.done 阶段）的主线程调用，
    /// 之后写文件在后台线程用快照进行，与"再来一组"重新开始录制互不干扰。
    struct Snapshot {
        let accel:  [Float]
        let motion: [Float]
        let pauses: [(Float, Float)]
    }

    func snapshot() -> Snapshot {
        Snapshot(accel: accelSamples, motion: motionSamples, pauses: pauses)
    }

    /// 将快照序列化为 JSON 文件（在后台线程调用，只读快照，不碰活动数组）。
    func writeToTempFile(_ snap: Snapshot, strokeType: String, startEpochMs: Double) -> URL? {
        let accelSamples  = snap.accel
        let motionSamples = snap.motion
        let na = accelSamples.count  / 4
        let nm = motionSamples.count / 13
        guard na > 0 || nm > 0 else { return nil }

        let fileName = "imu_\(Int64(startEpochMs))_\(strokeType).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }

        func w(_ s: String) { handle.write(Data(s.utf8)) }

        // ── 文件头 ──
        w("{\"version\":3,\"strokeType\":\"\(strokeType)\",\"startEpochMs\":\(Int64(startEpochMs))")
        let pausesJSON = snap.pauses.map { "[\(f3($0.0)),\(f3($0.1))]" }.joined(separator: ",")
        w(",\"pauses\":[\(pausesJSON)]")
        w(",\"streams\":{")

        // ── accel_raw ──
        w("\"accel_raw\":{\"hz\":800,\"sampleCount\":\(na)")
        w(",\"columns\":[\"t\",\"ax\",\"ay\",\"az\"],\"samples\":[")
        var buf = ""; buf.reserveCapacity(8_000)
        for i in 0..<na {
            if i > 0 { buf.append(",") }
            let b = i * 4
            buf += "[\(f3(accelSamples[b])),\(f4(accelSamples[b+1])),\(f4(accelSamples[b+2])),\(f4(accelSamples[b+3]))]"
            if buf.count > 6_000 { w(buf); buf.removeAll(keepingCapacity: true) }
        }
        if !buf.isEmpty { w(buf) }
        w("]},")  // ] 关闭 samples, } 关闭 accel_raw, , 分隔符

        // ── device_motion ──
        w("\"device_motion\":{\"hz\":100,\"sampleCount\":\(nm)")
        w(",\"columns\":[\"t\",\"uax\",\"uay\",\"uaz\",\"gx\",\"gy\",\"gz\",\"grav_x\",\"grav_y\",\"grav_z\",\"pitch\",\"roll\",\"yaw\"],\"samples\":[")
        buf.removeAll(keepingCapacity: true)
        for i in 0..<nm {
            if i > 0 { buf.append(",") }
            let b = i * 13
            buf += "[\(f3(motionSamples[b])),\(f4(motionSamples[b+1])),\(f4(motionSamples[b+2])),\(f4(motionSamples[b+3])),\(f4(motionSamples[b+4])),\(f4(motionSamples[b+5])),\(f4(motionSamples[b+6])),\(f4(motionSamples[b+7])),\(f4(motionSamples[b+8])),\(f4(motionSamples[b+9])),\(f4(motionSamples[b+10])),\(f4(motionSamples[b+11])),\(f4(motionSamples[b+12]))]"
            if buf.count > 6_000 { w(buf); buf.removeAll(keepingCapacity: true) }
        }
        if !buf.isEmpty { w(buf) }
        w("]}}}")  // ] 关闭 device_motion.samples, } 关闭 device_motion, } 关闭 streams, } 关闭 root

        try? handle.close()
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func f3(_ v: Float) -> String { String(format: "%.3f", v) }
    private func f4(_ v: Float) -> String { String(format: "%.4f", v) }
}
