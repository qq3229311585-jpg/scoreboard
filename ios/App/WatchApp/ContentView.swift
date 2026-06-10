import SwiftUI
import WatchKit

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var workout: WorkoutManager
    @EnvironmentObject var match: WatchMatchManager
    @EnvironmentObject var phone: PhoneSessionManager

    var body: some View {
        // 记分页只由 match.isMatchActive 驱动，不再混入 workout.isActive：
        // HealthKit workout 的启停是异步的，若把它作为进入条件，forceReset/结束时
        // 会因 workout 还没停而短暂停留在 MatchView，产生"闪一下设置页又回首页"的竞态。
        if match.isMatchActive {
            MatchView()
        } else {
            NavigationStack {
                if let pendingSport = match.pendingSetupSport,
                   let pendingSportName = match.pendingSetupSportName {
                    MatchSettingsView(sport: pendingSport, sportName: pendingSportName)
                } else {
                    IdleView()
                }
            }
            .onAppear {
                workout.requestAuthorization { _ in }
            }
        }
    }
}

// MARK: - Idle ─ 首页

struct IdleView: View {
    @EnvironmentObject var match: WatchMatchManager

    private let sports: [(id: String, name: String, symbol: String, hex: String)] = [
        ("badminton",   "羽毛球", "figure.badminton",    "#2A6B5B"),
        ("tabletennis", "乒乓球", "figure.table.tennis", "#7A3A2A"),
        ("tennis",      "网球",   "figure.tennis",       "#4A6B2A"),
        ("basketball",  "篮球",   "figure.basketball",   "#7A4E20"),
    ]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 6),
                              GridItem(.flexible(), spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(sports, id: \.id) { sport in
                        // 导航到比赛设置页
                        NavigationLink {
                            MatchSettingsView(sport: sport.id, sportName: sport.name)
                        } label: {
                            SportCard(symbol: sport.symbol,
                                      name: sport.name,
                                      hex: sport.hex)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
        }
        .navigationBarBackButtonHidden(true)
    }
}

