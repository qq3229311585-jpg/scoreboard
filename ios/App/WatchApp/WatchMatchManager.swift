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
    weak var swingDetector: SwingDetector?
    var audioGate: AudioGate?

    @Published var profileNames: [String] = []   // 从手机同步过来的档案名单
    @Published var hrPersonName: String = ""      // 个人中心开了心率监测的那个人；本地赛据此决定是否开心率+录音
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

    /// 比赛结束后的结算结果，非 nil 时 ContentView 显示结算页（本地赛 + 镜像赛通用）
    struct Result: Equatable {
        let winnerName: String
        let scoreLine: String
    }
    @Published var lastResult: Result? = nil

    private var ticker: Timer?
    private var history: [Snapshot] = []
    // 镜像赛身份标识（手机的 S.startTime）：用于区分"同一场/新一场/刚结束那场"，避免旧高分被 max 残留
    private var lastSeenPhoneMatchStartMs: Int = 0
    private var finishedPhoneMatchStartMs: Int = 0
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
        lastResult = nil
        isMatchActive = true
        sessionSource = .local
        pendingSetupSport = nil
        pendingSetupSportName = nil
        updatePeriodLabel()
        refreshProgress()
        updateSummary()
        canUndo = false
        let trackWearer = shouldTrackWearer()
        print("[Watch][Match] startLocalMatch sport=\(sport) names=\(teamAName),\(teamBName) hrPerson=\(hrPersonName) trackWearer=\(trackWearer)")
        workoutManager?.start(sport: sport, trackHR: trackWearer)
        swingDetector?.reset()
        swingDetector?.start()
        updateAudioGate(trackWearer: trackWearer)
        startTicker()
    }

    /// 强制重置（暂停时点"重新设置"）— 丢弃当前比赛，回到空闲
    func forceReset() {
        pendingSetupSport = sport
        pendingSetupSportName = sportLabel
        stopTicker()
        workoutManager?.stop()
        swingDetector?.stop()
        audioGate?.stopListening()
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

    func finishLocalMatch(alreadyScored: Bool = false) {
        guard sessionSource == .local else { return }
        refreshElapsed()

        // alreadyScored=true：由"打满自动结束"调用，本局已在 advanceRallyMatchIfNeeded
        // 记过 setScores/setWins，这里绝不能再记一次（否则局分多加一次，
        // 出现一局制 2:0、三局两胜 3:0 的错误比分）。
        if !alreadyScored {
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
        }

        let payload = buildCompletedPayload()
        print("[Watch][Match] finishLocalMatch winnerPayload=\(payload)")
        phoneSession?.sendCompletedMatch(payload)
        lastResult = makeResult()
        resetScoreState()   // 结束后立即清零比分/局/事件，防止残留状态被下一场或心跳重新激活后继续累加
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
        swingDetector?.stop()
        audioGate?.stopListening()
        matchStartDate = nil
        pausedAccumulated = 0
        pausedAt = nil
    }

    /// 镜像赛（手机开局、手表记分）在手表上结束。
    /// 关键：以手表的最终状态为权威，构建完整记录经 transferUserInfo 保证送达手机
    /// （手机端 watchMatchFinished 去重持久化 + 收尾 UI），不再依赖手机在线自存 ——
    /// 这样手机被杀/后台时记录也不丢。逻辑与 finishLocalMatch 一致，仅 guard 改为 .phone。
    func finishMirrorMatch() {
        guard sessionSource == .phone else { return }
        refreshElapsed()

        if !supportsMultiPoint {
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
        print("[Watch][Match] finishMirrorMatch winnerPayload=\(payload)")
        phoneSession?.sendCompletedMatch(payload)   // 保证送达，手机端权威保存
        // 同时即时通知手机结束，让它尽快把 S.winner 置位、停发"进行中"心跳，
        // 避免本地刚结束、手机仍报 active 的旧心跳把手表重新激活回记分页。
        phoneSession?.requestStopFromWatch()
        // 标记这一场已结束：之后带相同 matchStartMs 的滞后心跳一律忽略
        finishedPhoneMatchStartMs = lastSeenPhoneMatchStartMs
        lastResult = makeResult()
        resetScoreState()   // 结束后立即清零比分/局/事件，防止残留状态被下一场或心跳重新激活后继续累加
        isMatchActive = false
        isPaused = false
        canUndo = false
        history.removeAll()
        sessionSource = .none
        summary = "比赛已结束"
        stopTicker()
        workoutManager?.stop()
        swingDetector?.stop()
        audioGate?.stopListening()
        matchStartDate = nil
        pausedAccumulated = 0
        pausedAt = nil
    }

    /// 清空一场比赛的全部比分/局/事件状态。
    /// 结束比赛后必须调用 —— 否则残留的 teamAScore/setWins/setScores/matchEvents 会在
    /// 手表被手机心跳重新激活（applyPhoneState 走 max 对齐、不重置）时被当作上一场继续累加，
    /// 导致"继续上局比分""局分多加"等问题。
    private func resetScoreState() {
        teamAScore = 0
        teamBScore = 0
        setWins = [0, 0]
        setScores.removeAll()
        setTimes.removeAll()
        matchEvents.removeAll()
        heartRateTimeline.removeAll()
        periodIndex = 1
        elapsedSeconds = 0
    }

    /// 根据当前最终状态构建结算结果（胜者名 + 比分行）
    private func makeResult() -> Result {
        let winner = supportsMultiPoint
            ? (teamAScore > teamBScore ? 0 : 1)
            : (setWins[0] >= setWins[1] ? 0 : 1)
        let scoreLine = supportsMultiPoint
            ? "\(teamAScore) : \(teamBScore)"
            : "\(setWins[0]) : \(setWins[1])"
        return Result(winnerName: winner == 0 ? teamAName : teamBName, scoreLine: scoreLine)
    }

    func addPoint(team: Int) {
        addScore(team: team, delta: 1)
    }

    func addScore(team: Int, delta: Int) {
        // 数据对齐方案：手表无论 .local 还是 .phone（镜像手机赛）都本地累计。
        // 镜像赛时 ContentView 会在本地加完后再 sendControl 通知手机；
        // 手机端 seq 去重保证不重复加，max 对齐保证手机临时不可达期间本地领先不被旧快照覆盖。
        guard isMatchActive else { return }
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
        // 第 4 节（含加时）结束：非平分则直接判胜，平分才进加时
        if periodIndex >= 4 && teamAScore != teamBScore {
            finishLocalMatch()
            return
        }
        periodIndex += 1
        updatePeriodLabel()
        summary = "进入\(periodLabel)"
    }

    func applyPhoneStart(sport: String, trackWearer: Bool = true) {
        phoneSession?.resetControlSeq()
        sessionSource = .phone
        self.sport = sport
        sportLabel = displayName(for: sport)
        lastResult = nil
        lastSeenPhoneMatchStartMs = 0   // 新一场：清身份标识，首个 syncMatchState 会按新场采纳
        finishedPhoneMatchStartMs = 0
        isMatchActive = true
        isPaused = false
        canUndo = false
        elapsedSeconds = 0           // 必须清，否则 matchStartDate 会算成"上一场开始时间"
        periodIndex = 1
        setWins = [0, 0]
        setScores.removeAll()
        setTimes.removeAll()
        matchEvents.removeAll()
        history.removeAll()
        heartRateTimeline.removeAll()
        teamAScore = 0
        teamBScore = 0
        teamASubtitle = ""
        teamBSubtitle = ""
        summary = "手机端已开始"
        matchStartDate = Date()
        pausedAccumulated = 0
        pausedAt = nil
        print("[Watch][Match] applyPhoneStart sport=\(sport) trackWearer=\(trackWearer)")
        // workout 照常开（保后台保活，记分稳）；但只有 trackWearer 时才读心率。
        workoutManager?.start(sport: sport, trackHR: trackWearer)
        swingDetector?.reset()
        swingDetector?.start()
        // 录音(AudioGate)只在追踪佩戴者、且用户开了开关时才启动；否则显式停掉（防上一场残留）
        updateAudioGate(trackWearer: trackWearer)
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
        swingDetector?.stop()
        audioGate?.stopListening()
    }

    func applyPhoneState(_ msg: [String: Any]) {
        // 数据对齐方案：去掉 .local 拒收，永远接收手机快照；
        // 但比分类数据用 max(本地, 手机) —— 防止"手表刚加了分、手机暂时没收到、
        // 它推一个旧快照把本地拉回去"的回退。
        // 手表自己开的独立赛（startLocalMatch）保留 sessionSource=.local，不被这条干扰。
        print("[Watch][Match] applyPhoneState raw=\(msg)")
        DispatchQueue.main.async {
            let isActive = msg["isActive"] as? Bool ?? false

            // 守卫：手表刚在本地结束镜像赛、正显示结算页（lastResult != nil）时，
            // 忽略手机仍报"进行中"的旧心跳，避免被重新激活回记分页、导致再次结束把局分加两遍。
            // 等手机处理完结束推送 isActive=false，再走下面的清理分支。
            if isActive && self.lastResult != nil {
                print("[Watch][Match] applyPhoneState ignored (settling, lastResult set)")
                return
            }

            // 手机说结束了 → 跟着结束（独立赛不受影响：它自己的 finishLocalMatch 才负责清理）
            if !isActive {
                if self.sessionSource == .phone {
                    self.sessionSource = .none
                    self.isMatchActive = false
                    self.isPaused = false
                    self.canUndo = false
                    self.summary = "手机端已结束"
                    self.stopTicker()
                    self.workoutManager?.stop()
                }
                return
            }

            // 比赛身份判断（时间戳对齐）：用手机的 matchStartMs 区分是不是同一场。
            // 仅对镜像赛/空闲生效，手表自己开的独立赛（.local）不被手机快照干扰。
            let phoneStartMs = msg["matchStartMs"] as? Int ?? 0
            if phoneStartMs != 0 && self.sessionSource != .local {
                // 刚结束的那一场的滞后心跳（手机还没处理完结束）→ 忽略，别被拉回记分页
                if phoneStartMs == self.finishedPhoneMatchStartMs {
                    print("[Watch][Match] applyPhoneState ignored (finished match \(phoneStartMs) lagging heartbeat)")
                    return
                }
                // 新的一场（matchStartMs 变了）→ 先清零本地残留，下面 max 对齐自然采纳手机新值，
                // 而不会被上一场的旧高分卡住。
                if phoneStartMs != self.lastSeenPhoneMatchStartMs {
                    print("[Watch][Match] applyPhoneState new match \(phoneStartMs)，重置本地状态")
                    self.resetScoreState()
                    self.lastSeenPhoneMatchStartMs = phoneStartMs
                    self.finishedPhoneMatchStartMs = 0
                    self.lastResult = nil
                }
            }

            // 规则字段：永远跟手机走（手机是规则权威）
            self.sport = msg["sport"] as? String ?? self.sport
            self.sportLabel = msg["sportLabel"] as? String ?? self.displayName(for: self.sport)
            self.teamAName = msg["teamAName"] as? String ?? self.teamAName
            self.teamBName = msg["teamBName"] as? String ?? self.teamBName
            self.supportsMultiPoint = msg["supportsMultiPoint"] as? Bool ?? false
            self.ptWin = msg["ptWin"] as? Int ?? self.ptWin
            self.totalSets = msg["totalSets"] as? Int ?? self.totalSets
            self.setWin = msg["setWin"] as? Int ?? self.setWin
            self.periodLabel = msg["periodLabel"] as? String ?? self.periodLabel
            self.teamASubtitle = msg["teamASubtitle"] as? String ?? self.teamASubtitle
            self.teamBSubtitle = msg["teamBSubtitle"] as? String ?? self.teamBSubtitle
            self.summary = msg["summary"] as? String ?? self.summary
            // 暂停状态：手机权威（防止手表本地暂停状态和手机不一致）
            self.isPaused = msg["isPaused"] as? Bool ?? false
            let trackWearer = self.shouldTrackWearer()

            // 比分/局数/时间：max 对齐（核心）
            let phoneA = msg["teamAScore"] as? Int ?? 0
            let phoneB = msg["teamBScore"] as? Int ?? 0
            self.teamAScore = max(self.teamAScore, phoneA)
            self.teamBScore = max(self.teamBScore, phoneB)
            let phonePeriod = msg["periodIndex"] as? Int ?? self.periodIndex
            self.periodIndex = max(self.periodIndex, phonePeriod)
            if let phoneSW = msg["setWins"] as? [Int], phoneSW.count == 2 {
                self.setWins = [
                    max(self.setWins[0], phoneSW[0]),
                    max(self.setWins[1], phoneSW[1])
                ]
            }
            let phoneElapsed = msg["elapsedSeconds"] as? Int ?? 0
            self.elapsedSeconds = max(self.elapsedSeconds, phoneElapsed)

            // 状态机：第一次进入或重新激活
            if !self.isMatchActive {
                self.isMatchActive = true
                if self.sessionSource == .none { self.sessionSource = .phone }
            }

            print("[Watch][Match] applied phone state src=\(self.sessionSource) score=\(self.teamAScore):\(self.teamBScore) period=\(self.periodIndex) setWins=\(self.setWins)")
            if self.isPaused {
                self.stopTicker()
            } else if self.ticker == nil {
                self.startTicker()
            }
            // applyPhoneState 是可靠的 applicationContext 通道，必须和 applyPhoneStart 走同一套门控：
            // 否则 sendMessage 丢了时会退化成“谁都记心率 + 录音永远不启动”。
            self.workoutManager?.start(sport: self.sport, trackHR: trackWearer)
            self.updateAudioGate(trackWearer: trackWearer)
        }
    }

    private func shouldTrackWearer() -> Bool {
        !hrPersonName.isEmpty && (teamAName == hrPersonName || teamBName == hrPersonName)
    }

    private func updateAudioGate(trackWearer: Bool) {
        if trackWearer && audioGate?.isEnabled == true {
            audioGate?.startListening()
        } else {
            audioGate?.stopListening()
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
            finishLocalMatch(alreadyScored: true)   // 本局已记，勿重复
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
                "swingCount": swingDetector?.swingCount ?? 0,
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
