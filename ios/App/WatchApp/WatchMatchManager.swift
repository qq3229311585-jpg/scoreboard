import Foundation
import WatchKit

final class WatchMatchManager: ObservableObject {
    struct Snapshot {
        let teamAScore: Int
        let teamBScore: Int
        let isPaused: Bool
        let elapsedSeconds: Int
        let periodIndex: Int
        let teamASubtitle: String
        let teamBSubtitle: String
        let summary: String
        let setWins: [Int]
        let setScores: [[Int]]
        let setTimes: [Int]
        let isMatchActive: Bool
    }

    struct MatchEvent {
        let player: Int
        let delta: Int
        let setIndex: Int
        let timestamp: Double
        let elapsedMs: Int
        let pointMs: Int
        let cumA: Int
        let cumB: Int
    }

    enum SessionSource {
        case none
        case local
        case phone
    }

    weak var workoutManager: WorkoutManager?
    weak var phoneSession: PhoneSessionManager?

    @Published var profileNames: [String] = []   // 从手机同步过来的档案名单
    @Published var isMatchActive = false
    @Published var sport = "badminton"
    @Published var sportLabel = "羽毛球"
    @Published var teamAName = "我方"
    @Published var teamBName = "对手"
    @Published var teamAScore = 0
    @Published var teamBScore = 0
    @Published var teamASubtitle = ""
    @Published var teamBSubtitle = ""
    @Published var summary = "手表可直接开赛"
    @Published var isPaused = false
    @Published var canUndo = false
    @Published var supportsMultiPoint = false
    @Published var periodLabel = ""
    @Published var elapsedSeconds = 0
    @Published var sessionSource: SessionSource = .none
    @Published var pendingSetupSport: String? = nil
    @Published var pendingSetupSportName: String? = nil

    private var ticker: Timer?
    private var history: [Snapshot] = []
    private var periodIndex = 1
    private var ptWin = 21
    private var totalSets = 3
    private var setWin = 2
    private var setWins = [0, 0]
    private var setScores: [[Int]] = []
    private var setTimes: [Int] = []
    private var matchEvents: [MatchEvent] = []
    private var heartRateTimeline: [[String: Any]] = []
    private var matchStartedAtMs: Int = 0
    private var lastEventElapsedMs: Int = 0

    // 用 startDate + 累计暂停时长推算时间，避免息屏 Timer 停走导致计时失真
    private var matchStartDate: Date?
    private var pausedAccumulated: TimeInterval = 0
    private var pausedAt: Date?

    var isLocalSession: Bool { sessionSource == .local }

    func configure(workoutManager: WorkoutManager, phoneSession: PhoneSessionManager) {
        self.workoutManager = workoutManager
        self.phoneSession = phoneSession
    }

    func startLocalMatch(sport: String,
                         nameA: String? = nil,
                         nameB: String? = nil,
                         ptWin: Int = 21,
                         totalSets: Int = 3) {
        stopTicker()
        history.removeAll()
        self.sport = sport
        sportLabel = displayName(for: sport)
        supportsMultiPoint = sport == "basketball"
        self.ptWin = max(1, ptWin)
        self.totalSets = max(1, totalSets)
        self.setWin = max(1, Int(ceil(Double(self.totalSets) / 2.0)))
        teamAName = nameA ?? (sport == "basketball" ? "主队" : "我方")
        teamBName = nameB ?? (sport == "basketball" ? "客队" : "对手")
        teamAScore = 0
        teamBScore = 0
        teamASubtitle = ""
        teamBSubtitle = ""
        periodIndex = 1
        setWins = [0, 0]
        setScores.removeAll()
        setTimes.removeAll()
        elapsedSeconds = 0
        matchEvents.removeAll()
        heartRateTimeline.removeAll()
        matchStartedAtMs = Int(Date().timeIntervalSince1970 * 1000)
        matchStartDate = Date()
        pausedAccumulated = 0
        pausedAt = nil
        lastEventElapsedMs = 0
        isPaused = false
        isMatchActive = true
        sessionSource = .local
        pendingSetupSport = nil
        pendingSetupSportName = nil
        updatePeriodLabel()
        refreshProgress()
        updateSummary()
        canUndo = false
        print("[Watch][Match] startLocalMatch sport=\(sport) ptWin=\(self.ptWin) totalSets=\(self.totalSets) setWin=\(self.setWin) names=\(teamAName),\(teamBName)")
        workoutManager?.start(sport: sport)
        startTicker()
    }

