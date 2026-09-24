import SwiftUI
import WatchKit

// MARK: - Palette

/// 与手机端默认主题保持一致，红蓝两方在两端颜色相同，一眼能对上。
enum Palette {
    static let teamA  = Color(hex: "#D95F4B")
    static let teamB  = Color(hex: "#4A7FA8")
    static let accent = Color(hex: "#C8E645")
    static let win    = Color(hex: "#30D158")
    static let heart  = Color(hex: "#FF453A")
    static let pause  = Color(hex: "#FFD60A")
    static let info   = Color(hex: "#5AC8FA")
    static let card   = Color.white.opacity(0.08)
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var workout: WorkoutManager
    @EnvironmentObject var match: WatchMatchManager
    @EnvironmentObject var phone: PhoneSessionManager

    var body: some View {
        // 记分页只由 match.isMatchActive 驱动，不再混入 workout.isActive：
        // HealthKit workout 的启停是异步的，若把它作为进入条件，forceReset/结束时
        // 会因 workout 还没停而短暂停留在 MatchView，产生"闪一下设置页又回首页"的竞态。
        if let result = match.lastResult {
            SettlementView(result: result)
        } else if match.isMatchActive {
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
    @EnvironmentObject var phone: PhoneSessionManager

    private struct Sport: Identifiable {
        let id: String; let name: String; let symbol: String; let hex: String; let hint: String
    }

    private let sports: [Sport] = [
        Sport(id: "badminton",   name: "羽毛球", symbol: "figure.badminton",    hex: "#2A7A66", hint: "21 分"),
        Sport(id: "tabletennis", name: "乒乓球", symbol: "figure.table.tennis", hex: "#8A4030", hint: "11 分"),
        Sport(id: "tennis",      name: "网球",   symbol: "figure.tennis",       hex: "#56792E", hint: "6 局"),
        Sport(id: "basketball",  name: "篮球",   symbol: "figure.basketball",   hex: "#8A5A22", hint: "4 节"),
    ]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                statusRow

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6),
                                    GridItem(.flexible(), spacing: 6)],
                          spacing: 6) {
                    ForEach(sports) { sport in
                        NavigationLink {
                            MatchSettingsView(sport: sport.id, sportName: sport.name)
                        } label: {
                            SportCard(symbol: sport.symbol, name: sport.name,
                                      hint: sport.hint, hex: sport.hex)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(phone.isReachable
                     ? "在手机上开赛，手表会自动进入同步记分"
                     : "未连接 iPhone 也能独立开赛，结束后自动同步")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
        .navigationTitle("记分器")
        .navigationBarBackButtonHidden(true)
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            StatusChip(icon: phone.isReachable ? "iphone" : "iphone.slash",
                       text: phone.isReachable ? "已连接" : "独立模式",
                       color: phone.isReachable ? Palette.win : .white.opacity(0.45))
            if !match.hrPersonName.isEmpty {
                StatusChip(icon: "heart.fill", text: match.hrPersonName, color: Palette.heart)
            }
            Spacer(minLength: 0)
        }
    }
}

struct StatusChip: View {
    let icon: String; let text: String; let color: Color
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: 10, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
    }
}

