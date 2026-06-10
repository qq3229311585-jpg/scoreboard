import Capacitor
import WatchConnectivity

/// iPhone ↔ Apple Watch 三层通信模型
///   Layer 1 sendMessage        — 实时动作（startMatch / stopMatch / watchControl）
///   Layer 2 updateApplicationContext — 当前比分快照（每次状态变化后更新）
///   Layer 3 transferUserInfo   — 保证送达（手表赛果回传）
@objc(WatchPlugin)
public class WatchPlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier = "WatchPlugin"
    public let jsName = "WatchPlugin"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "isAvailable", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startWorkout", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopWorkout", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "syncMatchState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "syncProfiles", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "consumePendingWatchMatches", returnType: CAPPluginReturnPromise)
    ]

    private let pendingWatchMatchesKey = "pending_watch_matches_v1"

    /// 上次推送的 applicationContext，用于合并 matchState + profileNames
    private var lastContext: [String: Any] = [:]
    private var lastActivationState = WCSessionActivationState.notActivated
    private var lastActivationError = ""

    public override func load() {
        guard WCSession.isSupported() else { return }
        CAPLog.print("[WatchPlugin] load() supported=true")
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    @objc func isAvailable(_ call: CAPPluginCall) {
        let s = WCSession.isSupported() ? WCSession.default : nil
        let status: [String: Any] = [
            "supported":  WCSession.isSupported(),
            "paired":     s?.isPaired              ?? false,
            "installed":  s?.isWatchAppInstalled   ?? false,
            "reachable":  s?.isReachable           ?? false,
            "activationState": activationStateName(lastActivationState),
            "activationError": lastActivationError
        ]
        CAPLog.print("[WatchPlugin] isAvailable \(status)")
        call.resolve(status)
    }

    // MARK: - Layer 1: 实时动作（sendMessage）

    /// 让手表立刻跳入记分页
    @objc func startWorkout(_ call: CAPPluginCall) {
        let sport      = call.getString("sport")      ?? "badminton"
        let playerName = call.getString("playerName") ?? ""
        sendRealtime(["action": "startWorkout", "sport": sport, "playerName": playerName], call: call)
    }

    /// 让手表退出记分
    @objc func stopWorkout(_ call: CAPPluginCall) {
        sendRealtime(["action": "stopWorkout"], call: call)
    }

    // MARK: - Layer 2: 当前比分快照（updateApplicationContext）

    /// 每次比赛状态变化后调用，手表端始终获取最新快照
    @objc func syncMatchState(_ call: CAPPluginCall) {
        var payload = extractPayload(from: call)
        payload["action"] = "syncMatchState"
        // 保留已缓存的 profileNames，避免覆盖掉
        if let names = lastContext["profileNames"] {
            payload["profileNames"] = names
        }
        lastContext = payload
        updateContext(payload, call: call)
    }

    /// 档案名单同步（合并进 applicationContext，不单独占用一份 context）
    @objc func syncProfiles(_ call: CAPPluginCall) {
        let names = call.getArray("names") as? [String] ?? []
        var ctx = lastContext
        ctx["profileNames"] = names
        if ctx["action"] == nil { ctx["action"] = "syncMatchState" }
        lastContext = ctx
        updateContext(ctx, call: call)
    }

    // MARK: - Layer 3: 保证送达（transferUserInfo，消费未读比赛记录）

    @objc func consumePendingWatchMatches(_ call: CAPPluginCall) {
        let defaults = UserDefaults.standard
        let matches = defaults.array(forKey: pendingWatchMatchesKey) as? [[String: Any]] ?? []
        // 按 id 精确清除"本次读到的这批"；若读取与清除之间又有新记录到达，则保留给下次消费。
        // JS 侧仍按 id 去重作为兜底，避免极端情况下读到但未持久化导致重复写历史。
        let readIds = Set(matches.compactMap { numericId(from: ($0["record"] as? [String: Any])?["id"]) })
        let latest = defaults.array(forKey: pendingWatchMatchesKey) as? [[String: Any]] ?? []
        let remaining = latest.filter { item in
            guard let id = numericId(from: (item["record"] as? [String: Any])?["id"]) else { return true }
            return !readIds.contains(id)
        }
        defaults.set(remaining, forKey: pendingWatchMatchesKey)
        CAPLog.print("[WatchPlugin] consumePendingWatchMatches read=\(matches.count) cleared=\(readIds.count) remaining=\(remaining.count)")
        call.resolve(["matches": matches])
    }

    // MARK: - 内部工具

    private func sendRealtime(_ msg: [String: Any], call: CAPPluginCall) {
        guard WCSession.isSupported() else { call.resolve(); return }
        let session = WCSession.default
        CAPLog.print("[WatchPlugin] sendRealtime reachable=\(session.isReachable) msg=\(msg)")
        if session.isReachable {
            session.sendMessage(
                msg,
                replyHandler: { reply in
                    CAPLog.print("[WatchPlugin] sendRealtime reply=\(reply)")
                    call.resolve()
                },
                errorHandler: { err in
                    CAPLog.print("[WatchPlugin] sendRealtime error=\(err.localizedDescription)")
                    call.resolve()
                }  // 实时动作失败不阻塞 JS
            )
        } else {
            CAPLog.print("[WatchPlugin] sendRealtime skipped: not reachable")
            call.resolve()
        }
    }

    private func updateContext(_ ctx: [String: Any], call: CAPPluginCall) {
        guard WCSession.isSupported() else { call.resolve(); return }
        do {
            try WCSession.default.updateApplicationContext(ctx)
            CAPLog.print("[WatchPlugin] updateApplicationContext success action=\(ctx["action"] ?? "nil") ctx=\(ctx)")
            call.resolve()
        } catch {
            CAPLog.print("[WatchPlugin] updateApplicationContext error=\(error.localizedDescription)")
            call.reject(error.localizedDescription)
        }
    }

    private func extractPayload(from call: CAPPluginCall) -> [String: Any] {
        if let raw = call.options as? [String: Any] { return raw }
        var result: [String: Any] = [:]
        if let raw = call.options {
            for (key, value) in raw {
                if let k = key as? String { result[k] = value }
            }
        }
        return result
    }

    private func appendPendingWatchMatch(_ payload: [String: Any]) {
        let defaults = UserDefaults.standard
        var matches = defaults.array(forKey: pendingWatchMatchesKey) as? [[String: Any]] ?? []
        // 按 record.id 去重，避免 sendMessage + transferUserInfo 双路到达时重复
        let id = numericId(from: (payload["record"] as? [String: Any])?["id"])
        if let id, matches.contains(where: { numericId(from: ($0["record"] as? [String: Any])?["id"]) == id }) {
            CAPLog.print("[WatchPlugin] appendPendingWatchMatch skip duplicate id=\(id)")
            return
        }
        matches.insert(payload, at: 0)
        defaults.set(matches, forKey: pendingWatchMatchesKey)
        CAPLog.print("[WatchPlugin] appendPendingWatchMatch stored count=\(matches.count) id=\(id.map(String.init) ?? "nil")")
    }

    private func numericId(from value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let doubleValue = value as? Double {
            return Int(doubleValue)
        }
        return nil
    }
}