    /// 强制重置（暂停时点"重新设置"）— 丢弃当前比赛，回到空闲
    func forceReset() {
        pendingSetupSport = sport
        pendingSetupSportName = sportLabel
        stopTicker()
        workoutManager?.stop()
        isMatchActive = false
        isPaused = false
        canUndo = false
        sessionSource = .none
        history.removeAll()
        matchEvents.removeAll()
        heartRateTimeline.removeAll()
        setScores.removeAll()
        setTimes.removeAll()
        setWins = [0, 0]
        matchStartDate = nil
        pausedAccumulated = 0
        pausedAt = nil
    }

    func finishLocalMatch() {
        guard sessionSource == .local else { return }
        refreshElapsed()

        if !supportsMultiPoint {
            // 羽毛球/乒乓球：当前局领先方记为本局胜者
            if teamAScore != teamBScore {
                let sw = teamAScore > teamBScore ? 0 : 1
                setScores.append([teamAScore, teamBScore])
                setWins[sw] += 1
                setTimes.append(Int(Date().timeIntervalSince1970 * 1000))
            }
            if setWins[0] == setWins[1] {
                summary = "当前平分，请继续比赛"
                WKInterfaceDevice.current().play(.retry)
                return
            }
        } else {
            if teamAScore == teamBScore {
                summary = "当前平分，请继续比赛"
                WKInterfaceDevice.current().play(.retry)
                return
            }
        }

        let payload = buildCompletedPayload()
        print("[Watch][Match] finishLocalMatch winnerPayload=\(payload)")
        phoneSession?.sendCompletedMatch(payload)
        isMatchActive = false
        isPaused = false
        canUndo = false
        history.removeAll()
        sessionSource = .none
        pendingSetupSport = nil
        pendingSetupSportName = nil
        summary = "比赛已结束"
        stopTicker()
        workoutManager?.stop()
        matchStartDate = nil
        pausedAccumulated = 0
        pausedAt = nil
    }

    func addPoint(team: Int) {
        addScore(team: team, delta: 1)
    }

    func addScore(team: Int, delta: Int) {
        guard sessionSource == .local, isMatchActive else { return }
        refreshElapsed()
        pushHistory()
        if team == 0 {
            teamAScore += delta
        } else {
            teamBScore += delta
        }
        recordEvent(team: team, delta: delta)
        if !supportsMultiPoint {
            advanceRallyMatchIfNeeded()
            guard isMatchActive else { return }
        }
        print("[Watch][Match] addScore team=\(team) delta=\(delta) score=\(teamAScore):\(teamBScore) setWins=\(setWins) period=\(periodIndex)")
        updateSummary()
    }

    func togglePause() {
        guard sessionSource == .local, isMatchActive else { return }
        pushHistory()
        isPaused.toggle()
        if isPaused {
            refreshElapsed()
            pausedAt = Date()
            stopTicker()
            summary = "比赛暂停"
        } else {
            if let pa = pausedAt {
                pausedAccumulated += Date().timeIntervalSince(pa)
            }
            pausedAt = nil
            startTicker()
            updateSummary()
        }
    }

    func undo() {
        guard sessionSource == .local, let last = history.popLast() else { return }
        teamAScore = last.teamAScore
        teamBScore = last.teamBScore
        isPaused = last.isPaused
        elapsedSeconds = last.elapsedSeconds
        periodIndex = last.periodIndex
        teamASubtitle = last.teamASubtitle
        teamBSubtitle = last.teamBSubtitle
        summary = last.summary
        setWins = last.setWins
        setScores = last.setScores
        setTimes = last.setTimes
        isMatchActive = last.isMatchActive
        canUndo = !history.isEmpty
        updatePeriodLabel()
        if isPaused {
            stopTicker()
            summary = "已撤销"
        } else {
            startTicker()
            updateSummary(prefix: "已撤销")
        }
    }

    func nextPeriod() {
        guard sessionSource == .local, supportsMultiPoint else { return }
        pushHistory()
        periodIndex += 1
        updatePeriodLabel()
        summary = "进入\(periodLabel)"
    }

    func applyPhoneStart(sport: String) {
        sessionSource = .phone
        self.sport = sport
        sportLabel = displayName(for: sport)
        isMatchActive = true
        periodIndex = 1
        setWins = [0, 0]
        setScores.removeAll()
        setTimes.removeAll()
        teamAScore = 0
        teamBScore = 0
        teamASubtitle = ""
        teamBSubtitle = ""
        summary = "手机端已开始"
        print("[Watch][Match] applyPhoneStart sport=\(sport)")
        workoutManager?.start(sport: sport)
    }

    func applyPhoneStop() {
        guard sessionSource != .local else { return }
        print("[Watch][Match] applyPhoneStop")
        sessionSource = .none
        isMatchActive = false
        isPaused = false
        canUndo = false
        summary = "手机端已结束"
        stopTicker()
        workoutManager?.stop()
    }

