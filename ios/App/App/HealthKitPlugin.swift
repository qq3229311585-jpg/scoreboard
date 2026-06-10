import Capacitor
import HealthKit

/// Capacitor bridge for reading heart rate from HealthKit (Apple Watch data).
/// JS calls:
///   HealthKitPlugin.requestAuthorization()  → Promise<void>
///   HealthKitPlugin.queryHeartRate({ startMs, endMs }) → Promise<{ samples: [{timestamp, bpm}] }>
@objc(HealthKitPlugin)
public class HealthKitPlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier = "HealthKitPlugin"
    public let jsName = "HealthKitPlugin"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "isAvailable", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestAuthorization", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "queryHeartRate", returnType: CAPPluginReturnPromise)
    ]

    private let healthStore = HKHealthStore()

    /// 检查设备是否支持 HealthKit
    @objc func isAvailable(_ call: CAPPluginCall) {
        call.resolve(["available": HKHealthStore.isHealthDataAvailable()])
    }

    /// 请求读取心率数据的权限
    @objc func requestAuthorization(_ call: CAPPluginCall) {
        guard HKHealthStore.isHealthDataAvailable() else {
            call.reject("HealthKit not available on this device")
            return
        }
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            call.reject("Cannot create heart rate type")
            return
        }
        healthStore.requestAuthorization(toShare: [], read: [hrType]) { success, error in
            if let error = error {
                call.reject(error.localizedDescription)
                return
            }
            call.resolve(["granted": success])
        }
    }

    /// 查询指定时间段内的心率样本
    /// 参数: startMs (Unix ms), endMs (Unix ms)
    /// 返回: { samples: [{timestamp: Unix ms, bpm: Int}] }
    @objc func queryHeartRate(_ call: CAPPluginCall) {
        guard HKHealthStore.isHealthDataAvailable() else {
            call.resolve(["samples": []])
            return
        }
        guard let startMs = call.options["startMs"] as? Double,
              let endMs = call.options["endMs"] as? Double else {
            call.reject("startMs and endMs are required")
            return
        }
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            call.reject("Cannot create heart rate type")
            return
        }

        let start = Date(timeIntervalSince1970: startMs / 1000.0)
        let end   = Date(timeIntervalSince1970: endMs   / 1000.0)

        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: .strictStartDate
        )
        let sortDesc = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let beatsPerMin = HKUnit.count().unitDivided(by: .minute())

        let query = HKSampleQuery(
            sampleType: hrType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sortDesc]
        ) { _, samples, error in
            if let error = error {
                call.reject(error.localizedDescription)
                return
            }
            let results: [[String: Any]] = (samples as? [HKQuantitySample] ?? []).map { sample in
                let bpm = sample.quantity.doubleValue(for: beatsPerMin)
                return [
                    "timestamp": sample.startDate.timeIntervalSince1970 * 1000.0,
                    "bpm": Int(bpm.rounded())
                ]
            }
            call.resolve(["samples": results])
        }

        healthStore.execute(query)
    }
}
