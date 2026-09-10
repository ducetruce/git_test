import Foundation

/// Everything the Bluetooth SIG Heart Rate Measurement characteristic
/// (`0x2A37`) can carry — not just the pulse rate.
///
/// The optional fields matter more than they look: `rrIntervals` are the
/// beat-to-beat timings that heart-rate variability is computed from, and
/// they're the only clinically interesting signal a plain standard-GATT
/// chest strap emits. Most apps parse byte 1 and throw the rest away.
public struct HeartRateMeasurement: Hashable, Sendable {
    public enum SensorContact: Sendable, Hashable {
        /// The sensor doesn't report contact state at all.
        case notSupported
        case notDetected
        case detected
    }

    public var beatsPerMinute: Int
    public var sensorContact: SensorContact
    /// Cumulative kilojoules since the sensor was reset, when reported.
    public var energyExpendedKilojoules: Int?
    /// Beat-to-beat intervals in seconds, oldest first. A single
    /// notification can carry several.
    public var rrIntervals: [Double]

    public init(
        beatsPerMinute: Int,
        sensorContact: SensorContact = .notSupported,
        energyExpendedKilojoules: Int? = nil,
        rrIntervals: [Double] = []
    ) {
        self.beatsPerMinute = beatsPerMinute
        self.sensorContact = sensorContact
        self.energyExpendedKilojoules = energyExpendedKilojoules
        self.rrIntervals = rrIntervals
    }

    /// One line for the protocol log describing what this sensor is
    /// actually sending — in particular whether the beat-to-beat intervals
    /// HRV depends on are present, which varies by device and by mode and
    /// is otherwise invisible.
    public var diagnosticSummary: String {
        var parts = ["\(beatsPerMinute) bpm"]

        switch sensorContact {
        case .detected: parts.append("skin contact ok")
        case .notDetected: parts.append("NO SKIN CONTACT — readings unreliable")
        case .notSupported: break
        }

        if let energyExpendedKilojoules {
            parts.append("\(energyExpendedKilojoules) kJ")
        }

        if rrIntervals.isEmpty {
            parts.append("no RR intervals — HRV unavailable from this sensor")
        } else {
            parts.append("\(rrIntervals.count) RR interval(s) — HRV available")
        }

        return parts.joined(separator: " · ")
    }
}

/// Decodes `0x2A37` per the Heart Rate Service spec. Byte 0 is a flags
/// field:
///
/// - bit 0: heart rate value format (0 = UINT8, 1 = UINT16)
/// - bits 1-2: sensor contact status (supported bit, then detected bit)
/// - bit 3: energy expended field present
/// - bit 4: RR-interval field(s) present
public enum HeartRateMeasurementParser {
    public static func parse(_ data: Data) -> HeartRateMeasurement? {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return nil }

        var cursor = 1

        let isUInt16Format = (flags & 0x01) != 0
        let beatsPerMinute: Int
        if isUInt16Format {
            guard bytes.count >= cursor + 2 else { return nil }
            beatsPerMinute = Int(UInt16(bytes[cursor]) | (UInt16(bytes[cursor + 1]) << 8))
            cursor += 2
        } else {
            guard bytes.count >= cursor + 1 else { return nil }
            beatsPerMinute = Int(bytes[cursor])
            cursor += 1
        }

        let contactSupported = (flags & 0x04) != 0
        let contactDetected = (flags & 0x02) != 0
        let sensorContact: HeartRateMeasurement.SensorContact = contactSupported
            ? (contactDetected ? .detected : .notDetected)
            : .notSupported

        var energy: Int?
        if (flags & 0x08) != 0, bytes.count >= cursor + 2 {
            energy = Int(UInt16(bytes[cursor]) | (UInt16(bytes[cursor + 1]) << 8))
            cursor += 2
        }

        var rrIntervals: [Double] = []
        if (flags & 0x10) != 0 {
            // RR intervals are UINT16s in units of 1/1024 second, repeated
            // until the payload runs out.
            while bytes.count >= cursor + 2 {
                let raw = UInt16(bytes[cursor]) | (UInt16(bytes[cursor + 1]) << 8)
                rrIntervals.append(Double(raw) / 1024.0)
                cursor += 2
            }
        }

        return HeartRateMeasurement(
            beatsPerMinute: beatsPerMinute,
            sensorContact: sensorContact,
            energyExpendedKilojoules: energy,
            rrIntervals: rrIntervals
        )
    }

    public static func parseBPM(from data: Data) -> Int? {
        parse(data)?.beatsPerMinute
    }
}
