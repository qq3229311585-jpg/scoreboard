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
        CAPPluginMethod(name: "queryHeartRate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getUserMetrics", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "queryActiveEnergy", returnType: CAPPluginReturnPromise)
    ]

    private let healthStore = HKHealthStore()

    /// 本插件需要读取的所有 HealthKit 类型（心率、静息心率、活动能量、出生日期）
    private var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        if let hr = HKQuantityType.quantityType(forIdentifier: .heartRate) { types.insert(hr) }
        if let resting = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) { types.insert(resting) }
        if let energy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) { types.insert(energy) }
        if let dob = HKObjectType.characteristicType(forIdentifier: .dateOfBirth) { types.insert(dob) }
        return types
    }

    /// 检查设备是否支持 HealthKit
    @objc func isAvailable(_ call: CAPPluginCall) {
        call.resolve(["available": HKHealthStore.isHealthDataAvailable()])
    }

    /// 请求读取心率数据的权限
    /// ⚠️ 注意：HealthKit 出于隐私设计，**不会告诉调用方"读权限"是否真的获得**。
    /// 这里返回的 `granted` 只表示"授权弹窗流程没出错"——即使用户点了"不允许"，
    /// 也会返回 `granted: true`。后续 `queryHeartRate` 在未授权时会静默返回空数组。
    /// JS 侧不要把 `granted` 当作"能读到数据"的可靠信号。
    @objc func requestAuthorization(_ call: CAPPluginCall) {
        guard HKHealthStore.isHealthDataAvailable() else {
            call.reject("HealthKit not available on this device")
            return
        }
        healthStore.requestAuthorization(toShare: [], read: readTypes) { success, error in
            if let error = error {
                call.reject(error.localizedDescription)
                return
            }
            call.resolve(["granted": success])
        }
    }

    /// 读取用户个人指标，用于个性化心率区间。
    /// 返回: { age: Int?, restingHeartRate: Int?, maxHeartRate: Int? }
    /// 任何一项拿不到则该字段为 NSNull（JS 侧得到 null），由 JS 回退到默认值。
    @objc func getUserMetrics(_ call: CAPPluginCall) {
        guard HKHealthStore.isHealthDataAvailable() else {
            call.resolve(["age": NSNull(), "restingHeartRate": NSNull(), "maxHeartRate": NSNull()])
            return
        }

        // 年龄：从出生日期推算
        var ageValue: Any = NSNull()
        if let dob = try? healthStore.dateOfBirthComponents(),
           let year = dob.year {
            let nowYear = Calendar.current.component(.year, from: Date())
            let age = nowYear - year
            if age > 0 && age < 120 { ageValue = age }
        }

        // 静息心率：取最近一条样本
        guard let restingType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) else {
            call.resolve(["age": ageValue, "restingHeartRate": NSNull(), "maxHeartRate": NSNull()])
            return
        }
        let beatsPerMin = HKUnit.count().unitDivided(by: .minute())
        let sortDesc = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(sampleType: restingType, predicate: nil, limit: 1,
                                  sortDescriptors: [sortDesc]) { _, samples, _ in
            var restingValue: Any = NSNull()
            if let s = (samples as? [HKQuantitySample])?.first {
                let rhr = Int(s.quantity.doubleValue(for: beatsPerMin).rounded())
                if rhr > 0 { restingValue = rhr }
            }
            call.resolve([
                "age": ageValue,
                "restingHeartRate": restingValue,
                "maxHeartRate": NSNull()   // JS 用 Tanaka 公式按 age 计算，原生不下结论
            ])
        }
        healthStore.execute(query)
    }

    /// 查询指定时间段消耗的活动能量（卡路里，kcal）总和。
    /// 参数: startMs, endMs。返回: { kcal: Double }
    @objc func queryActiveEnergy(_ call: CAPPluginCall) {
        guard HKHealthStore.isHealthDataAvailable(),
              let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
              let startMs = call.options["startMs"] as? Double,
              let endMs = call.options["endMs"] as? Double else {
            call.resolve(["kcal": 0])
            return
        }
        let start = Date(timeIntervalSince1970: startMs / 1000.0)
        let end   = Date(timeIntervalSince1970: endMs   / 1000.0)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let query = HKStatisticsQuery(quantityType: energyType, quantitySamplePredicate: predicate,
                                      options: .cumulativeSum) { _, stats, _ in
            let kcal = stats?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
            call.resolve(["kcal": Double(round(kcal * 10) / 10)])
        }
        healthStore.execute(query)
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
