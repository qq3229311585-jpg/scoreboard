import UIKit
import Capacitor

/// 继承 CAPBridgeViewController，用于注册本地 Swift 插件。
/// 本地插件（非 SPM 包）必须在此处手动注册，否则 Capacitor 不会调用 load()，
/// 导致 WCSession / HealthKit 从不初始化。
class ViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(WatchPlugin())
        bridge?.registerPluginInstance(HealthKitPlugin())
    }
}
