import SwiftUI
import PhotosUI
import UIKit

struct MealView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppStore
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var watch: WatchLink
    @State private var name = "Rice bowl"
    @State private var carbs = 65.0
    @State private var protein = 28.0
    @State private var fat = 18.0
    @State private var fiber = 7.0
    @State private var bolus = ""
    @State private var priorCarbs = ""
    @State private var image: UIImage?
    @State private var photo: PhotosPickerItem?
    @State private var camera = false
    @State private var error: String?
    @State private var submitting = false
    var body: some View {
        Form {
            Section("Your meal") {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 16))
                }
                HStack {
                    Button { camera = true } label: { Label("Take photo", systemImage: "camera") }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    Spacer()
                    PhotosPicker(selection: $photo, matching: .images) { Label("Choose photo", systemImage: "photo") }
                }.buttonStyle(.borderless)
                TextField("Meal name", text: $name)
                Menu("Use a nutrition preset") {
                    Button("Rice bowl") { preset("Rice bowl", 65, 28, 18, 7) }
                    Button("Oats and berries") { preset("Oats and berries", 48, 12, 9, 8) }
                    Button("Pizza") { preset("Pizza", 74, 27, 31, 5) }
                    Button("Chicken salad") { preset("Chicken salad", 24, 42, 20, 10) }
                }
            }
            Section("Nutrition · confirm your portion") {
                number("Carbohydrates", $carbs)
                number("Protein", $protein)
                number("Fat", $fat)
                number("Fiber", $fiber)
                Text("Photos are saved with your meal. This version uses confirmed macros; it does not estimate nutrition from the image. Presets are illustrative and should be edited for your portion.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Optional recorded context") {
                TextField("Bolus already taken in prior 2 h · units", text: $bolus).keyboardType(.decimalPad)
                TextField("Carbs eaten in prior 2 h · grams", text: $priorCarbs).keyboardType(.decimalPad)
                Text("Leave unknown values blank. These are past observations, never suggested doses. This baseline model supports recorded bolus insulin only; it does not model other medication classes.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Model: \(model.package.participantID)").font(.caption)
                if !model.package.synthetic {
                    Text("Live-device inputs should belong to the same person as the imported model. Using another participant's model is a demonstration, not personalization for the wearer.").font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    submitting = true
                    Task {
                        await health.refresh()
                        submit()
                        submitting = false
                    }
                } label: {
                    Label(submitting ? "Reading context…" : "Forecast the next 2 hours", systemImage: "waveform.path.ecg")
                }.disabled(submitting)
            }
            if let error { Section { Text(error).foregroundStyle(.orange) } }
        }
        .navigationTitle("Before you eat").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .sheet(isPresented: $camera) { CameraPicker(image: $image) }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let picked = UIImage(data: data) { image = picked }
            }
        }
    }
    private func number(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: value, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 85)
            Text("g").foregroundStyle(.secondary)
        }
    }
    private func preset(_ title: String, _ c: Double, _ p: Double, _ f: Double, _ fi: Double) {
        name = title; carbs = c; protein = p; fat = f; fiber = fi
    }
    private func optional(_ text: String) throws -> Double? {
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        guard let value = Double(text), value.isFinite, value >= 0 else { throw ForecastError.invalidInput }
        return value
    }
    private func submit() {
        do {
            let baseline: Double
            let trend: Double?
            if health.demoCGM { baseline = 108; trend = 0 }
            else {
                guard let glucose = health.glucose else { throw ForecastError.missingBaseline }
                guard glucose.ageMinutes <= 15 else { throw ForecastError.staleGlucose }
                baseline = glucose.value; trend = health.trend
            }
            let hr = watch.freshHeartRate ?? health.heartRate
            let now = Date()
            let components = Calendar.current.dateComponents([.hour,.minute], from: now)
            let hour = Double(components.hour ?? 12)+Double(components.minute ?? 0)/60
            let values: [Double?] = [carbs,protein,fat,fiber,baseline,trend,hr.flatMap { $0.ageMinutes <= 15 ? $0.value : nil },health.activityKcal,try optional(bolus),sin(hour*2*Double.pi/24),cos(hour*2*Double.pi/24),try optional(priorCarbs)]
            let input = ForecastInput(name: name.isEmpty ? "Meal" : name, timestamp: ISO8601DateFormatter().string(from: now), values: values,
                source: "\(health.demoCGM ? "Demo glucose" : health.glucose?.source ?? "CGM") · \(hr?.source ?? "HR unavailable") · confirmed nutrition")
            let forecast = try model.predict(input, photo: image?.jpegData(compressionQuality: 0.7))
            watch.publish(forecast)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
