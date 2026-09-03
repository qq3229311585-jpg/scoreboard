import Foundation
import WatchConnectivity
import WatchKit

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
    /// 当前这组数据对应的传输文件名——迟到的上一组传输失败回调不污染本组状态
    private var activeTransferName: String?

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    private var recorderStarted = false
    /// 准备中：界面已切到录制页，但传感器还没真正开始出数据
    @Published var isPreparing = false

    func startRecording() {
        sendState = .idle
        sendError = nil
        activeTransferName = nil
        elapsedSeconds = 0
        phase = .recording
        isPreparing = true
        recorderStarted = false
        // 启动运动会话——CMBatchedSensorManager 的 800Hz 要求 session 真正进入 .running。
        // 必须等 .running 再开采集，否则高频流抢跑被拒、丢数据。授权/启动失败也照常录（仅 100Hz）。
        workout.start { [weak self] ok in
            guard let self else { return }
            if self.recorderStarted {
                // 兜底已先启动（此时 800Hz 被拒只有 100Hz），workout 迟到 ready 后补启高频流
                if ok, self.phase == .recording {
                    print("[Recorder] workout 迟到 ready，补启 800Hz 流")
                    self.recorder.ensureAccelStream()
                }
            } else {
                print("[Recorder] workout ready=\(ok)，开始采集")
                self.beginRecorderOnce()
            }
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
        sessionStart = Date()          // t=0 与 startEpochMs 对齐到真实采集开始时刻
        recorder.start()
        isPreparing = false
        startTimer()                   // 计时从真实采集开始，不含准备时间
        WKInterfaceDevice.current().play(.start)
    }

    /// 准备阶段取消，直接回首页（此时还没有任何数据）
    func cancelPreparing() {
        guard isPreparing else { return }
        workout.stop()
        isPreparing = false
        phase = .setup
    }

    func pauseRecording() {
        guard recorderStarted else { return }   // 准备中不可暂停（UI 也不显示按钮）
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
        WKInterfaceDevice.current().play(.stop)
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
        // 主线程取快照：录制已停止，之后哪怕"再来一组"清空数组也不影响写文件
        let snap = recorder.snapshot()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let fileURL = self.recorder.writeToTempFile(snap, strokeType: stroke, startEpochMs: startMs) else {
                DispatchQueue.main.async { self.sendState = .error; self.sendError = "写入失败" }
                return
            }
            let meta: [String: Any] = [
                "action":      "imuStream",
                "strokeType":  stroke,
                "startMs":     startMs,
                "accelCount":  snap.accel.count / 4,
                "motionCount": snap.motion.count / 13,
                "accelHz":     800,
                "motionHz":    100
            ]
            WCSession.default.transferFile(fileURL, metadata: meta)
            DispatchQueue.main.async {
                self.activeTransferName = fileURL.lastPathComponent
                self.sendState = .done
                WKInterfaceDevice.current().play(.success)
            }
        }
    }

    // MARK: WCSessionDelegate
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let name = fileTransfer.file.fileURL.lastPathComponent
        guard let error else {
            // 传输成功，清掉 tmp 里的大文件，避免积累
            try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
            return
        }
        print("[Recorder] transfer error (\(name)): \(error)")
        DispatchQueue.main.async {
            // 只有还停留在这组数据的 Summary 页时才提示重试；
            // 已开始新一组的话，重试发出的会是新数据，反而造成混乱
            guard self.phase == .done, name == self.activeTransferName else { return }
            self.sendState = .error
            self.sendError = "传输出错，可重试"
        }
    }
}
