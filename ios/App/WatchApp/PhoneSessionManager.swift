import WatchConnectivity
import Foundation

class PhoneSessionManager: NSObject, ObservableObject, WCSessionDelegate {
    weak var workoutManager: WorkoutManager?
    weak var matchManager: WatchMatchManager?

    @Published var isReachable = false
    @Published var activationStateLabel = "notActivated"
    @Published var activationError = ""

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        print("[Watch][PhoneSessionManager] init supported=true")
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: - WCSessionDelegate

    func session(_ s: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        print("[Watch][PhoneSessionManager] activationDidComplete state=\(stateName(state)) reachable=\(s.isReachable) error=\(error?.localizedDescription ?? "")")
        DispatchQueue.main.async {
            self.isReachable = s.isReachable
            self.activationStateLabel = self.stateName(state)
            self.activationError = error?.localizedDescription ?? ""
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        print("[Watch][PhoneSessionManager] reachabilityDidChange reachable=\(session.isReachable)")
        DispatchQueue.main.async { self.isReachable = session.isReachable }
    }

    // Layer 1: sendMessage
    func session(_ s: WCSession, didReceiveMessage msg: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        print("[Watch][PhoneSessionManager] didReceiveMessageWithReply \(msg)")
        handleFromPhone(msg)
        replyHandler(["ok": true])
    }

    func session(_ s: WCSession, didReceiveMessage msg: [String: Any]) {
        print("[Watch][PhoneSessionManager] didReceiveMessage \(msg)")
        handleFromPhone(msg)
    }

    // Layer 3: transferUserInfo（手机→手表方向不使用；手表→手机走 sendControl/sendCompletedMatch）
    func session(_ s: WCSession, didReceiveUserInfo info: [String: Any]) {
        print("[Watch][PhoneSessionManager] didReceiveUserInfo \(info)")
        handleFromPhone(info)
    }

    // Layer 2: applicationContext（比分快照 + 档案名）
    func session(_ session: WCSession, didReceiveApplicationContext ctx: [String: Any]) {
        print("[Watch][PhoneSessionManager] didReceiveApplicationContext \(ctx)")
        applyContext(ctx)
    }

    // MARK: - 启动时恢复

    /// App 启动时读 applicationContext：恢复档案名 + 如有进行中比赛则进入记分页
    func applyContextOnLaunch() {
        guard WCSession.isSupported() else { return }
        // 先从本地存储恢复（无网络时也能用）
        if let saved = UserDefaults.standard.stringArray(forKey: "watch_profile_names") {
            DispatchQueue.main.async { self.matchManager?.profileNames = saved }
        }
        let ctx = WCSession.default.receivedApplicationContext
        guard !ctx.isEmpty else { return }
        // applicationContext 包含档案名和/或比赛快照
        applyContext(ctx, delay: 0.05)
    }

    // MARK: - 处理来自手机的消息

    private func handleFromPhone(_ msg: [String: Any]) {
        print("[Watch][PhoneSessionManager] handleFromPhone action=\(msg["action"] ?? "nil")")
        guard let action = msg["action"] as? String else { return }
        switch action {
        case "startWorkout":
            let sport = msg["sport"] as? String ?? "badminton"
            matchManager?.applyPhoneStart(sport: sport)
        case "syncMatchState":
            matchManager?.applyPhoneState(msg)
        case "stopWorkout":
            matchManager?.applyPhoneStop()
        default:
            break
        }
    }

    /// 处理 applicationContext：提取档案名 + 比赛快照
    private func applyContext(_ ctx: [String: Any], delay: Double = 0) {
        // 提取档案名
        if let names = ctx["profileNames"] as? [String] {
            UserDefaults.standard.set(names, forKey: "watch_profile_names")
            DispatchQueue.main.async { self.matchManager?.profileNames = names }
        }
        // 同步比赛快照：既处理进行中，也处理已结束/退出态
        guard let action = ctx["action"] as? String,
              action == "syncMatchState" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.matchManager?.applyPhoneState(ctx)
        }
    }

    // MARK: - 手表 → 手机

    /// 实时心率推送给手机（Layer 1）
    func pushHR(bpm: Int, ts: Double) {
        guard WCSession.default.isReachable else { return }
        print("[Watch][PhoneSessionManager] pushHR bpm=\(bpm) ts=\(ts)")
        WCSession.default.sendMessage(["bpm": bpm, "ts": ts], replyHandler: nil, errorHandler: nil)
    }

    /// 手表加分 / 暂停等操作通知手机（Layer 1 实时 + Layer 3 兜底）
    func sendControl(_ type: String, delta: Int? = nil, team: Int? = nil) {
        var msg: [String: Any] = ["action": "watchControl", "type": type]
        if let delta { msg["delta"] = delta }
        if let team  { msg["team"]  = team  }
        let session = WCSession.default
        print("[Watch][PhoneSessionManager] sendControl reachable=\(session.isReachable) msg=\(msg)")
        if session.isReachable {
            session.sendMessage(msg, replyHandler: nil, errorHandler: nil)
        } else {
            // 手机后台不可达时走 transferUserInfo，避免操作丢失
            session.transferUserInfo(msg)
        }
    }

    /// 手表请求手机停止比赛（Layer 1 实时 + Layer 3 兜底）
    func requestStopFromWatch() {
        let session = WCSession.default
        print("[Watch][PhoneSessionManager] requestStopFromWatch reachable=\(session.isReachable)")
        let msg: [String: Any] = ["action": "stopWorkout"]
        if session.isReachable {
            session.sendMessage(msg, replyHandler: nil, errorHandler: nil)
        } else {
            session.transferUserInfo(msg)
        }
    }

    /// 手表独立赛果回传手机（Layer 3 保证送达 + Layer 1 即时通知）
    func sendCompletedMatch(_ payload: [String: Any]) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        let sanitized = sanitizeDictionary(payload)
        print("[Watch][PhoneSessionManager] sendCompletedMatch reachable=\(session.isReachable) payload=\(sanitized)")
        // transferUserInfo 保证送达，无论手机是否在线
        session.transferUserInfo(sanitized)
        // applicationContext 作为离线兜底，避免 iPhone 刚启动时错过第一拍
        try? session.updateApplicationContext(sanitized)
        // 若可达，同时 sendMessage 让手机立刻处理（iPhone 侧去重）
        if session.isReachable {
            session.sendMessage(sanitized, replyHandler: nil, errorHandler: nil)
        }
    }

    private func sanitizeDictionary(_ dict: [String: Any]) -> [String: Any] {
        var sanitized: [String: Any] = [:]
        for (key, item) in dict {
            if let cleaned = sanitizePropertyList(item) {
                sanitized[key] = cleaned
            }
        }
        return sanitized
    }

    private func sanitizePropertyList(_ value: Any) -> Any? {
        switch value {
        case is NSNull:
            return nil
        case let str as String:
            return str
        case let num as NSNumber:
            return num
        case let date as Date:
            return date
        case let data as Data:
            return data
        case let arr as [Any]:
            return arr.compactMap { sanitizePropertyList($0) }
        case let dict as [String: Any]:
            return sanitizeDictionary(dict)
        default:
            return nil
        }
    }

    private func stateName(_ state: WCSessionActivationState) -> String {
        switch state {
        case .notActivated:
            return "notActivated"
        case .inactive:
            return "inactive"
        case .activated:
            return "activated"
        @unknown default:
            return "unknown"
        }
    }
}
