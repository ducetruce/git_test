import Foundation

/// `DeviceSession` for `GenericBLECoordinator`. Reads Device Information and
/// Battery Level once on connect, subscribes to Heart Rate notifications for
/// the life of the connection, and can push alerts via the Alert
/// Notification Profile (0x1811) if the peripheral supports it.
public final class GenericBLESession: DeviceSession {
    public private(set) var device: Device
    private weak var transport: DeviceTransport?
    private weak var delegate: DeviceSessionDelegate?

    public init(device: Device) {
        self.device = device
    }

    public func start(transport: DeviceTransport, delegate: DeviceSessionDelegate) async throws {
        self.transport = transport
        self.delegate = delegate

        await readDeviceInfoIfAvailable()
        await readBatteryIfAvailable()
        try? subscribeToHeartRateIfAvailable()
    }

    public func stop() {
        try? transport?.unsubscribe(service: StandardBLEService.heartRate, characteristic: StandardBLECharacteristic.heartRateMeasurement)
        transport = nil
        delegate = nil
    }

    public func sendAlert(_ alert: NotificationAlert) async throws {
        guard let transport else { throw DeviceTransportError.notConnected }
        let payload = Self.encodeAlert(alert)
        try await transport.writeValue(
            payload,
            service: StandardBLEService.alertNotification,
            characteristic: StandardBLECharacteristic.newAlert,
            withResponse: false
        )
    }

    public func setTime(_ date: Date) async throws {
        guard let transport else { throw DeviceTransportError.notConnected }
        try await transport.writeValue(
            Self.encodeCurrentTime(date),
            service: StandardBLEService.currentTime,
            characteristic: StandardBLECharacteristic.currentTime,
            withResponse: true
        )
    }

    // MARK: - Private

    private func readDeviceInfoIfAvailable() async {
        guard let transport else { return }
        let manufacturer = try? await transport.readValue(
            service: StandardBLEService.deviceInformation,
            characteristic: StandardBLECharacteristic.manufacturerName
        )
        let model = try? await transport.readValue(
            service: StandardBLEService.deviceInformation,
            characteristic: StandardBLECharacteristic.modelNumber
        )
        let firmware = try? await transport.readValue(
            service: StandardBLEService.deviceInformation,
            characteristic: StandardBLECharacteristic.firmwareRevision
        )

        guard manufacturer != nil || model != nil || firmware != nil else { return }

        device.manufacturer = manufacturer.flatMap { String(data: $0, encoding: .utf8) } ?? device.manufacturer
        device.modelNumber = model.flatMap { String(data: $0, encoding: .utf8) } ?? device.modelNumber
        device.firmwareVersion = firmware.flatMap { String(data: $0, encoding: .utf8) } ?? device.firmwareVersion
        delegate?.session(self, didUpdateDeviceInfo: device)
    }

    private func readBatteryIfAvailable() async {
        guard let transport else { return }
        guard let data = try? await transport.readValue(
            service: StandardBLEService.battery,
            characteristic: StandardBLECharacteristic.batteryLevel
        ), let level = data.first else { return }

        let battery = BatteryInfo(level: Int(level))
        device.battery = battery
        delegate?.session(self, didUpdateBattery: battery)
    }

    private func subscribeToHeartRateIfAvailable() throws {
        guard let transport else { return }
        try transport.subscribe(
            service: StandardBLEService.heartRate,
            characteristic: StandardBLECharacteristic.heartRateMeasurement
        ) { [weak self] data in
            guard let self, let measurement = HeartRateMeasurementParser.parse(data) else { return }
            self.delegate?.session(self, didReceive: measurement)
        }
    }

    /// Encodes a `New Alert` characteristic (0x2A46) value: category ID,
    /// alert count, then a UTF-8 text info string, per the Alert
    /// Notification Profile spec.
    static func encodeAlert(_ alert: NotificationAlert) -> Data {
        let categoryId: UInt8
        switch alert.category {
        case .call: categoryId = 0x01
        case .message: categoryId = 0x03
        case .custom: categoryId = 0x00
        }
        var data = Data([categoryId, 0x01])
        let text = "\(alert.title): \(alert.body)".prefix(18) // ANP messages are short by design
        data.append(contentsOf: Array(text.utf8))
        return data
    }

    /// Encodes the Current Time characteristic (0x2A2B) exact-time payload.
    static func encodeCurrentTime(_ date: Date) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)

        var data = Data()
        let year = UInt16(c.year ?? 1970)
        data.append(UInt8(year & 0xFF))
        data.append(UInt8((year >> 8) & 0xFF))
        data.append(UInt8(c.month ?? 1))
        data.append(UInt8(c.day ?? 1))
        data.append(UInt8(c.hour ?? 0))
        data.append(UInt8(c.minute ?? 0))
        data.append(UInt8(c.second ?? 0))
        // Calendar's weekday is 1=Sunday...7=Saturday; Bluetooth's Day-of-Week is 1=Monday...7=Sunday.
        let calendarWeekday = c.weekday ?? 1
        let bluetoothWeekday = calendarWeekday == 1 ? 7 : calendarWeekday - 1
        data.append(UInt8(bluetoothWeekday))
        data.append(0) // fractions256
        data.append(0) // adjust reason
        return data
    }
}
