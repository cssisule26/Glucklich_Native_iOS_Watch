import SwiftUI
import Charts
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var health: HealthStore
    var body: some View {
        TabView {
            NavigationStack { HomeView() }.tabItem { Label("Forecast", systemImage: "waveform.path.ecg") }
            NavigationStack { EvaluationView() }.tabItem { Label("Day 8", systemImage: "chart.xyaxis.line") }
            NavigationStack { ModelView() }.tabItem { Label("My model", systemImage: "person.crop.circle") }
            NavigationStack { SettingsView() }.tabItem { Label("Connect", systemImage: "applewatch") }
        }
        .onChange(of: scenePhase) { _, value in
            if value == .active { Task { await health.refresh() } }
        }
    }
}

struct Panel: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }
}
extension View { func panel() -> some View { modifier(Panel()) } }

struct HomeView: View {
    @EnvironmentObject private var model: AppStore
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var watch: WatchLink
    @State private var entry = false
    @State private var tick = Date()
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    var body: some View {
        let _ = tick // Refresh freshness labels even when no new sensor sample arrives.
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A little insight.\nBefore your first bite.")
                        .font(.system(.largeTitle, design: .rounded).bold())
                    Text("Explore your next two hours with a meal forecast and wearable context.").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 16) {
                    Label("Your signals", systemImage: "heart.text.square").font(.headline)
                    HStack(alignment: .top) {
                        let hr = watch.freshHeartRate ?? health.heartRate
                        signal("Heart rate", value: hr.map { String(Int($0.value)) } ?? "—", unit: "bpm")
                        signal("Glucose", value: health.demoCGM ? "108" : health.glucose.map { String(Int($0.value)) } ?? "—", unit: "mg/dL")
                        signal("Activity", value: health.activityKcal.map { String(Int($0)) } ?? "—", unit: "kcal · prior hour")
                    }
                    let hr = watch.freshHeartRate ?? health.heartRate
                    Text(hr.map { "\($0.source) · \(Int($0.ageMinutes)) min ago" } ?? "Heart rate unavailable. Connect Apple Health or start a Watch walk.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(health.demoCGM ? "Glucose: generated demo value" : health.glucose.map { "Glucose: \($0.source) · \(Int($0.ageMinutes)) min ago" } ?? "No readable CGM glucose")
                        .font(.caption).foregroundStyle(health.demoCGM ? Color.orange : Color.secondary)
                    if let reading = hr, reading.ageMinutes > 15 { Text("Heart rate is stale; it will be omitted from a new forecast.").font(.caption).foregroundStyle(.orange) }
                }.panel()
                Button { entry = true } label: {
                    Label("Log a meal & forecast", systemImage: "camera.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                if let forecast = model.forecast {
                    ForecastCard(forecast: forecast)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Ready for your demo", systemImage: "sparkles").font(.headline)
                        Text("Start with the bundled participant on the Day 8 tab, or log a meal. Import a trained participant JSON on My model when your dataset is ready.")
                            .foregroundStyle(.secondary)
                        Text("Current model: \(model.package.provenance)").font(.caption)
                    }.panel()
                }
                if let message = model.message { Text(message).font(.caption).foregroundStyle(.orange) }
            }.padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Glucklich")
        .toolbar {
            Button { Task { await health.refresh() } } label: { Image(systemName: "arrow.clockwise") }
        }
        .sheet(isPresented: $entry) { NavigationStack { MealView() } }
        .onReceive(timer) { tick = $0 }
        .id("home")
    }
    private func signal(_ title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title, design: .rounded).bold()).monospacedDigit()
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ForecastCard: View {
    let forecast: Forecast
    var observed: [Double] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Predicted peak").font(.caption).foregroundStyle(.secondary)
                    Text("\(Int(forecast.peak.value.rounded()))").font(.system(size: 46, weight: .bold, design: .rounded))
                    Text("mg/dL · at \(forecast.peak.minute) minutes").font(.caption)
                }
                Spacer()
                Text(forecast.syntheticModel ? "DEMO MODEL" : "PARTICIPANT MODEL")
                    .font(.caption2.bold()).padding(9)
                    .background(.teal.opacity(0.12), in: Capsule())
            }
            Text(forecast.input.name).font(.headline)
            Text("Inputs captured at \(forecast.input.timestamp)").font(.caption2).foregroundStyle(.secondary)
            Chart {
                ForEach(forecast.points) { point in
                    AreaMark(x: .value("Minutes", point.minute), yStart: .value("Lower", point.lower), yEnd: .value("Upper", point.upper))
                        .foregroundStyle(.teal.opacity(0.14))
                    LineMark(x: .value("Minutes", point.minute), y: .value("Glucose", point.value), series: .value("Series", "Forecast"))
                        .foregroundStyle(.teal).lineStyle(StrokeStyle(lineWidth: 3))
                }
                ForEach(Array(observed.enumerated()), id: \.offset) { pair in
                    LineMark(x: .value("Minutes", (pair.offset+1)*5), y: .value("Glucose", pair.element), series: .value("Series", "Observed"))
                        .foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth: 2, dash: [5,3]))
                }
                RuleMark(y: .value("Baseline", forecast.points[0].value)).foregroundStyle(.gray.opacity(0.5)).lineStyle(StrokeStyle(dash: [4,4]))
            }
            .frame(height: 230).chartXAxisLabel("Minutes after meal").chartYAxisLabel("mg/dL")
            Text(observed.isEmpty ? "Teal: forecast · shaded: estimated spread" : "Teal: forecast · orange: observed · shaded: estimated spread")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                ForEach([30,60,90,120], id: \.self) { minute in
                    VStack(spacing: 6) {
                        Text("\(minute)m").font(.caption).foregroundStyle(.secondary)
                        Text("\(Int(forecast.points[minute/5].value.rounded()))").font(.headline).monospacedDigit()
                    }.frame(maxWidth: .infinity).padding(.vertical, 12).background(.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            HStack {
                metric("Peak rise", String(format: "%.0f mg/dL", forecast.excursion))
                metric("Positive iAUC", String(format: "%.1f mg·h/dL", forecast.iauc))
            }
            Divider()
            Text("What shaped this forecast?").font(.headline)
            Text("Contributions to the predicted change at its peak, relative to this participant's average inputs. Associations, not proven effects.").font(.caption).foregroundStyle(.secondary)
            ForEach(forecast.drivers.prefix(5)) { driver in
                HStack {
                    Text(driver.name).font(.subheadline)
                    Spacer()
                    Text(String(format: "%+.1f", driver.value)).font(.subheadline.monospacedDigit()).foregroundStyle(driver.value >= 0 ? .orange : .teal)
                }
            }
            Text(String(format: "Reference response: %+.1f mg/dL. Full contributions sum to the forecast change at its post-meal peak.", forecast.referenceDelta)).font(.caption2).foregroundStyle(.secondary)
            ForEach(forecast.warnings, id: \.self) { text in
                Label(text, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            Text("Estimated spread uses Day 7 errors. It is not a calibrated confidence probability. Research prototype; not for treatment or insulin decisions.")
                .font(.caption2).foregroundStyle(.secondary)
        }.panel()
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold())
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EvaluationView: View {
    @EnvironmentObject private var model: AppStore
    @EnvironmentObject private var watch: WatchLink
    @State private var selection = ""
    @State private var forecast: Forecast?
    @State private var revealed = false
    @State private var error: String?
    private var selected: EvaluationCase? { model.package.cases.first { $0.id == selection } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("The meal your model hasn't seen.").font(.system(.title, design: .rounded).bold())
                Text("Fit: Days 1–7. Forecast: Day 8. Predictions use the participant's stored pre-meal context; live Watch signals are reserved for a new meal on the Forecast tab.")
                    .foregroundStyle(.secondary)
                if model.package.cases.isEmpty {
                    Text("No Day 8 cases in this package. Export an eight-day window when available.").panel()
                } else {
                    Picker("Day 8 meal", selection: $selection) {
                        ForEach(model.package.cases) { item in Text(item.input.name).tag(item.id) }
                    }.pickerStyle(.menu)
                    Button("Predict held-out meal") {
                        do {
                            if let item = selected {
                                forecast = try ForecastEngine(package: model.package).predict(item.input)
                                revealed = false
                                error = nil
                                if let forecast { watch.publish(forecast) }
                            }
                        } catch { self.error = error.localizedDescription }
                    }.buttonStyle(.borderedProminent)
                    if let forecast {
                        if let item = selected, !item.observed.isEmpty {
                            Button(revealed ? "Observed response shown" : "Reveal observed response") { revealed = true }
                                .buttonStyle(.bordered).disabled(revealed)
                            if revealed {
                                let mae = zip(forecast.points.dropFirst(), item.observed).reduce(0.0) { $0+abs($1.0.value-$1.1) }/24
                                Text(String(format: "Day 8 trajectory MAE: %.1f mg/dL", mae)).font(.headline)
                            }
                        } else { Text("Observed Day 8 CGM was not available at export. Forecast remains available.").font(.caption) }
                        ForecastCard(forecast: forecast, observed: revealed ? (selected?.observed ?? []) : [])
                    }
                }
                if let error { Text(error).foregroundStyle(.orange) }
            }.padding(20)
        }
        .background(Color(.systemGroupedBackground)).navigationTitle("Day 8 test")
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: model.package.participantID) { _, _ in selection = model.package.cases.first?.id ?? ""; forecast = nil; revealed = false }
        .onChange(of: model.package.trainingEnd) { _, _ in selection = model.package.cases.first?.id ?? ""; forecast = nil; revealed = false }
        .onChange(of: selection) { _, _ in forecast = nil; revealed = false }
    }
    private func selectFirstIfNeeded() {
        if !model.package.cases.contains(where: { $0.id == selection }) { selection = model.package.cases.first?.id ?? "" }
    }
}