    func applyPhoneState(_ msg: [String: Any]) {
        guard sessionSource != .local else { return }
        print("[Watch][Match] applyPhoneState raw=\(msg)")
        DispatchQueue.main.async {
            let isActive = msg["isActive"] as? Bool ?? false
            self.sessionSource = isActive ? .phone : .none
            self.isMatchActive = isActive
            self.sport = msg["sport"] as? String ?? self.sport
            self.sportLabel = msg["sportLabel"] as? String ?? self.displayName(for: self.sport)
            self.teamAName = msg["teamAName"] as? String ?? "A"
            self.teamBName = msg["teamBName"] as? String ?? "B"
            self.teamAScore = msg["teamAScore"] as? Int ?? 0
            self.teamBScore = msg["teamBScore"] as? Int ?? 0
            self.teamASubtitle = msg["teamASubtitle"] as? String ?? ""
            self.teamBSubtitle = msg["teamBSubtitle"] as? String ?? ""
            self.summary = msg["summary"] as? String ?? ""
            self.periodLabel = msg["periodLabel"] as? String ?? ""
            self.isPaused = msg["isPaused"] as? Bool ?? false
            self.canUndo = false
            self.supportsMultiPoint = msg["supportsMultiPoint"] as? Bool ?? false
            self.elapsedSeconds = msg["elapsedSeconds"] as? Int ?? 0
            self.ptWin = msg["ptWin"] as? Int ?? self.ptWin
            self.totalSets = msg["totalSets"] as? Int ?? self.totalSets
            self.setWin = msg["setWin"] as? Int ?? self.setWin
            self.periodIndex = msg["periodIndex"] as? Int ?? self.periodIndex
            self.setWins = msg["setWins"] as? [Int] ?? self.setWins
            print("[Watch][Match] applied phone state active=\(self.isMatchActive) score=\(self.teamAScore):\(self.teamBScore) period=\(self.periodIndex) ptWin=\(self.ptWin) totalSets=\(self.totalSets) setWins=\(self.setWins)")
            if self.isMatchActive && !self.isPaused {
                self.startTicker()
            } else {
                self.stopTicker()
                self.workoutManager?.stop()
            }
        }
    }

    func recordHeartRate(bpm: Int, timestamp: Double) {
        guard isMatchActive else { return }
        heartRateTimeline.append([
            "timestamp": timestamp,
            "bpm": bpm
        ])
    }

    private func pushHistory() {
        history.append(
            Snapshot(
                teamAScore: teamAScore,
                teamBScore: teamBScore,
                isPaused: isPaused,
                elapsedSeconds: elapsedSeconds,
                periodIndex: periodIndex,
                teamASubtitle: teamASubtitle,
                teamBSubtitle: teamBSubtitle,
                summary: summary,
                setWins: setWins,
                setScores: setScores,
                setTimes: setTimes,
                isMatchActive: isMatchActive
            )
        )
        canUndo = true
    }

    private func advanceRallyMatchIfNeeded() {
        guard let winner = rallyWinner(teamAScore, teamBScore) else {
            refreshProgress()
            return
        }
        setScores.append([teamAScore, teamBScore])
        if setTimes.isEmpty {
            setTimes = [matchStartedAtMs]
        }
        setTimes.append(Int(Date().timeIntervalSince1970 * 1000))
        setWins[winner] += 1

        if setWins[winner] >= setWin {
            refreshProgress()
            summary = "\(winner == 0 ? teamAName : teamBName) 获胜"
            finishLocalMatch()
            return
        }

        periodIndex += 1
        updatePeriodLabel()
        teamAScore = 0
        teamBScore = 0
        refreshProgress()
        summary = "进入第\(periodIndex)局"
    }

    private func rallyWinner(_ a: Int, _ b: Int) -> Int? {
        let maxPoint = sport == "badminton" ? ptWin + 9 : nil
        if a < ptWin && b < ptWin {
            return nil
        }
        if let maxPoint, a >= maxPoint || b >= maxPoint {
            return a >= b ? 0 : 1
        }
        if a >= ptWin && a - b >= 2 { return 0 }
        if b >= ptWin && b - a >= 2 { return 1 }
        return nil
    }

    private func refreshProgress() {
        guard !supportsMultiPoint else {
            teamASubtitle = ""
            teamBSubtitle = ""
            return
        }
        teamASubtitle = dotsString(won: setWins[0], total: totalSets)
        teamBSubtitle = dotsString(won: setWins[1], total: totalSets)
    }

    private func dotsString(won: Int, total: Int) -> String {
        guard total > 0 else { return "" }
        return String(repeating: "●", count: max(0, won)) + String(repeating: "○", count: max(0, total - won))
    }

