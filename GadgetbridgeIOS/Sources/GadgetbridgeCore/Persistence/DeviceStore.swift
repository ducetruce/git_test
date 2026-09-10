import Foundation

/// Persists the user's paired `Device` list across app launches.
public protocol DeviceStore: AnyObject {
    func loadDevices() throws -> [Device]
    func saveDevices(_ devices: [Device]) throws
}

public final class JSONFileDeviceStore: DeviceStore {
    private let fileURL: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("devices.json")
    }

    public func loadDevices() throws -> [Device] {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else { return [] }
        return try decoder.decode([Device].self, from: data)
    }

    public func saveDevices(_ devices: [Device]) throws {
        let data = try encoder.encode(devices)
        try data.write(to: fileURL, options: .atomic)
    }
}
