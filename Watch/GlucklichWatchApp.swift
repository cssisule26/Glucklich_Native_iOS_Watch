import SwiftUI

@main
struct GlucklichWatchApp: App {
    @StateObject private var session = WalkingSession()
    var body: some Scene {
        WindowGroup { WatchHome().environmentObject(session).tint(.teal) }
    }
}

struct WatchHome: View {
    @EnvironmentObject private var session: WalkingSession
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Glucklich").font(.headline).foregroundStyle(.teal)
                if let forecast = session.forecast {
                    Text(forecast.input.name).font(.caption)
                    Text("\(Int(forecast.peak.value.rounded()))").font(.system(size: 40, weight: .bold, design: .rounded))
                    Text("Forecast peak · mg/dL").font(.caption2)
                    Text("In \(forecast.peak.minute) min · \(forecast.syntheticModel ? "Demo model" : forecast.participantID)").font(.caption2).foregroundStyle(.secondary)
                    Text(forecast.createdAt, style: .relative).font(.caption2)
                    Text("Forecast at meal time; not current glucose.").font(.caption2)
                } else {
                    Text("Log a meal on iPhone to see its forecast here.").font(.caption)
                }
                Divider()
                if let hr = session.heartRate {
                    Label("\(Int(hr)) bpm", systemImage: "heart.fill").foregroundStyle(.pink)
                }
                Button(session.running ? "End walk" : "Start walking session") {
                    if session.running { session.end() } else { Task { await session.start() } }
                }.buttonStyle(.borderedProminent).disabled(session.busy)
                Text("Walk while this session runs. Live heart rate is sent to the paired iPhone when reachable.").font(.caption2).foregroundStyle(.secondary)
                if let message = session.message { Text(message).font(.caption2) }
            }
        }
    }
}
