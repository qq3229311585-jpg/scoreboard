import Foundation
import WatchConnectivity

/// 接收 SwingTrainer Watch App 通过 transferFile 发来的 IMU JSON 文件，
/// 存进本 App 的 Documents 目录。配合 Info.plist 的 UIFileSharingEnabled，
/// 这些文件会出现在 iPhone「文件」App 里，可 AirDrop / 拷贝到 Mac 给分类器用。
final class WatchReceiver: NSObject, ObservableObject, WCSessionDelegate {

    @Published private(set) var receivedCount = 0
    @Published private(set) var lastFileName  = ""

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// 保存到 Documents 根目录（开启文件共享后直接在「文件」里可见）
    private var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession,
                 activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {
        print("[TrainerApp] WCSession 激活 state=\(state.rawValue) error=\(error?.localizedDescription ?? "无")")
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        // iOS 需重新激活以支持切换手表
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let dest = documentsDir.appendingPathComponent(file.fileURL.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: file.fileURL, to: dest)
            let name = dest.lastPathComponent
            DispatchQueue.main.async {
                self.receivedCount += 1
                self.lastFileName = name
            }
            print("[TrainerApp] 收到文件 \(name)")
        } catch {
            print("[TrainerApp] 接收文件失败 \(error)")
        }
    }
}