struct SportCard: View {
    let symbol: String; let name: String; let hex: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
            Text(name)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, minHeight: 72)
        .background(Color(hex: hex),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Match Settings ─ 比赛设置

struct MatchSettingsView: View {
    let sport: String
    let sportName: String

    @EnvironmentObject var match: WatchMatchManager
    @Environment(\.dismiss) var dismiss

    // 优先使用手机历史记录中同步来的真实名字；只有完全没有时才回退到默认词
    private var nameOptions: [String] {
        let defaults = sport == "basketball"
            ? ["主队", "客队", "我方", "对手"]
            : ["我方", "对手", "主队", "客队"]
        let synced = match.profileNames.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return synced.isEmpty ? defaults : synced
    }

    @State private var selectedA = 0
    @State private var selectedB = 1
    // 非篮球规则
    @State private var ptWin: Int
    @State private var totalSets: Int

    private let ptOptions = [6, 7, 11, 15, 21, 25, 30]
    private let setOptions = [1, 3, 5]

    init(sport: String, sportName: String) {
        self.sport = sport
        self.sportName = sportName
        let defaultPtWin: Int
        switch sport {
        case "tabletennis": defaultPtWin = 11
        case "tennis":      defaultPtWin = 6
        default:            defaultPtWin = 21
        }
        _ptWin = State(initialValue: defaultPtWin)
        _totalSets = State(initialValue: 3)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                // ── 球员名选择 ──
                settingsCard {
                    VStack(spacing: 0) {
                        pickerRow(
                            label: sport == "basketball" ? "主队" : "红方",
                            options: nameOptions,
                            selection: $selectedA
                        )
                        Divider().background(.white.opacity(0.08))
                        pickerRow(
                            label: sport == "basketball" ? "客队" : "蓝方",
                            options: nameOptions,
                            selection: $selectedB
                        )
                    }
                }

                // ── 分数规则（非篮球）──
                if sport != "basketball" {
                    settingsCard {
                        VStack(spacing: 0) {
                            stepperRow(label: sport == "tennis" ? "赢局" : "赢分",
                                       options: ptOptions,
                                       value: $ptWin)
                            Divider().background(.white.opacity(0.08))
                            stepperRow(label: "局数",
                                       options: setOptions,
                                       value: $totalSets)
                        }
                    }
                    if sport == "tennis" {
                        Text("简化版网球：先赢 N 局且领先 2 局。无 15/30/40 与抢七。")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.horizontal, 6)
                            .multilineTextAlignment(.leading)
                    }
                }

                // ── 开始按钮 ──
                Button {
                    WKInterfaceDevice.current().play(.start)
                    let names = nameOptions
                    // 确保 A/B 不同（两人选了同一个名字时自动取下一个）
                    let effectiveB = selectedB == selectedA
                        ? (selectedA + 1) % max(1, names.count)
                        : selectedB
                    match.startLocalMatch(
                        sport: sport,
                        nameA: names[safe: selectedA] ?? "我方",
                        nameB: names[safe: effectiveB] ?? "对手",
                        ptWin: sport == "basketball" ? 0 : ptWin,
                        totalSets: sport == "basketball" ? 4 : totalSets
                    )
                } label: {
                    Text("开始比赛")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color(hex: "#C8E645"),
                                    in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
        }
        .navigationTitle(sportName)
        .navigationBarTitleDisplayMode(.inline)
        // 当本页是"重设"后作为 NavigationStack 根显示时（pendingSetupSport != nil），
        // 系统没有返回手势，补一个回首页按钮；从首页 NavigationLink 进来时则用系统返回。
        .toolbar {
            if match.pendingSetupSport != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        match.pendingSetupSport = nil
                        match.pendingSetupSportName = nil
                    } label: {
                        Image(systemName: "house.fill")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
            }
        }
    }

    // MARK: helpers
    @ViewBuilder
    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(.white.opacity(0.07),
                         in: RoundedRectangle(cornerRadius: 12))
    }

    private func pickerRow(label: String, options: [String], selection: Binding<Int>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 34, alignment: .leading)
            Picker("", selection: selection) {
                ForEach(options.indices, id: \.self) { i in
                    Text(options[i]).tag(i)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 52)
            .clipped()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }

    private func stepperRow(label: String, options: [Int], value: Binding<Int>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            HStack(spacing: 12) {
                Button {
                    if let idx = options.firstIndex(of: value.wrappedValue), idx > 0 {
                        value.wrappedValue = options[idx - 1]
                    }
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)

                Text("\(value.wrappedValue)")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 28)

                Button {
                    if let idx = options.firstIndex(of: value.wrappedValue),
                       idx < options.count - 1 {
                        value.wrappedValue = options[idx + 1]
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

// MARK: - Match ─ 记分主界面

struct MatchView: View {
    @EnvironmentObject var workout: WorkoutManager
    @EnvironmentObject var match: WatchMatchManager
    @EnvironmentObject var phone: PhoneSessionManager

    // 暂停时触发"重新设置"——退出比赛回到 IdleView
    @State private var showResetConfirm = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .padding(.bottom, 3)

                // ── 左右双面板 ──
                HStack(spacing: 5) {
                    PanelView(
                        name: match.teamAName,
                        score: match.teamAScore,
                        subtitle: match.teamASubtitle,
                        hex: "#C83030",
                        supportsMultiPoint: match.supportsMultiPoint,
                        onPoint: { primaryScore(team: 0) },
                        onPlus2: { addScore(team: 0, delta: 2) },
                        onPlus3: { addScore(team: 0, delta: 3) }
                    )
                    PanelView(
                        name: match.teamBName,
                        score: match.teamBScore,
                        subtitle: match.teamBSubtitle,
                        hex: "#1E5FA0",
                        supportsMultiPoint: match.supportsMultiPoint,
                        onPoint: { primaryScore(team: 1) },
                        onPlus2: { addScore(team: 1, delta: 2) },
                        onPlus3: { addScore(team: 1, delta: 3) }
                    )
                }
                .padding(.horizontal, 5)
                .frame(maxHeight: .infinity)

                bottomBar
                    .padding(.horizontal, 8)
                    .padding(.top, 3)
                    .padding(.bottom, 2)
            }
            .background(Color.black.ignoresSafeArea())

            // ── 暂停遮罩 ──
            if match.isPaused {
                PauseOverlay(onReset: {
                    // 重新设置：直接结束当前比赛，回到首页（NavigationStack pop）
                    match.forceReset()
                })
            }
        }
        .navigationBarBackButtonHidden(true)
    }

    // MARK: 顶部状态栏
    private var topBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(hex: "#FF3B30"))
                Text(workout.heartRate > 0 ? "\(Int(workout.heartRate))" : "--")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(minWidth: 44, alignment: .leading)

            Spacer()

            VStack(spacing: 0) {
                Text(match.periodLabel.isEmpty ? match.sportLabel : match.periodLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(match.sessionSource == .local
                        ? Color(hex: "#4CD964") : Color(hex: "#5AC8FA"))
                    .lineLimit(1)
                Text(formatTime(match.elapsedSeconds))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()

            HStack(spacing: 2) {
                if phone.isReachable {
                    Image(systemName: "iphone")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: "#4CD964"))
                } else {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.22))
                }
            }
            .frame(minWidth: 44, alignment: .trailing)
        }
    }

    // MARK: 底部控制栏
    private var bottomBar: some View {
        HStack(spacing: 4) {
            ctrlBtn(icon: "arrow.uturn.backward",
                    color: match.canUndo ? .white.opacity(0.55) : .white.opacity(0.18)) {
                guard match.canUndo else { return }
                haptic(.click)
                if match.isLocalSession { match.undo() }
                else { phone.sendControl("undo") }
            }
            ctrlBtn(icon: "pause.fill", color: Color(hex: "#FFD60A")) {
                haptic(.directionUp)
                if match.isLocalSession { match.togglePause() }
                else { phone.sendControl("togglePause") }
            }
            if match.supportsMultiPoint {
                ctrlBtn(icon: "forward.end.fill", color: Color(hex: "#5AC8FA")) {
                    haptic(.success)
                    if match.isLocalSession { match.nextPeriod() }
                    else { phone.sendControl("nextPeriod") }
                }
            }
            ctrlBtn(icon: "xmark.circle.fill", color: Color(hex: "#FF3B30")) {
                haptic(.failure)
                if match.isLocalSession { match.finishLocalMatch() }
                else { phone.requestStopFromWatch() }
            }
        }
    }

    private func ctrlBtn(icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func addScore(team: Int, delta: Int) {
        // 更强的震动：连续两次 click，达到明显感知
        WKInterfaceDevice.current().play(.notification)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            WKInterfaceDevice.current().play(.notification)
        }
        if match.isLocalSession { match.addScore(team: team, delta: delta) }
        else { phone.sendControl("addScore", delta: delta, team: team) }
    }

    private func primaryScore(team: Int) {
        if match.supportsMultiPoint {
            addScore(team: team, delta: 1)
            return
        }
        WKInterfaceDevice.current().play(.notification)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            WKInterfaceDevice.current().play(.notification)
        }
        if match.isLocalSession { match.addPoint(team: team) }
        else { phone.sendControl("addPoint", team: team) }
    }

    private func haptic(_ t: WKHapticType) { WKInterfaceDevice.current().play(t) }
    private func formatTime(_ s: Int) -> String { String(format: "%02d:%02d", s / 60, s % 60) }
}

