import Foundation
import Observation

/// Stock presets from the bundle plus user engines stored as JSON in the app container.
@Observable
final class EngineLibrary {
    static let presetOrder = ["inline-4", "inline-4-turbo", "v6-90-splitpin", "crossplane-v8",
                              "flatplane-v8", "v10", "v12", "futuristic"]

    private(set) var presets: [EngineDefinition] = []
    private(set) var userEngines: [EngineDefinition] = []
    private(set) var loadErrors: [String] = []

    var all: [EngineDefinition] { presets + userEngines }

    static var userDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Engines", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init(bundle: Bundle = .main) {
        reload(bundle: bundle)
    }

    func reload(bundle: Bundle = .main) {
        var errors: [String] = []
        let urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: "Engines") ?? []
        var loaded: [EngineDefinition] = []
        for url in urls {
            do { loaded.append(try Self.load(url)) } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        presets = loaded.sorted { (Self.presetOrder.firstIndex(of: $0.id) ?? 99) < (Self.presetOrder.firstIndex(of: $1.id) ?? 99) }

        var users: [EngineDefinition] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.userDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            do { users.append(try Self.load(url)) } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        userEngines = users.sorted { $0.name < $1.name }
        loadErrors = errors
    }

    static func load(_ url: URL) throws -> EngineDefinition {
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> EngineDefinition {
        let def = try JSONDecoder().decode(EngineDefinition.self, from: data)
        try def.validate()
        return def
    }

    static func encode(_ def: EngineDefinition) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(def)
    }

    func isPreset(_ id: String) -> Bool { presets.contains { $0.id == id } }

    func engine(id: String) -> EngineDefinition? { all.first { $0.id == id } }

    /// Stock presets are never edited in place: editing duplicates.
    func duplicate(_ def: EngineDefinition) -> EngineDefinition {
        var copy = def
        var n = 1
        let base = def.id.replacingOccurrences(of: #"-custom-\d+$"#, with: "", options: .regularExpression)
        while engine(id: "\(base)-custom-\(n)") != nil { n += 1 }
        copy.id = "\(base)-custom-\(n)"
        copy.name = "\(def.name) (custom \(n))"
        return copy
    }

    func save(_ def: EngineDefinition) throws {
        try def.validate()
        guard !isPreset(def.id) else { throw EngineValidationError(problems: ["Stock presets cannot be overwritten"]) }
        let url = Self.userDirectory.appendingPathComponent("\(def.id).json")
        try Self.encode(def).write(to: url, options: .atomic)
        reload()
    }

    func delete(_ def: EngineDefinition) {
        guard !isPreset(def.id) else { return }
        try? FileManager.default.removeItem(at: Self.userDirectory.appendingPathComponent("\(def.id).json"))
        reload()
    }

    @discardableResult
    func importEngine(from url: URL) throws -> EngineDefinition {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var def = try Self.load(url)
        if isPreset(def.id) || engine(id: def.id) != nil { def = duplicate(def) }
        try save(def)
        return def
    }

    /// Writes the engine to a temporary file for sharing.
    func exportURL(for def: EngineDefinition) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(def.id).json")
        try Self.encode(def).write(to: url, options: .atomic)
        return url
    }
}
