import Foundation

struct Expected: Codable { var points: [Double]; var missingPoints: [Double] }
@main
struct ModelCheck {
    static func main() throws {
        let path = CommandLine.arguments[1]
        let p = try JSONDecoder().decode(ParticipantPackage.self, from: Data(contentsOf: URL(fileURLWithPath: path+"/Resources/demo_participant.json")))
        let expected = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: URL(fileURLWithPath: path+"/Tests/swift_expected.json")))
        try p.validate()
        let engine = ForecastEngine(package:p)
        var input = p.cases[0].input
        let result = try engine.predict(input)
        assert(result.points.count==25)
        for (actual, value) in zip(result.points.dropFirst(),expected.points) { assert(abs(actual.value-value)<1e-8) }
        let index = result.points.dropFirst().enumerated().max(by: { $0.element.value < $1.element.value })!.offset
        let sum = result.drivers.reduce(result.referenceDelta) { $0+$1.value }
        assert(abs(sum-(result.points[index+1].value-result.points[0].value))<1e-8)
        input.values[6] = nil
        input.values[7] = nil
        let missing = try engine.predict(input)
        for (actual,value) in zip(missing.points.dropFirst(),expected.missingPoints) { assert(abs(actual.value-value)<1e-8) }
        input.values[4] = nil
        do { _ = try engine.predict(input); fatalError("Missing glucose should fail") }
        catch ForecastError.missingBaseline {}
        var bad = p
        bad.coefficients[0] = []
        do { try bad.validate(); fatalError("Invalid package should fail") }
        catch ForecastError.invalidPackage {}
        print("Swift/Python parity, driver sums, missing inputs and schema checks passed")
    }
}
