import SwiftUI

/// SwingTrainer 的 iPhone 容器 App。
/// 作用有二：1) 作为 SwingTrainer Watch App 的 companion，让独立的挥拍训练手表 App
/// 能安装到 Apple Watch；2) 接收手表传来的 IMU JSON 文件，存进 Documents 供「文件」App 导出。
@main
struct TrainerApp: App {
    @StateObject private var receiver = WatchReceiver()

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 14) {
                Image(systemName: "figure.badminton")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.blue)
                Text("挥拍训练")
                    .font(.title2.bold())
                Text("在 Apple Watch 上采集挥拍数据，结束后同步到手机。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Divider().padding(.vertical, 4)

                VStack(spacing: 6) {
                    Text("已接收 \(receiver.receivedCount) 个文件")
                        .font(.headline)
                        .foregroundStyle(receiver.receivedCount > 0 ? .green : .secondary)
                    if !receiver.lastFileName.isEmpty {
                        Text("最新：\(receiver.lastFileName)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 24)
                    }
                    Text("在「文件」App →「我的 iPhone」→「挥拍训练」中导出")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 2)
                }
            }
        }
    }
}