// MARK: - Panel ─ 左/右得分面板

struct PanelView: View {
    let name: String; let score: Int; let subtitle: String
    let hex: String; let supportsMultiPoint: Bool
    let onPoint: () -> Void; let onPlus2: () -> Void; let onPlus3: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(hex: hex))
                .onTapGesture(count: 2, perform: onPoint)

            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)

                Text("\(score)")
                    .font(.system(size: 42, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.top, 1)

                Spacer()

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.horizontal, 8)
                }

                if supportsMultiPoint {
                    HStack(spacing: 3) {
                        miniBtn("+2", action: onPlus2)
                        miniBtn("+3", action: onPlus3)
                    }
                    .padding(.horizontal, 5)
                    .padding(.bottom, 6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func miniBtn(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.white.opacity(0.22), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pause Overlay ─ 暂停遮罩（带模糊）

struct PauseOverlay: View {
    @EnvironmentObject var match: WatchMatchManager
    @EnvironmentObject var phone: PhoneSessionManager
    var onReset: () -> Void

    var body: some View {
        ZStack {
            // 毛玻璃模糊背景
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .overlay(Color.black.opacity(0.45).ignoresSafeArea())

            VStack(spacing: 10) {
                // 当前比分
                Text("\(match.teamAScore)  :  \(match.teamBScore)")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)

                Text(formatTime(match.elapsedSeconds) + " · 已暂停")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))

                // 操作按钮
                HStack(spacing: 8) {
                    // 继续
                    pauseBtn(icon: "play.fill",
                             label: "继续",
                             color: Color(hex: "#4CD964")) {
                        haptic(.start)
                        if match.isLocalSession { match.togglePause() }
                        else { phone.sendControl("togglePause") }
                    }
                    // 重新设置（仅本地赛）
                    if match.isLocalSession {
                        pauseBtn(icon: "arrow.counterclockwise",
                                 label: "重设",
                                 color: Color(hex: "#FFD60A")) {
                            haptic(.directionUp)
                            onReset()
                        }
                    }
                    // 结束
                    pauseBtn(icon: "xmark",
                             label: "结束",
                             color: Color(hex: "#FF3B30")) {
                        haptic(.failure)
                        if match.isLocalSession { match.finishLocalMatch() }
                        else { phone.requestStopFromWatch() }
                    }
                }

                // 撤销（仅本地赛且有历史）
                if match.isLocalSession && match.canUndo {
                    Button {
                        haptic(.click)
                        match.undo()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward")
                            Text("撤销上一分")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func pauseBtn(icon: String, label: String, color: Color,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(width: 54, height: 50)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func haptic(_ t: WKHapticType) { WKInterfaceDevice.current().play(t) }
    private func formatTime(_ s: Int) -> String { String(format: "%02d:%02d", s / 60, s % 60) }
}

// MARK: - Color helper

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let n = UInt64(h, radix: 16) ?? 0
        let r = Double((n >> 16) & 0xFF) / 255
        let g = Double((n >>  8) & 0xFF) / 255
        let b = Double( n        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Array safe subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
