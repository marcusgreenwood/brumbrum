import Foundation

/// Writes one CSV row per control tick (100 Hz) to Documents/Logs, for tuning
/// the estimator and measuring lag against real drives. Runs on the control
/// queue; buffers rows and flushes once a second. Closing happens on deinit.
final class DriveLogger {
    struct Row {
        var time: Double
        var mode: String
        var rawAccel: Double
        var accel: Double
        var bias: Double
        var speed: Double
        var speedStd: Double
        var stationary: Bool
        var gpsSpeed: Double
        var gpsAccuracy: Double
        var gpsNew: Bool
        var gpsInnovation: Double
        var rpm: Double
        var load: Double
        var gear: Int
        var confidence: Double
        var gate: Int
        var blip: Bool
        var latency: Double
        var horizon: Double
    }

    static let header = "t,mode,raw_accel,accel,bias,speed,speed_std,stationary,gps_speed,gps_acc,gps_new,gps_innov,rpm,load,gear,confidence,gate,blip,latency,horizon\n"

    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func allLogs() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files.filter { $0.pathExtension == "csv" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    let url: URL
    private let handle: FileHandle?
    private var buffer = ""
    private var rows = 0

    init() {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        url = Self.directory.appendingPathComponent("drive-\(f.string(from: Date())).csv")
        FileManager.default.createFile(atPath: url.path, contents: Self.header.data(using: .utf8))
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    deinit {
        flush()
        try? handle?.close()
    }

    func write(_ r: Row) {
        buffer += String(format: "%.3f,%@,%.4f,%.4f,%.4f,%.3f,%.3f,%d,%.3f,%.2f,%d,%.3f,%.0f,%.3f,%d,%.2f,%d,%d,%.3f,%.3f\n",
                         r.time, r.mode, r.rawAccel, r.accel, r.bias, r.speed, r.speedStd, r.stationary ? 1 : 0,
                         r.gpsSpeed, r.gpsAccuracy, r.gpsNew ? 1 : 0, r.gpsInnovation, r.rpm, r.load, r.gear,
                         r.confidence, r.gate, r.blip ? 1 : 0, r.latency, r.horizon)
        rows += 1
        if rows % 100 == 0 { flush() }
    }

    private func flush() {
        guard !buffer.isEmpty, let data = buffer.data(using: .utf8) else { return }
        try? handle?.write(contentsOf: data)
        buffer = ""
    }
}
