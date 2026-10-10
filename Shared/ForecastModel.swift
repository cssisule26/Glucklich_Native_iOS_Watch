import Foundation

// Portable numerical inference. Also compiled by scripts/check_on_mac.sh.
struct ForecastInput: Codable, Equatable {
    var name: String
    var timestamp: String
    var values: [Double?]
    var source: String
}

struct EvaluationCase: Codable, Identifiable {
    var id: String
    var input: ForecastInput
    var observed: [Double]
    var photoPath: String?
}

struct ParticipantPackage: Codable {
    var schemaVersion: Int
    var participantID: String
    var provenance: String
    var synthetic: Bool
    var trainingEnd: String
    var trainingCount: Int
    var featureNames: [String]
    var imputation: [Double]
    var means: [Double]
    var scales: [Double]
    var coefficients: [[Double]]
    var intercepts: [Double]
    var widths: [Double]
    var minimums: [Double]
    var maximums: [Double]
    var validationCount: Int
    var validationMAE: Double?
    var persistenceMAE: Double?
    var cases: [EvaluationCase]

    static let expectedFeatures = ["Carbohydrates", "Protein", "Fat", "Fiber", "Baseline glucose", "Pre-meal trend", "Heart rate", "Activity kcal in prior hour", "Bolus units in prior 2 hours", "Hour sine", "Hour cosine", "Carbs in prior 2 hours"]

    func validate() throws {
        let p = Self.expectedFeatures.count
        guard schemaVersion == 1, featureNames == Self.expectedFeatures,
              trainingCount >= 8, !participantID.isEmpty,
              imputation.count == p, minimums.count == p, maximums.count == p,
              means.count == 2*p, scales.count == 2*p,
              coefficients.count == 24, coefficients.allSatisfy({ $0.count == 2*p }),
              intercepts.count == 24, widths.count == 24,
              scales.allSatisfy({ $0.isFinite && $0 > 0 }),
              widths.allSatisfy({ $0.isFinite && $0 >= 0 }),
              (imputation + means + intercepts + minimums + maximums + coefficients.flatMap { $0 }).allSatisfy(\.isFinite),
              zip(minimums, maximums).allSatisfy({ $0.0 <= $0.1 }),
              cases.allSatisfy({ $0.input.values.count == p && ($0.observed.isEmpty || $0.observed.count == 24) && $0.observed.allSatisfy(\.isFinite) && $0.input.values.compactMap { $0 }.allSatisfy(\.isFinite) && $0.input.values[4] != nil }),
              Set(cases.map(\.id)).count == cases.count else {
            throw ForecastError.invalidPackage
        }
    }
}

enum ForecastError: LocalizedError {
    case invalidPackage, missingBaseline, invalidInput, staleGlucose
    var errorDescription: String? {
        switch self {
        case .invalidPackage: return "Unsupported or invalid participant JSON. Export a schema v1 package with the included pipeline."
        case .missingBaseline: return "A current glucose reading is needed. Enable demo CGM or connect a CGM source in Apple Health."
        case .invalidInput: return "Review the meal values. Inputs must be finite and nutrition cannot be negative."
        case .staleGlucose: return "The latest CGM reading is over 15 minutes old. Refresh it before forecasting."
        }
    }
}

struct ForecastPoint: Codable, Identifiable {
    var minute: Int
    var value: Double
    var lower: Double
    var upper: Double
    var id: Int { minute }
}

struct Driver: Codable, Identifiable {
    var name: String
    var value: Double
    var id: String { name }
}

struct Forecast: Codable, Identifiable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var input: ForecastInput
    var points: [ForecastPoint]
    var drivers: [Driver]
    var referenceDelta: Double
    var warnings: [String]
    var participantID: String
    var syntheticModel: Bool
    var peak: ForecastPoint { points.max(by: { $0.value < $1.value })! }
    var excursion: Double { peak.value - points[0].value }
    var iauc: Double {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + (max(0, pair.0.value-points[0].value) + max(0, pair.1.value-points[0].value)) * Double(pair.1.minute-pair.0.minute) / 120
        }
    }
}

struct ForecastEngine {
    let package: ParticipantPackage

    func predict(_ input: ForecastInput) throws -> Forecast {
        try package.validate()
        guard input.values.count == 12,
              input.values.compactMap({ $0 }).allSatisfy(\.isFinite),
              input.values.prefix(4).compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else { throw ForecastError.invalidInput }
        guard let baseline = input.values[4], baseline > 0 else { throw ForecastError.missingBaseline }
        var x = input.values.enumerated().map { $0.element ?? package.imputation[$0.offset] }
        x += input.values.map { $0 == nil ? 1 : 0 }
        let z = x.indices.map { (x[$0] - package.means[$0]) / package.scales[$0] }
        let outside = input.values.indices.filter { i in
            guard let value = input.values[i] else { return false }
            return value < package.minimums[i] - 1e-8 || value > package.maximums[i] + 1e-8
        }
        var warnings: [String] = []
        if package.synthetic { warnings.append("Model trained on generated demo data; performance does not establish real-world accuracy.") }
        if !outside.isEmpty { warnings.append("Outside training range: " + outside.map { package.featureNames[$0] }.joined(separator: ", ")) }
        if input.values.contains(where: { $0 == nil }) { warnings.append("Unavailable inputs use training medians with missingness indicators.") }
        if package.validationCount < 10 { warnings.append("Too few validation meals to establish interval coverage.") }
        let inflation = outside.isEmpty ? 1.0 : 1.5
        var points = [ForecastPoint(minute: 0, value: baseline, lower: baseline, upper: baseline)]
        for i in 0..<24 {
            let delta = zip(package.coefficients[i], z).reduce(package.intercepts[i]) { $0 + $1.0*$1.1 }
            let value = baseline + delta
            let width = package.widths[i] * inflation
            points.append(ForecastPoint(minute: (i+1)*5, value: value, lower: value-width, upper: value+width))
        }
        guard points.allSatisfy({ $0.value.isFinite && $0.lower.isFinite && $0.upper.isFinite }) else { throw ForecastError.invalidInput }
        if points.contains(where: { $0.value < 40 || $0.value > 400 }) { warnings.append("Forecast exceeds the model's supported display range; treat this result as unreliable.") }
        let peakIndex = max(0, points.dropFirst().enumerated().max(by: { $0.element.value < $1.element.value })?.offset ?? 0)
        let drivers = (0..<12).map { i in
            Driver(name: package.featureNames[i], value: package.coefficients[peakIndex][i]*z[i] + package.coefficients[peakIndex][i+12]*z[i+12])
        }.sorted { abs($0.value) > abs($1.value) }
        return Forecast(input: input, points: points, drivers: drivers,
                        referenceDelta: package.intercepts[peakIndex], warnings: warnings,
                        participantID: package.participantID, syntheticModel: package.synthetic)
    }
}