struct SportCard: View {
    let symbol: String; let name: String; let hint: String; let hex: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 4)
            Text(name)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(hint)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
        .background(
            LinearGradient(colors: [Color(hex: hex), Color(hex: hex).opacity(0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
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

    // B 的可选名单：去掉 A 已经选中的那个
    private var nameOptionsB: [String] {
        let all = nameOptions
        guard selectedA < all.count else { return all }
        return all.filter { $0 != all[selectedA] }
    }

    @State private var selectedA = 0
    // B 用的是 nameOptionsB（已去掉 A 选中的那个），默认就指它的第一项；
    // 设成 1 会在名单只剩 1 项时越界，回退成"对手"。
    @State private var selectedB = 0
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

    private var ruleSummary: String {
        if sport == "basketball" { return "4 节 · 累计得分 · 平分进加时" }
        let unit = sport == "tennis" ? "局" : "分"
        let sets = totalSets == 1 ? "1 局定胜负" : "\(totalSets) 局 \(Int(ceil(Double(totalSets) / 2))) 胜"
        return "先到 \(ptWin) \(unit) · \(sets)"
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                settingsCard {
                    VStack(spacing: 0) {
                        pickerRow(color: Palette.teamA, options: nameOptions, selection: $selectedA)
                        Divider().background(.white.opacity(0.08))
                        pickerRow(color: Palette.teamB, options: nameOptionsB, selection: $selectedB)
                            .onChange(of: selectedA) { _ in
                                // A 换人后 B 重置到第一个（避免 index 越界或隐式指向旧名字）
                                selectedB = 0
                            }
                    }
                }

                if sport != "basketball" {
                    settingsCard {
                        VStack(spacing: 0) {
                            stepperRow(label: sport == "tennis" ? "赢局" : "赢分",
                                       options: ptOptions, value: $ptWin)
                            Divider().background(.white.opacity(0.08))
                            stepperRow(label: "局数", options: setOptions, value: $totalSets)
                        }
                    }
                }

                Text(sport == "tennis" ? ruleSummary + "\n简化网球：无 15/30/40 与抢七" : ruleSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                Button {
                    WKInterfaceDevice.current().play(.start)
                    match.startLocalMatch(
                        sport: sport,
                        nameA: nameOptions[safe: selectedA] ?? "我方",
                        nameB: nameOptionsB[safe: selectedB] ?? "对手",
                        ptWin: sport == "basketball" ? 0 : ptWin,
                        totalSets: sport == "basketball" ? 4 : totalSets
                    )
                } label: {
                    Label("开始比赛", systemImage: "play.fill")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Palette.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)
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

    @ViewBuilder
    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func pickerRow(color: Color, options: [String], selection: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(color)
                .frame(width: 4, height: 28)
            Picker("", selection: selection) {
                ForEach(options.indices, id: \.self) { i in
                    Text(options[i]).tag(i)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 52)
            .clipped()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    private func stepperRow(label: String, options: [Int], value: Binding<Int>) -> some View {
        let idx = options.firstIndex(of: value.wrappedValue)
        let canDec = (idx ?? 0) > 0
        let canInc = (idx ?? options.count - 1) < options.count - 1
        return HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            HStack(spacing: 10) {
                stepButton("minus", enabled: canDec) {
                    if let idx, idx > 0 { value.wrappedValue = options[idx - 1] }
                }
                Text("\(value.wrappedValue)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .frame(minWidth: 26)
                stepButton("plus", enabled: canInc) {
                    if let idx, idx < options.count - 1 { value.wrappedValue = options[idx + 1] }
                }
            }
            .animation(.snappy, value: value.wrappedValue)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func stepButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            WKInterfaceDevice.current().play(.click)
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 1 : 0.3))
                .frame(width: 30, height: 30)
                .background(.white.opacity(enabled ? 0.16 : 0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Match ─ 记分主界面

struct MatchView: View {
    @EnvironmentObject var workout: WorkoutManager
    @EnvironmentObject var match: WatchMatchManager
    @EnvironmentObject var phone: PhoneSessionManager
    @EnvironmentObject var swingDetector: SwingDetector

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .padding(.bottom, 4)

                HStack(spacing: 5) {
                    PanelView(
                        name: match.teamAName,
                        score: match.teamAScore,
                        subtitle: match.teamASubtitle,
                        color: Palette.teamA,
                        isLeading: match.teamAScore > match.teamBScore,
                        badge: match.pointBadge(for: 0),
                        supportsMultiPoint: match.supportsMultiPoint,
                        onPoint: { primaryScore(team: 0) },
                        onPlus2: { addScore(team: 0, delta: 2) },
                        onPlus3: { addScore(team: 0, delta: 3) }
                    )
                    PanelView(
                        name: match.teamBName,
                        score: match.teamBScore,
                        subtitle: match.teamBSubtitle,
                        color: Palette.teamB,
                        isLeading: match.teamBScore > match.teamAScore,
                        badge: match.pointBadge(for: 1),
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
                    .padding(.top, 4)
                    .padding(.bottom, 2)
            }
            .background(Color.black.ignoresSafeArea())

            if match.isPaused {
                PauseOverlay(onReset: { match.forceReset() })
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: match.isPaused)
        .navigationBarBackButtonHidden(true)
    }

    // MARK: 顶部状态栏
    private var topBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(workout.heartRate > 0 ? Palette.heart : .white.opacity(0.25))
                    .symbolEffect(.pulse, isActive: workout.heartRate > 0)
                Text(workout.heartRate > 0 ? "\(Int(workout.heartRate))" : "--")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            .frame(minWidth: 44, alignment: .leading)

            Spacer()

            VStack(spacing: 0) {
                Text(match.periodLabel.isEmpty ? match.sportLabel : match.periodLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(match.sessionSource == .local ? Palette.win : Palette.info)
                    .lineLimit(1)
                Text(formatTime(match.elapsedSeconds))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            HStack(spacing: 4) {
                if swingDetector.swingCount > 0 {
                    HStack(spacing: 1) {
                        Image(systemName: "figure.badminton")
                            .font(.system(size: 9))
                        Text("\(swingDetector.swingCount)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(Palette.pause)
                }
                // 镜像赛才关心手机连接；独立赛显示"独立"更直观
                Image(systemName: match.sessionSource == .phone
                      ? (phone.isReachable ? "iphone" : "iphone.slash")
                      : "applewatch")
                    .font(.system(size: 10))
                    .foregroundStyle(match.sessionSource == .phone && !phone.isReachable
                                     ? Palette.pause : .white.opacity(0.4))
            }
            .frame(minWidth: 44, alignment: .trailing)
        }
    }

    // MARK: 底部控制栏
    // "结束比赛"只放在暂停页里：记分时手腕乱碰最容易误触，结束又不可撤销。
    private var bottomBar: some View {
        HStack(spacing: 5) {
            ctrlBtn(icon: "arrow.uturn.backward", tint: .white, enabled: match.canUndo) {
                WKInterfaceDevice.current().play(.click)
                undo()
            }
            ctrlBtn(icon: "pause.fill", tint: Palette.pause, enabled: true) {
                WKInterfaceDevice.current().play(.stop)
                togglePause(match: match, phone: phone)
            }
            if match.supportsMultiPoint {
                ctrlBtn(icon: "forward.end.fill", tint: Palette.info, enabled: true) {
                    WKInterfaceDevice.current().play(.success)
                    if match.isLocalSession { match.nextPeriod() }
                    else { phone.sendControl("nextPeriod") }
                }
            }
        }
    }

    private func ctrlBtn(icon: String, tint: Color, enabled: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(enabled ? tint : .white.opacity(0.2))
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(Palette.card, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func undo() {
        guard match.canUndo else { return }
        let mirror = match.sessionSource == .phone
        match.undo()
        if mirror { phone.sendControl("undo") }
    }

    // 记分震动保持原先的"连震两下"，戴着手表挥拍时单次 click 容易感觉不到
    private func scoreHaptic() {
        WKInterfaceDevice.current().play(.notification)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            WKInterfaceDevice.current().play(.notification)
        }
    }

    private func addScore(team: Int, delta: Int) {
        scoreHaptic()
        // 数据对齐方案：无论独立赛还是镜像赛，永远本地立即累计；
        // 镜像赛额外通知手机（手机端 seq 去重+max 对齐，手机锁屏走 transferUserInfo 兜底）
        match.addScore(team: team, delta: delta)
        if match.sessionSource == .phone {
            phone.sendControl("addScore", delta: delta, team: team)
        }
    }

    private func primaryScore(team: Int) {
        if match.supportsMultiPoint {
            addScore(team: team, delta: 1)
            return
        }
        scoreHaptic()
        match.addPoint(team: team)
        if match.sessionSource == .phone {
            phone.sendControl("addPoint", team: team)
        }
    }

    private func formatTime(_ s: Int) -> String { String(format: "%02d:%02d", s / 60, s % 60) }
}

private func togglePause(match: WatchMatchManager, phone: PhoneSessionManager) {
    if match.isLocalSession { match.togglePause() }
    else { phone.sendControl("togglePause") }
}

// MARK: - Panel ─ 左/右得分面板

struct PanelView: View {
    let name: String; let score: Int; let subtitle: String
    let color: Color; let isLeading: Bool; let badge: String?
    let supportsMultiPoint: Bool
    let onPoint: () -> Void; let onPlus2: () -> Void; let onPlus3: () -> Void

    // 手写双击检测：SwiftUI 内置 .onTapGesture(count:2) 在 watchOS 上时间窗约 300ms 极严，
    // 加上子视图会吞手势，实测表现为"点四下才记一分"。第一次点击"上膛"，0.6s 内再点才记分。
    @State private var armedAt: Date? = nil
    @State private var bump = false

    private static let armWindow: TimeInterval = 0.6

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [color, color.opacity(0.7)],
                                     startPoint: .top, endPoint: .bottom))
                .brightness(isLeading ? 0.04 : -0.04)

            // 第一下点击后的"上膛"提示：描边 + 文案，告诉用户再点一次才记分
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(armedAt != nil ? 0.9 : 0), lineWidth: 2)

            VStack(spacing: 0) {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 6)
                    .padding(.top, 7)

                Spacer(minLength: 0)

                Text("\(score)")
                    .font(.system(size: 52, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText(value: Double(score)))
                    .scaleEffect(bump ? 1.1 : 1)
                    .padding(.horizontal, 4)

                Group {
                    if armedAt != nil {
                        Text("再点一次 +1")
                            .foregroundStyle(.white)
                    } else if let badge {
                        Text(badge)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Palette.pause, in: Capsule())
                    } else if !subtitle.isEmpty {
                        Text(subtitle)
                            .foregroundStyle(.white.opacity(0.55))
                    } else {
                        Text(" ")
                    }
                }
                .font(.system(size: 9, weight: .bold))
                .lineLimit(1)

                Spacer(minLength: 0)

                if supportsMultiPoint {
                    HStack(spacing: 3) {
                        miniBtn("+2", action: onPlus2)
                        miniBtn("+3", action: onPlus3)
                    }
                    .padding(.horizontal, 5)
                    .padding(.bottom, 5)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { handleTap() }
        .onChange(of: score) { _ in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { bump = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { bump = false }
            }
        }
        .animation(.easeOut(duration: 0.15), value: armedAt)
        .animation(.snappy, value: score)
    }

    private func handleTap() {
        let now = Date()
        if let armed = armedAt, now.timeIntervalSince(armed) < Self.armWindow {
            armedAt = nil
            onPoint()
            return
        }
        armedAt = now
        WKInterfaceDevice.current().play(.click)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.armWindow) {
            if let armed = armedAt, Date().timeIntervalSince(armed) >= Self.armWindow {
                armedAt = nil
            }
        }
    }

    private func miniBtn(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 26)
                .background(.white.opacity(0.24), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pause Overlay ─ 暂停页

struct PauseOverlay: View {
    @EnvironmentObject var match: WatchMatchManager
    @EnvironmentObject var phone: PhoneSessionManager
    var onReset: () -> Void

    @State private var showFinishConfirm = false
    @State private var showResetConfirm = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .overlay(Color.black.opacity(0.55).ignoresSafeArea())

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        scoreColumn(name: match.teamAName, score: match.teamAScore, color: Palette.teamA)
                        Text(":")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.4))
                        scoreColumn(name: match.teamBName, score: match.teamBScore, color: Palette.teamB)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "pause.circle.fill").foregroundStyle(Palette.pause)
                        Text("已暂停 · \(formatTime(match.elapsedSeconds))")
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .font(.system(size: 11, weight: .medium))

                    Button {
                        WKInterfaceDevice.current().play(.start)
                        togglePause(match: match, phone: phone)
                    } label: {
                        Label("继续比赛", systemImage: "play.fill")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(Palette.win, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 6) {
                        if match.canUndo {
                            smallBtn(icon: "arrow.uturn.backward", label: "撤销", color: .white) {
                                WKInterfaceDevice.current().play(.click)
                                let mirror = match.sessionSource == .phone
                                match.undo()
                                if mirror { phone.sendControl("undo") }
                            }
                        }
                        if match.isLocalSession {
                            smallBtn(icon: "arrow.counterclockwise", label: "重设", color: Palette.pause) {
                                showResetConfirm = true
                            }
                        }
                        smallBtn(icon: "flag.checkered", label: "结束", color: Palette.heart) {
                            WKInterfaceDevice.current().play(.failure)
                            showFinishConfirm = true
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        .alert("结束比赛？", isPresented: $showFinishConfirm) {
            Button("结束并保存", role: .destructive) {
                if match.isLocalSession { match.finishLocalMatch() }
                else {
                    // .phone 镜像赛：手表以最终状态为权威，构建记录经 transferUserInfo
                    // 保证送达手机（手机死活都不丢），不再仅发 stopWorkout 依赖手机自存。
                    match.finishMirrorMatch()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前局领先方记为本局胜者")
        }
        .alert("重设比赛？", isPresented: $showResetConfirm) {
            Button("清空重设", role: .destructive) { onReset() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本场比分不会保存")
        }
    }

    private func scoreColumn(name: String, score: Int, color: Color) -> some View {
        VStack(spacing: 0) {
            Text("\(score)")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }

    private func smallBtn(icon: String, label: String, color: Color,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func formatTime(_ s: Int) -> String { String(format: "%02d:%02d", s / 60, s % 60) }
}

// MARK: - 结算页

struct SettlementView: View {
    @EnvironmentObject var match: WatchMatchManager
    let result: WatchMatchManager.Result
    @State private var appeared = false

    private var winnerColor: Color { result.winnerIsA ? Palette.teamA : Palette.teamB }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Palette.pause)
                    .scaleEffect(appeared ? 1 : 0.3)
                    .rotationEffect(.degrees(appeared ? 0 : -25))

                Text(result.winnerName)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.4)

                Text("获胜")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(winnerColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
                    .background(winnerColor.opacity(0.2), in: Capsule())

                VStack(spacing: 2) {
                    Text(result.scoreLine)
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.9))
                    if !result.detailLine.isEmpty {
                        Text(result.detailLine)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    if result.durationSeconds > 0 {
                        Label(formatDuration(result.durationSeconds), systemImage: "clock")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text("记录已同步到 iPhone 历史")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))

                Button {
                    match.lastResult = nil
                } label: {
                    Text("完成")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Palette.win, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
        }
        .background(Color.black.ignoresSafeArea())
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: appeared)
        .onAppear {
            appeared = true
            WKInterfaceDevice.current().play(.success)
        }
    }

    private func formatDuration(_ s: Int) -> String {
        s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d 分 %02d 秒", s / 60, s % 60)
    }
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
