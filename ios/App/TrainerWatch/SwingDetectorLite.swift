import Foundation
import CoreMotion

/// 双流 IMU 录制器。
/// - accel_raw : CMBatchedSensorManager，最高 800Hz，原始加速度（含重力）
/// - device_motion : CMMotionManager，100Hz，传感器融合（去重力加速度 + 陀螺仪 + 重力矢量 + 姿态角）
final class StreamRecorder: ObservableObject {
    @Published private(set) var accelCount  = 0   // accel_raw 采样点数
    @Published private(set) var motionCount = 0   // device_motion 采样点数

    // 平铺存储 — accel_raw stride 4:  t, ax, ay, az
    private var accelSamples:  [Float] = []
    // 平铺存储 — device_motion stride 13: t, uax, uay, uaz, gx, gy, gz, grav_x, grav_y, grav_z, pitch, roll, yaw
    private var motionSamples: [Float] = []

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
        accelCount = 0; motionCount = 0
        startDate   = Date()
        startUptime = ProcessInfo.processInfo.systemUptime
        batched = CMBatchedSensorManager()   // 每次录制用全新实例，避免重启后高频流不出数据
        beginUpdates()
    }

    private func beginUpdates() {
        guard let t0 = startDate else { return }

        // ── CMBatchedSensorManager：800Hz 原始加速度 ──────────────────────
        if CMBatchedSensorManager.isAccelerometerSupported {
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
                        DispatchQueue.main.async { self.accelCount = n }
                    }
                    // 流正常结束后写入最终计数，确保 Summary 显示准确
                    let final = self.accelSamples.count / 4
                    DispatchQueue.main.async { self.accelCount = final }
                } catch {
                    print("[StreamRecorder] accelerometerUpdates 出错（800Hz 需活跃运动会话）: \(error)")
                }
            }
        } else {
            print("[StreamRecorder] CMBatchedSensorManager.isAccelerometerSupported = false")
        }

        // ── CMMotionManager：100Hz 传感器融合数据 ─────────────────────────
        motion.deviceMotionUpdateInterval = 1.0 / 100.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] d, _ in
            guard let self, let d else { return }
            let t = Float(Date().timeIntervalSince(t0))
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

    func pause() {
        batchedTask?.cancel(); batchedTask = nil
        batched.stopAccelerometerUpdates()
        motion.stopDeviceMotionUpdates()
    }

    func resume() { beginUpdates() }

    func stop() {
        pause()
        let na = accelSamples.count  / 4
        let nm = motionSamples.count / 13
        DispatchQueue.main.async { self.accelCount = na; self.motionCount = nm }
    }

    func reset() {
        accelSamples.removeAll(); motionSamples.removeAll()
        accelCount = 0; motionCount = 0; startDate = nil
    }

    /// 将两条数据流序列化为 JSON 文件（在后台线程调用）。
    func writeToTempFile(strokeType: String, startEpochMs: Double) -> URL? {
        let na = accelSamples.count  / 4
        let nm = motionSamples.count / 13
        guard na > 0 || nm > 0 else { return nil }

        let fileName = "imu_\(Int64(startEpochMs))_\(strokeType).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }

        func w(_ s: String) { handle.write(Data(s.utf8)) }

        // ── 文件头 ──
        w("{\"version\":2,\"strokeType\":\"\(strokeType)\",\"startEpochMs\":\(Int64(startEpochMs))")
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
