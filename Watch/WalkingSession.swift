import Foundation
import HealthKit
import WatchConnectivity
import Combine

@MainActor
final class WalkingSession: NSObject, ObservableObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate, WCSessionDelegate {
    @Published var heartRate: Double?
    @Published var running = false
    @Published var busy = false
    @Published var message: String?
    @Published var forecast: Forecast?
    private let store = HKHealthStore()
    private var workout: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }
    func start() async {
        guard workout == nil, !busy else { return }
        busy = true
        heartRate = nil
        defer { busy = false }
        do {
            let hr = HKQuantityType(.heartRate)
            let energy = HKQuantityType(.activeEnergyBurned)
            try await store.requestAuthorization(toShare: [HKObjectType.workoutType(), energy], read: [hr, energy])
            let config = HKWorkoutConfiguration()
            config.activityType = .walking
            config.locationType = .unknown
            let session = try HKWorkoutSession(healthStore: store, configuration: config)
            let live = session.associatedWorkoutBuilder()
            live.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            session.delegate = self
            live.delegate = self
            workout = session
            builder = live
            let now = Date()
            session.startActivity(with: now)
            try await live.beginCollection(at: now)
            running = true
            message = "Walking session active"
        } catch {
            workout?.end()
            builder?.discardWorkout()
            workout = nil
            builder = nil
            running = false
            message = error.localizedDescription
        }
    }
    func end() {
        guard workout != nil, !busy else { return }
        busy = true
        workout?.end()
    }
    private func finish(at date: Date) async {
        running = false
        defer { workout = nil; builder = nil; busy = false }
        guard let builder else { return }
        do {
            try await builder.endCollection(at: date)
            _ = try await builder.finishWorkout()
            message = "Walk saved to Apple Health"
        } catch { message = error.localizedDescription }
    }
    private func collect(_ builder: HKLiveWorkoutBuilder, types: Set<HKSampleType>) {
        let hr = HKQuantityType(.heartRate)
        guard types.contains(hr), let stats = builder.statistics(for: hr),
              let quantity = stats.mostRecentQuantity(), let interval = stats.mostRecentQuantityDateInterval() else { return }
        let value = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        heartRate = value
        if WCSession.default.activationState == .activated && WCSession.default.isReachable {
            WCSession.default.sendMessage(["heartRate": value, "timestamp": interval.end.timeIntervalSince1970], replyHandler: nil) { error in
                Task { @MainActor in self.message = "iPhone link: " + error.localizedDescription }
            }
        }
    }
    private func receive(_ context: [String: Any]) {
        if let data = context["forecast"] as? Data,
           let value = try? JSONDecoder().decode(Forecast.self, from: data), !value.points.isEmpty {
            forecast = value
        }
    }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        if toState == .ended { Task { @MainActor in await self.finish(at: date) } }
    }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.builder?.discardWorkout()
            self.workout = nil
            self.builder = nil
            self.running = false
            self.busy = false
            self.message = error.localizedDescription
        }
    }
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        Task { @MainActor in self.collect(workoutBuilder, types: collectedTypes) }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.receive(session.receivedApplicationContext)
            if let error { self.message = error.localizedDescription }
            if session.isReachable { session.sendMessage(["requestForecast": true], replyHandler: nil, errorHandler: nil) }
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        Task { @MainActor in self.receive(applicationContext) }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable { session.sendMessage(["requestForecast": true], replyHandler: nil, errorHandler: nil) }
    }
}
