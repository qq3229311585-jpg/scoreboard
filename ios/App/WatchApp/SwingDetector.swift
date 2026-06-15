import Foundation
import CoreMotion

final class SwingDetector: ObservableObject {
    @Published var swingCount = 0

    private var sensorManager: CMBatchedSensorManager?
    private var isRunning = false

    // 使用三轴合向量（x²+y²+z²）而非单轴，避免 Apple Watch 轴方向与 BadminSense(Samsung) 不同导致漏检。
    // 阈值 15 rad²/s² ≈ 总旋转速率 3.9 rad/s ≈ 222 deg/s；坐姿微动 <20 deg/s 远低于此值。
    // debounce 0.8s：完整杀球动作（前挥+击球+随挥）约 600-800ms，避免一次挥拍记 2-3 次。
    private let targetHz: Double = 100
    private let squaredThreshold: Double = 15
    private let debounceSeconds: Double = 0.8

    private var lastSwingTime: TimeInterval = 0
    private var sampleCounter = 0

    func start() {
        guard !isRunning else { return }
        guard CMBatchedSensorManager.isDeviceMotionSupported else {
            print("[SwingDetector] device motion not supported, trying CMMotionManager fallback")
            startFallback()
            return
        }
        isRunning = true
        swingCount = 0
        lastSwingTime = 0
        sampleCounter = 0

        sensorManager = CMBatchedSensorManager()
        guard let sm = sensorManager else { return }

        Task {
            do {
                for try await batch in sm.deviceMotionUpdates() {
                    guard isRunning else { break }
                    processBatch(batch)
                }
            } catch {
                print("[SwingDetector] batch error: \(error), falling back to CMMotionManager")
                startFallback()
            }
        }
        print("[SwingDetector] started (CMBatchedSensorManager)")
    }

    func stop() {
        isRunning = false
        sensorManager = nil
        fallbackManager?.stopDeviceMotionUpdates()
        fallbackManager = nil
        print("[SwingDetector] stopped, total swings: \(swingCount)")
    }

    func reset() {
        swingCount = 0
        lastSwingTime = 0
        sampleCounter = 0
    }

    // MARK: - Batch processing (200Hz gyro → downsample to 100Hz)

    private func processBatch(_ batch: [CMDeviceMotion]) {
        for (i, sample) in batch.enumerated() {
            // Downsample: 200Hz → 100Hz, take every 2nd sample
            sampleCounter += 1
            guard sampleCounter % 2 == 0 else { continue }

            let r = sample.rotationRate
            let squared = r.x * r.x + r.y * r.y + r.z * r.z // 三轴合向量，rad²/s²
            let ts = sample.timestamp

            if squared > squaredThreshold && (ts - lastSwingTime) > debounceSeconds {
                lastSwingTime = ts
                DispatchQueue.main.async {
                    self.swingCount += 1
                }
            }
        }
    }

    // MARK: - Fallback: CMMotionManager at 100Hz (older watchOS / simulator)

    private var fallbackManager: CMMotionManager?

    private func startFallback() {
        isRunning = true
        swingCount = 0
        lastSwingTime = 0

        let mm = CMMotionManager()
        mm.deviceMotionUpdateInterval = 1.0 / targetHz
        fallbackManager = mm

        guard mm.isDeviceMotionAvailable else {
            print("[SwingDetector] no motion available at all")
            return
        }

        mm.startDeviceMotionUpdates(to: .init()) { [weak self] motion, error in
            guard let self, self.isRunning, let motion else { return }
            let r = motion.rotationRate
            let squared = r.x * r.x + r.y * r.y + r.z * r.z // 三轴合向量，rad²/s²
            let ts = motion.timestamp

            if squared > squaredThreshold && (ts - self.lastSwingTime) > self.debounceSeconds {
                self.lastSwingTime = ts
                DispatchQueue.main.async {
                    self.swingCount += 1
                }
            }
        }
        print("[SwingDetector] started (CMMotionManager fallback)")
    }
}
