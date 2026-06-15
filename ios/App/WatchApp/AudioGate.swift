import Foundation
import AVFoundation

/// 通过 Watch 麦克风检测击球声，为 SwingDetector 提供二次确认。
/// 使用 IIR 平滑背景噪声 + 能量突变检测（onset detection），无需频域分析。
final class AudioGate: ObservableObject {

    @Published var isEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "audioGatingEnabled")
            // 关闭时立即停止；开启时不自动监听——由比赛开始/结束控制
            if !isEnabled { stopListening() }
        }
    }

    /// SwingDetector 在 processingQueue 上调用，AudioGate 在此 closure 里通知
    var onImpact: ((TimeInterval) -> Void)?

    private var engine: AVAudioEngine?
    private var isListening = false

    // 最近击球时间戳环形缓冲（CACurrentMediaTime 秒）
    private var impactTimestamps: [TimeInterval] = []
    private let maxBuffered = 30

    // 能量平滑状态（仅在 audio tap callback 里访问，单线程安全）
    private var smoothedEnergy: Float = 1e-8
    private let smoothingFactor: Float = 0.90   // IIR 系数（大→慢，背景估计更稳）
    private let onsetRatio: Float = 8.0          // 当前帧能量 / 平滑背景 > 此值视为冲击
    private let minEnergyFloor: Float = 1e-7     // 防止除零
    private let minImpactInterval: TimeInterval = 0.12  // 连续 impact 最短间隔

    private var lastImpactTime: TimeInterval = 0

    init() {
        // 恢复上次保存的开关状态
        let saved = UserDefaults.standard.object(forKey: "audioGatingEnabled")
        if let savedBool = saved as? Bool {
            isEnabled = savedBool
        }
    }

    func startListening() {
        guard !isListening else { return }
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            guard let self, granted else {
                print("[AudioGate] 麦克风权限未授予")
                return
            }
            DispatchQueue.main.async { self.setupEngine() }
        }
    }

    func stopListening() {
        guard isListening else { return }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isListening = false
        print("[AudioGate] 已停止")
    }

    private func setupEngine() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.mixWithOthers])
            try session.setActive(true)

            let eng = AVAudioEngine()
            let inputNode = eng.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                print("[AudioGate] 采样率为 0，放弃")
                return
            }

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, time in
                self?.handleBuffer(buf, time: time)
            }

            eng.prepare()
            try eng.start()
            engine = eng
            isListening = true
            print("[AudioGate] 启动，采样率=\(format.sampleRate)")
        } catch {
            print("[AudioGate] 启动失败: \(error)")
        }
    }

    // MARK: - 音频处理（audio tap callback，非主线程）

    private func handleBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }

        // RMS 能量
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let energy = sum / Float(n)

        // Onset 检测
        let bg = max(smoothedEnergy, minEnergyFloor)
        let isOnset = energy > bg * onsetRatio

        // 只用"安静帧"更新背景，避免击球声污染基线
        if !isOnset {
            smoothedEnergy = smoothingFactor * smoothedEnergy + (1 - smoothingFactor) * energy
        }

        if isOnset {
            // ProcessInfo.systemUptime 与 CMDeviceMotion.timestamp 同一时间基准（均为系统启动后秒数）
            let ts = ProcessInfo.processInfo.systemUptime
            guard ts - lastImpactTime > minImpactInterval else { return }
            lastImpactTime = ts

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.impactTimestamps.append(ts)
                if self.impactTimestamps.count > self.maxBuffered {
                    self.impactTimestamps.removeFirst()
                }
                print("[AudioGate] 击球声 ts=\(String(format:"%.3f",ts))")
            }
            onImpact?(ts)   // 直接在 audio 线程回调（SwingDetector.processingQueue 会串行处理）
        }
    }

    // MARK: - 查询接口（SwingDetector 在 processingQueue 上调用）

    func hasImpactNear(_ ts: TimeInterval, window: Double) -> Bool {
        // impactTimestamps 在主线程写，这里可能从 processingQueue 读——竞争较低
        // 用 DispatchQueue.main.sync 确保读安全（processingQueue ≠ main，不会死锁）
        var found = false
        DispatchQueue.main.sync {
            let lo = ts - window
            let hi = ts + window
            found = impactTimestamps.contains { $0 >= lo && $0 <= hi }
        }
        return found
    }
}
