import Foundation
import Combine

@MainActor
final class AppStore: ObservableObject {
    @Published var package: ParticipantPackage
    @Published var forecast: Forecast?
    @Published var saved: [Forecast] = []
    @Published var message: String?
    private let directory: URL
    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Glucklich", isDirectory: true)
        // Bundled package is generated and validated as part of packaging.
        let demoURL = Bundle.main.url(forResource: "demo_participant", withExtension: "json")!
        package = try! JSONDecoder().decode(ParticipantPackage.self, from: Data(contentsOf: demoURL))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("participant.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let imported = try JSONDecoder().decode(ParticipantPackage.self, from: Data(contentsOf: url))
                try imported.validate()
                package = imported
            }
            let log = directory.appendingPathComponent("forecasts.json")
            if FileManager.default.fileExists(atPath: log.path) {
                saved = try JSONDecoder().decode([Forecast].self, from: Data(contentsOf: log))
            }
            forecast = saved.last
        } catch { message = "Could not restore saved data: " + error.localizedDescription }
    }

    func predict(_ input: ForecastInput, photo: Data? = nil) throws -> Forecast {
        let result = try ForecastEngine(package: package).predict(input)
        var updated = saved
        updated.append(result)
        updated = Array(updated.suffix(100))
        if let photo {
            try photo.write(to: directory.appendingPathComponent(result.id.uuidString+".jpg"), options: [.atomic,.completeFileProtection])
        }
        try JSONEncoder().encode(updated).write(to: directory.appendingPathComponent("forecasts.json"), options: [.atomic,.completeFileProtection])
        saved = updated
        forecast = result
        return result
    }

    func importPackage(_ url: URL) throws {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size < 10_000_000 else { throw ForecastError.invalidPackage }
        let data = try Data(contentsOf: url)
        let next = try JSONDecoder().decode(ParticipantPackage.self, from: data)
        try next.validate()
        try data.write(to: directory.appendingPathComponent("participant.json"), options: [.atomic,.completeFileProtection])
        package = next
        forecast = nil
    }
    func resetDemo() throws {
        let url = Bundle.main.url(forResource: "demo_participant", withExtension: "json")!
        try importPackage(url)
    }
    func erase() throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: url)
        }
        saved = []
        forecast = nil
        let url = Bundle.main.url(forResource: "demo_participant", withExtension: "json")!
        package = try JSONDecoder().decode(ParticipantPackage.self, from: Data(contentsOf: url))
    }
}
