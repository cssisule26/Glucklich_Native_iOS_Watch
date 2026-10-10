import Foundation
import HealthKit
import Combine

struct HealthReading {
    var value: Double
    var date: Date
    var source: String
    var ageMinutes: Double { max(0, Date().timeIntervalSince(date)/60) }
}

@MainActor
final class HealthStore: ObservableObject {
    @Published var heartRate: HealthReading?
    @Published var glucose: HealthReading?
    @Published var trend: Double?
    @Published var activityKcal: Double?
    @Published var activityUpdatedAt: Date?
    @Published var authorizationRequested = false
    @Published var loading = false
    @Published var message: String?
    @Published var demoCGM = true
    private let store = HKHealthStore()
    private var observers: [HKObserverQuery] = []
    private let hrType = HKQuantityType(.heartRate)
    private let glucoseType = HKQuantityType(.bloodGlucose)
    private let energyType = HKQuantityType(.activeEnergyBurned)

    func connect() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            message = "Apple Health requires a supported physical iPhone. Demo mode works in Simulator."
            return
        }
        do {
            try await store.requestAuthorization(toShare: [], read: [hrType, glucoseType, energyType])
            // Completion does not reveal whether read access was granted.
            authorizationRequested = true
            await refresh()
            observe()
        } catch { message = error.localizedDescription }
    }

    func refresh() async {
        guard authorizationRequested else { return }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            async let hrs = samples(hrType, unit: HKUnit.count().unitDivided(by: .minute()), minutes: 60)
            async let sugars = samples(glucoseType, unit: HKUnit(from: "mg/dL"), minutes: 30)
            async let energy = energySamples()
            let (h,g,e) = try await (hrs,sugars,energy)
            heartRate = h.last
            glucose = g.last
            trend = nil
            if let first = g.first, let last = g.last {
                let gap = last.date.timeIntervalSince(first.date)/60
                if gap >= 5 { trend = (last.value-first.value)*5/gap }
            }
            activityKcal = e.isEmpty ? nil : e.reduce(0) { $0+$1.value }
            activityUpdatedAt = e.last?.date
            message = h.isEmpty && g.isEmpty && e.isEmpty ? "No recent readable Health data. Check permissions and sensor synchronization; iOS does not disclose denied read permissions." : nil
        } catch { message = error.localizedDescription }
    }

    private func samples(_ type: HKQuantityType, unit: HKUnit, minutes: Double) async throws -> [HealthReading] {
        try await withCheckedThrowingContinuation { continuation in
            let now = Date()
            let predicate = HKQuery.predicateForSamples(withStart: now.addingTimeInterval(-minutes*60), end: now, options: .strictEndDate)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let rows = (samples as? [HKQuantitySample] ?? []).map { sample in
                    HealthReading(value: sample.quantity.doubleValue(for: unit), date: sample.endDate, source: sample.sourceRevision.source.name)
                }.filter { $0.value.isFinite }
                continuation.resume(returning: rows)
            }
            store.execute(query)
        }
    }

    private func energySamples() async throws -> [HealthReading] {
        // HealthKit's cumulative statistic handles overlapping sources rather
        // than summing duplicated phone/watch raw samples.
        try await withCheckedThrowingContinuation { continuation in
            let now = Date()
            let start = now.addingTimeInterval(-3600)
            let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate)
            let query = HKStatisticsQuery(quantityType: energyType, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
                if let error { continuation.resume(throwing: error); return }
                if let value = result?.sumQuantity()?.doubleValue(for: .kilocalorie()) {
                    continuation.resume(returning: [HealthReading(value: value, date: now, source: "Apple Health · prior hour")])
                } else { continuation.resume(returning: []) }
            }
            store.execute(query)
        }
    }

    private func observe() {
        guard observers.isEmpty else { return }
        for type in [hrType,glucoseType,energyType] {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, done, _ in
                Task { @MainActor in
                    await self?.refresh()
                    done()
                }
            }
            observers.append(query)
            store.execute(query)
        }
    }
}
