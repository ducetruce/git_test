// Generated from the sytchi/NarwalIntegration fault table (MIT).
// See THIRD_PARTY_NOTICES.md.

public enum RobotErrorText {
    /// Fault code -> English message, for the codes the community has identified.
    public static let messages: [Int: String] = [
        0x01010013: "Base station overflowed",
        0x01010032: "Cleaning tray not in place",
        0x01010034: "Clean water tank not in place",
        0x01010035: "Clean water tank error",
        0x01010036: "Dirty water tank full or not in place",
        0x01010051: "Water exchange module: clean water tank error",
        0x01010052: "Water exchange module error",
        0x01010053: "Base station overflowed",
        0x01010059: "Water exchange module not installed",
        0x01010060: "Water control module not detected",
        0x01010061: "Water spray system error",
        0x01010063: "Dirty water outlet pipe error",
        0x01010137: "Clean water tank empty",
        0x02020011: "Roller brush lifting error",
        0x02020013: "Mop lifting error",
        0x02020015: "Mopping module motor overcurrent",
        0x02020028: "Side brush error",
        0x02020030: "Side brush error",
        0x02020031: "Roller brush entangled",
        0x02020032: "Dust bin not in place",
        0x02020040: "Mopping module error",
        0x02020050: "Mopping module error",
        0x02020060: "Mopping module error",
        0x02030040: "Battery temperature too high",
        0x02030041: "Battery temperature too low",
        0x02030050: "Charging pads error",
        0x02030051: "Charging error",
        0x02100015: "Failed to return to the base station",
        0x02100017: "Cannot find the base station",
        0x02100018: "Cannot find the base station",
        0x02100019: "Repositioning failed",
        0x02100021: "Robot is trapped",
        0x02100051: "Failed to exit the base station",
        0x02100070: "Failed to exit the base station",
        0x02110020: "Failed to connect to the base station",
        0x02110030: "Mop washing interrupted",
        0x02110040: "Mop drying interrupted",
        0x02110096: "Motor cooling down, cannot start a task",
        0x02130020: "Entered a no-go zone",
        0x02310025: "Drive wheel malfunction",
        0x02310026: "Rear left drive wheel stuck",
        0x02310027: "Rear right drive wheel stuck",
        0x02310031: "Robot lifted off the floor",
        0x02310034: "Rear left drive wheel overcurrent, restart required",
        0x02310100: "LiDAR speed error",
        0x02310101: "LiDAR cover error",
        0x02310110: "IMU sensor error",
        0x02310118: "Front infrared sensor error",
        0x02310120: "Front ground sensor error",
        0x02310128: "Cliff sensor error",
        0x02310130: "Wall sensor (PSD) error",
        0x02310138: "Floor ultrasonic sensor error",
        0x02310140: "Bumper malfunction",
    ]

    public static func message(for code: Int) -> String {
        messages[code] ?? "Robot fault"
    }

    /// "0x02020031", the form Narwal support uses.
    public static func hexCode(_ code: Int) -> String {
        let digits = String(code, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, 8 - digits.count)) + digits
    }

    /// What to do about a fault, from the kind of part it names.
    public static func advice(for code: Int) -> String? {
        guard let text = messages[code]?.lowercased() else { return nil }
        let rules: [(keys: [String], advice: String)] = [
            (["roller brush", "side brush"], "Turn the robot over and clear hair or debris from the brush, then resume."),
            (["dirty water"], "Empty the dirty water tank and seat it firmly."),
            (["clean water"], "Fill the clean water tank and seat it firmly."),
            (["dust bin", "dust bag"], "Empty the dust bin and check it clicks into place."),
            (["tray"], "Reseat the cleaning tray in the station."),
            (["overflowed"], "Empty the dirty water tank and wipe out the station's tray."),
            (["base station", "dock"], "Check nothing blocks the station and it has power, then send the robot back to the dock."),
            (["trapped"], "Move the robot to open floor, then resume."),
            (["lifted"], "Put the robot back on the floor."),
            (["no-go"], "Move the robot out of the no-go zone, then resume."),
            (["wheel"], "Check the wheels for hair or debris. Restart the robot if it keeps happening."),
            (["cooling"], "Wait a few minutes, then try again."),
            (["sensor", "lidar", "bumper", "imu"], "Wipe the sensors and LiDAR cover with a dry cloth. Restart the robot if it keeps happening."),
            (["mop"], "Check the mops are attached and the station has water."),
            (["repositioning"], "Move the robot near the dock or a familiar spot, then resume."),
        ]
        return rules.first { rule in rule.keys.contains { text.contains($0) } }?.advice
    }

    /// The robot's own note is mostly Chinese debug text; keep only its
    /// English cause line ("原因:robot roll brush is over current…").
    public static func reason(fromDetail detail: String) -> String? {
        for line in detail.split(whereSeparator: \.isNewline) {
            guard let marker = line.range(of: "原因:") ?? line.range(of: "原因：") else { continue }
            let text = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
            return text.prefix(1).uppercased() + text.dropFirst()
        }
        return nil
    }
}
