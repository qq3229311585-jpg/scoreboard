import SwiftUI

// MARK: - Setup: 球技选择列表

struct SetupView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(StrokeType.allCases) { t in
                    NavigationLink(value: t) {
                        HStack(spacing: 10) {
                            Image(systemName: t.icon)
                                .font(.system(size: 22, weight: .semibold))
                                .frame(width: 30)
                                .foregroundStyle(.blue)
                            Text(t.rawValue)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .navigationTitle("挥拍训练")
    }
}

// MARK: - Start: 确认球技，开始录制

struct StartView: View {
    let strokeType: StrokeType
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: strokeType.icon)
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.blue)
                Text(strokeType.rawValue)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Text("50Hz 原始录制")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onStart) {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill").font(.system(size: 16))
                    Text("开始录制").font(.system(size: 17, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .padding(.horizontal, 4)
            .padding(.bottom, 6)
        }
        .navigationTitle(strokeType.rawValue)
    }
}

// MARK: - Recording: 只显示录制状态，不显示计数

struct RecordingView: View {
    @EnvironmentObject var session: RecordingSession
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.15))
                    .frame(width: 72, height: 72)
                    .scaleEffect(pulse ? 1.4 : 1.0)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
                Circle()
                    .fill(Color.red)
                    .frame(width: 18, height: 18)
            }
            .onAppear { pulse = true }

            Text("录制中")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 10)

            Spacer()

            HStack(spacing: 8) {
                Button { session.pauseRecording() } label: {
                    Text("暂停")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.bordered)
                .tint(.orange)

                Button { session.stopRecording() } label: {
                    Text("停止")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
    }
}

// MARK: - Paused

struct PausedView: View {
    @EnvironmentObject var session: RecordingSession

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                Text("已暂停")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Button { session.resumeRecording() } label: {
                    Text("继续")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                Button { session.stopRecording() } label: {
                    Text("停止")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
    }
}

// MARK: - Summary: 录制结束，同步到手机

struct SummaryView: View {
    var onRetry: (() -> Void)? = nil
    @EnvironmentObject var session: RecordingSession

    var durationStr: String {
        let s = session.elapsedSeconds
        return "\(s / 60)分\(s % 60)秒"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                // 信息卡
                VStack(spacing: 6) {
                    infoRow("球技", session.strokeType.rawValue, .yellow)
                    Divider().opacity(0.3)
                    infoRow("时长", durationStr, .blue)
                    Divider().opacity(0.3)
                    infoRow("加速度", "\(session.recorder.accelCount)点 @800Hz", .green)
                    Divider().opacity(0.3)
                    infoRow("姿态", "\(session.recorder.motionCount)点 @100Hz", .cyan)
                }
                .padding(10)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // 同步按钮区
                sendSection

                // 其他操作
                VStack(spacing: 6) {
                    Button {
                        onRetry?()
                        session.startRecording()
                    } label: {
                        Text("再来一组").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        session.phase = .setup
                        session.recorder.reset()
                    } label: {
                        Text("返回首页").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }

    func infoRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
        }
    }

    @ViewBuilder
    var sendSection: some View {
        switch session.sendState {
        case .idle:
            Button { session.sendToPhone() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "iphone.and.arrow.right.outward")
                    Text("同步到手机")
                }
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)

        case .transferring:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("写入文件中…").font(.system(size: 12))
            }
            .foregroundStyle(.blue)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.blue.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .done:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                Text("已排队传输").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.green)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Color.green.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .error:
            VStack(spacing: 5) {
                Text(session.sendError ?? "传输出错")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                Button { session.sendToPhone() } label: {
                    Text("重试").frame(maxWidth: .infinity).padding(.vertical, 5)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(8)
            .background(Color.red.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