struct ModelView: View {
    @EnvironmentObject private var model: AppStore
    @State private var importing = false
    @State private var error: String?
    var body: some View {
        List {
            Section("Participant") {
                LabeledContent("ID", value: model.package.participantID)
                Text(model.package.provenance)
                LabeledContent("Training meals", value: "\(model.package.trainingCount)")
                Text("Training through " + model.package.trainingEnd).font(.caption)
                Text(model.package.synthetic ? "Generated sample data" : "Imported participant data").foregroundStyle(.teal)
            }
            Section("Chronological validation") {
                LabeledContent("Day 7 meals", value: "\(model.package.validationCount)")
                if let mae = model.package.validationMAE { LabeledContent("Model MAE", value: String(format: "%.1f mg/dL", mae)) }
                if let mae = model.package.persistenceMAE { LabeledContent("Constant glucose baseline MAE", value: String(format: "%.1f mg/dL", mae)) }
                Text("Validation fits Days 1–6 and forecasts Day 7. The final model is refit on Days 1–7. Small samples limit interpretation; demo results do not estimate clinical performance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("How it learns") {
                Text("A separate regularized regression predicts each 5-minute change from baseline. Coefficients and missingness indicators are learned for this participant. The exported model runs offline on iPhone.")
                Text("CGMacros ZIP and MetaboNet Parquet are processed on your computer using Pipeline/train.py. Import the resulting participant.json here.").font(.caption)
                Button("Import participant JSON") { importing = true }
                Button("Restore bundled demo") { do { try model.resetDemo() } catch { self.error = error.localizedDescription } }
            }
            Section("Saved forecasts") {
                if model.saved.isEmpty { Text("Your meal forecasts are saved locally.").foregroundStyle(.secondary) }
                ForEach(model.saved.reversed()) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.input.name).bold()
                        Text("\(item.participantID) · \(Int(item.peak.value.rounded())) mg/dL peak").font(.caption)
                        Text(item.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if let error { Section("Import message") { Text(error).foregroundStyle(.orange) } }
        }.navigationTitle("My model")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do { try model.importPackage(result.get()); error = nil } catch { self.error = error.localizedDescription }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var watch: WatchLink
    @EnvironmentObject private var model: AppStore
    @State private var erase = false
    @State private var error: String?
    var body: some View {
        Form {
            Section("Apple Health") {
                Button("Connect Apple Health") { Task { await health.connect() } }
                Button("Refresh readings") { Task { await health.refresh() } }.disabled(!health.authorizationRequested || health.loading)
                Text("Heart rate and active energy come from permitted Apple Health sources. Glucose requires an external CGM that writes to Apple Health.")
                    .font(.caption)
                Toggle("Use demo glucose", isOn: $health.demoCGM)
                Text("Demo glucose is fixed at 108 mg/dL and labeled in every new meal's source. Apple Watch does not supply glucose.").font(.caption).foregroundStyle(.secondary)
                if let message = health.message { Text(message).font(.caption).foregroundStyle(.orange) }
            }
            Section("Apple Watch") {
                Text(watch.status)
                Text("Install Glucklich Watch on your paired Watch. Start a walking session while actually walking. Keep Glucklich open on iPhone for live heart rate. HealthKit activity may arrive later after synchronization.")
                    .font(.caption)
                Text("A forecast is a snapshot at meal time. Later exercise does not automatically rewrite that forecast or prove a causal glucose reduction.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Your data") {
                Text("Health readings, imported model parameters, forecasts and meal photos remain on device. This app has no server, API keys or photo upload. Raw datasets stay on your computer.").font(.caption)
                Button("Delete local models, forecasts & photos", role: .destructive) { erase = true }
            }
            Section("About Glucklich") {
                Text("Rutgers Health Hack · Predict My Glucose Response")
                Text("Research prototype. Estimated uncertainty is uncalibrated. Forecasts are not glucose measurements, treatment advice or insulin recommendations.").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.orange) }
        }.navigationTitle("Connect")
        .confirmationDialog("Delete all saved app data and return to demo?", isPresented: $erase, titleVisibility: .visible) {
            Button("Delete saved data", role: .destructive) { do { try model.erase() } catch { self.error = error.localizedDescription } }
        }
    }
}
