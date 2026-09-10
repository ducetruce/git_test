import Foundation

/// Decodes the Bluetooth SIG Heart Rate Measurement characteristic
/// (`0x2A37`) payload per the Heart Rate Profile spec: byte 0 is a flags
/// field; bit 0 selects UINT8 vs UINT16 for the heart rate value that
/// follows.
public enum HeartRateMeasurementParser {
    public static func parseBPM(from data: Data) -> Int? {
        guard let flags = data.first else { return nil }
        let isUInt16Format = (flags & 0x01) != 0
        if isUInt16Format {
            guard data.count >= 3 else { return nil }
            let value = UInt16(data[data.startIndex + 1]) | (UInt16(data[data.startIndex + 2]) << 8)
            return Int(value)
        } else {
            guard data.count >= 2 else { return nil }
            return Int(data[data.startIndex + 1])
        }
    }
}
