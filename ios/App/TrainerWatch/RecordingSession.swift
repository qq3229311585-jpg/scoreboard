import Foundation
import WatchConnectivity

enum StrokeType: String, CaseIterable, Identifiable, Hashable {
    case smash = "杀球"
    case clear = "高远球"
    case push  = "推球"
    case lift  = "挑球"
    case drop  = "劈吊"
    case net   = "放网"
    case empty = "空挥"
    case mixed = "混合"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .smash: return "bolt.fill"
        case .clear: return "arrow.up"
        case .push:  return "arrow.right"
        case .lift:  return "arrow.up.left"
        case .drop:  return "arrow.down.right"
        case .net:   return "dot.circle"
        case .empty: return "hand.wave"
        case .mixed: return "shuffle"
        }
    }
}

final class RecordingSession: NSObject, ObservableObject, WCSessionDelegate {
    @Published var strokeType: StrokeType = .clear
    @Published var phase: Phase = .setup
    @Published var elapsedSeconds = 0

    enum SendState { case idle, transferring, done, error }
    @Published var sendState: SendState = .idle
    @Published var sendError: String? = nil

    enum Phase { case setup, recording, paused, done }

    let recorder = StreamRecorder()
    private let workout = TrainerWorkout()
    private var timer: Timer?
    private var sessionStart: Date?

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    private var recorderStarted = false

    func startRecording() {
        sendState = .idle
        sendError = nil
        sessionStart = Date()
        elapsedSeconds = 0
        phase = .recording
        recorderStarted = false
        startTimer()
        // 启动运动会话——CMBatchedSensorManager 的 800Hz 要求 session 真正进入 .running。
        // 必须等 .running 再开采集，否则高频流抢跑被拒、丢数据。授权/启动失败也照常录（仅 100Hz）。
        workout.start { [weak self] ok in
            print("[Recorder] workout ready=\(ok)，开始采集")
            self?.beginRecorderOnce()
        }
        // 兜底：2.5s 内若 workout 仍未 ready（异常情况），也启动采集，至少拿到 100Hz。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, !self.recorderStarted, self.phase == .recording else { return }
            print("[Recorder] workout 超时未 ready，兜底启动采集（可能仅 100Hz）")
            self.beginRecorderOnce()
        }
    }

    private func beginRecorderOnce() {
        guard !recorderStarted, phase == .recording else { return }
        recorderStarted = true
        recorder.start()
    }

    func pauseRecording() {
        recorder.pause()
        timer?.invalidate(); timer = nil
        phase = .paused
    }

    func resumeRecording() {
        recorder.resume()
        phase = .recording
        startTimer()
    }

    func stopRecording() {
        recorder.stop()
        workout.stop()
        timer?.invalidate(); timer = nil
        phase = .done
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.elapsedSeconds += 1
        }
    }

    func sendToPhone() {
        guard sendState == .idle || sendState == .error else { return }
        sendState = .transferring
        let startMs = (sessionStart ?? Date()).timeIntervalSince1970 * 1000
        let stroke  = strokeType.rawValue

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let fileURL = self.recorder.writeToTempFile(strokeType: stroke, startEpochMs: startMs) else {
                DispatchQueue.main.async { self.sendState = .error; self.sendError = "写入失败" }
                return
            }
            let meta: [String: Any] = [
                "action":      "imuStream",
                "strokeType":  stroke,
                "startMs":     startMs,
                "accelCount":  self.recorder.accelCount,
                "motionCount": self.recorder.motionCount,
                "accelHz":     800,
                "motionHz":    100
            ]
            WCSession.default.transferFile(fileURL, metadata: meta)
            DispatchQueue.main.async { self.sendState = .done }
        }
    }

    // MARK: WCSessionDelegate
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let error else { return }
        DispatchQueue.main.async {
            self.sendState = .error
            self.sendError = "传输出错，可重试"
            print("[Recorder] transfer error: \(error)")
        }
    }
}