    private func recordEvent(team: Int, delta: Int) {
        let elapsedMs = elapsedSeconds * 1000
        let pointMs = max(0, elapsedMs - lastEventElapsedMs)
        matchEvents.append(
            MatchEvent(
                player: team,
                delta: delta,
                setIndex: periodIndex,
                timestamp: Double(Int(Date().timeIntervalSince1970 * 1000)),
                elapsedMs: elapsedMs,
                pointMs: pointMs,
                cumA: teamAScore,
                cumB: teamBScore
            )
        )
        lastEventElapsedMs = elapsedMs
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.sessionSource == .local {
                // 本地比赛：用 startDate 推算，避免息屏 Timer 停走导致少算
                if !self.isPaused && self.isMatchActive {
                    self.refreshElapsed()
                }
            } else if !self.isPaused && self.isMatchActive {
                // 手机控制：等手机端 syncMatchState 推快照覆盖，中间靠 +1 撑住显示
                self.elapsedSeconds += 1
            }
        }
    }

    /// 用 startDate + 已暂停时长重算 elapsedSeconds，息屏期间也能补回正确时长
    private func refreshElapsed() {
        guard let start = matchStartDate else { return }
        var paused = pausedAccumulated
        if let pa = pausedAt {
            paused += Date().timeIntervalSince(pa)
        }
        elapsedSeconds = max(0, Int(Date().timeIntervalSince(start) - paused))
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func updatePeriodLabel() {
        periodLabel = supportsMultiPoint ? "第\(periodIndex)节" : "第\(periodIndex)局"
    }

    private func updateSummary(prefix: String? = nil) {
        let base = "\(teamAName) \(teamAScore) : \(teamBScore) \(teamBName)"
        if let prefix {
            summary = "\(prefix) · \(base)"
        } else {
            summary = base
        }
    }

    private func buildCompletedPayload() -> [String: Any] {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let winner = supportsMultiPoint
            ? (teamAScore > teamBScore ? 0 : 1)
            : (setWins[0] >= setWins[1] ? 0 : 1)
        let rules: [String: Any] = supportsMultiPoint
            ? ["ptWin": 0, "setWin": 0, "totalSets": 0]
            : ["ptWin": ptWin, "setWin": setWin, "totalSets": totalSets]
        let payloadSetScores: [[Int]] = supportsMultiPoint
            ? buildBasketballPeriodScores()
            : self.setScores
        let payloadSetTimes: [Int] = supportsMultiPoint
            ? buildSetTimes(now: now)
            : (self.setTimes.isEmpty ? [matchStartedAtMs, now] : self.setTimes)
        let events = matchEvents.map { event in
            [
                "p": event.player,
                "delta": event.delta,
                "setIndex": event.setIndex,
                "t": event.timestamp,
                "elapsedMs": event.elapsedMs,
                "pointMs": event.pointMs,
                "cumA": event.cumA,
                "cumB": event.cumB
            ] as [String : Any]
        }

        return [
            "action": "watchMatchFinished",
            "record": [
                "id": now,
                "date": now,
                "sport": sport,
                "names": [teamAName, teamBName],
                "rules": rules,
                "events": events,
                "sets": supportsMultiPoint ? [] : setWins,
                "setScores": payloadSetScores,
                "setTimes": payloadSetTimes,
                "winner": winner,
                "duration": elapsedSeconds * 1000,
                "heartRateTimeline": heartRateTimeline,
                "hrPlayerIdx": 0,
            ]
        ]
    }

    private func buildBasketballPeriodScores() -> [[Int]] {
        guard supportsMultiPoint else { return [[teamAScore, teamBScore]] }
        let grouped = Dictionary(grouping: matchEvents, by: \.setIndex)
        let indexes = grouped.keys.sorted()
        return indexes.map { idx in
            let items = grouped[idx] ?? []
            let a = items.filter { $0.player == 0 }.reduce(0) { $0 + $1.delta }
            let b = items.filter { $0.player == 1 }.reduce(0) { $0 + $1.delta }
            return [a, b]
        }
    }

    private func buildSetTimes(now: Int) -> [Int] {
        guard supportsMultiPoint else { return [matchStartedAtMs, now] }
        var times = [matchStartedAtMs]
        let grouped = Dictionary(grouping: matchEvents, by: \.setIndex)
        let indexes = grouped.keys.sorted()
        for idx in indexes {
            if let last = grouped[idx]?.last {
                times.append(matchStartedAtMs + last.elapsedMs)
            }
        }
        if times.last != now {
            times.append(now)
        }
        return times
    }

    private func displayName(for sport: String) -> String {
        switch sport {
        case "badminton": return "羽毛球"
        case "tabletennis": return "乒乓球"
        case "tennis": return "网球"
        case "basketball": return "篮球"
        case "football": return "足球"
        default: return sport
        }
    }
}
