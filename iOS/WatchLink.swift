import Foundation
import WatchConnectivity
import Combine

@MainActor
final class WatchLink: NSObject, ObservableObject, WCSessionDelegate {
    @Published var liveHeartRate: HealthReading?
    @Published var status = "Watch not connected"
    private var latestForecast: Data?
    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }
    var freshHeartRate: HealthReading? {
        guard let value = liveHeartRate, value.ageMinutes < 0.25 else { return nil }
        return value
    }
    func publish(_ forecast: Forecast) {
        latestForecast = try? JSONEncoder().encode(forecast)
        flush()
    }
    private func flush() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let data = latestForecast else { return }
        do { try WCSession.default.updateApplicationContext(["forecast": data]) }
        catch { status = "Forecast sync: " + error.localizedDescription }
    }
    private func receive(_ message: [String: Any]) {
        if message["requestForecast"] as? Bool == true { flush() }
        if let hr = message["heartRate"] as? Double, let t = message["timestamp"] as? Double,
           hr.isFinite, (25...250).contains(hr), t.isFinite,
           abs(Date().timeIntervalSince1970-t) < 15 {
            liveHeartRate = HealthReading(value: hr, date: Date(timeIntervalSince1970: t), source: "Apple Watch · walking session")
        }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.status = error?.localizedDescription ?? (session.isPaired && session.isWatchAppInstalled ? "Watch paired" : "Install the Watch app on a paired Watch")
            self.flush()
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        Task { @MainActor in self.receive(message) }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.status = session.isReachable ? "Watch reachable" : "Watch offline · last readings retained" }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