// MARK: - WCSessionDelegate
extension WatchPlugin: WCSessionDelegate {
    public func session(_ session: WCSession,
                        activationDidCompleteWith state: WCSessionActivationState,
                        error: Error?) {
        lastActivationState = state
        lastActivationError = error?.localizedDescription ?? ""
        CAPLog.print("[WatchPlugin] activationDidComplete state=\(activationStateName(state)) paired=\(session.isPaired) installed=\(session.isWatchAppInstalled) reachable=\(session.isReachable) error=\(lastActivationError)")
    }
    public func sessionDidBecomeInactive(_ session: WCSession) {}
    public func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    // 来自手表的实时消息（心率、记分操作、赛果）
    public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        CAPLog.print("[WatchPlugin] didReceiveMessage \(message)")
        handleFromWatch(message)
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                        replyHandler: @escaping ([String: Any]) -> Void) {
        CAPLog.print("[WatchPlugin] didReceiveMessageWithReply \(message)")
        handleFromWatch(message)
        replyHandler(["ok": true])
    }

    // 来自手表的 transferUserInfo（赛果保证送达通道）
    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        CAPLog.print("[WatchPlugin] didReceiveUserInfo \(userInfo)")
        handleFromWatch(userInfo)
    }

    // 来自手表的 applicationContext（离线兜底通道）
    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        CAPLog.print("[WatchPlugin] didReceiveApplicationContext \(applicationContext)")
        handleFromWatch(applicationContext)
    }

    private func handleFromWatch(_ msg: [String: Any]) {
        CAPLog.print("[WatchPlugin] handleFromWatch action=\(msg["action"] ?? "nil") msg=\(msg)")
        // 实时心率
        if let bpm = msg["bpm"] as? Int {
            let ts = msg["ts"] as? Double ?? Date().timeIntervalSince1970 * 1000
            notifyListeners("heartRateUpdate", data: ["bpm": bpm, "timestamp": ts])
        }
        guard let action = msg["action"] as? String else { return }
        switch action {
        case "watchControl":
            notifyListeners("watchControl", data: msg)
        case "stopWorkout":
            notifyListeners("watchStopRequested", data: msg)
        case "watchMatchFinished":
            appendPendingWatchMatch(msg)
            notifyListeners("watchMatchFinished", data: msg)
        default:
            break
        }
    }

    private func activationStateName(_ state: WCSessionActivationState) -> String {
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
