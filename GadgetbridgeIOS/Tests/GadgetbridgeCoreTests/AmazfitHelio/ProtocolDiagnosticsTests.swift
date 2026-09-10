import XCTest
@testable import GadgetbridgeCore

private final class CapturingLogger: ProtocolLogging {
    private(set) var lines: [String] = []
    func log(_ message: String) { lines.append(message) }
    var transcript: String { lines.joined(separator: "\n") }
}

/// A transport that replays a canned notification as soon as anything is
/// written, standing in for a device that answers differently than
/// `AmazfitHelioSession`'s guessed constants expect.
private final class ReplayingTransport: DeviceTransport {
    private var onUpdate: ((Data) -> Void)?
    private let reply: [UInt8]
    private(set) var written: [[UInt8]] = []

    init(reply: [UInt8]) { self.reply = reply }

    /// Only the vendor auth characteristic exists here — no standard Heart
    /// Rate service, so the session takes the handshake path rather than
    /// broadcast mode.
    func hasCharacteristic(service: ServiceUUID, characteristic: ServiceUUID) -> Bool {
        characteristic == HuamiGATT.authCharacteristic
    }

    func readValue(service: ServiceUUID, characteristic: ServiceUUID) async throws -> Data {
        throw DeviceTransportError.characteristicNotFound(characteristic)
    }

    func writeValue(_ data: Data, service: ServiceUUID, characteristic: ServiceUUID, withResponse: Bool) async throws {
        written.append([UInt8](data))
        onUpdate?(Data(reply))
    }

    func subscribe(service: ServiceUUID, characteristic: ServiceUUID, onUpdate: @escaping (Data) -> Void) throws {
        guard characteristic == HuamiGATT.authCharacteristic else { return }
        self.onUpdate = onUpdate
    }

    func unsubscribe(service: ServiceUUID, characteristic: ServiceUUID) throws {}
    func disconnect() {}
}

private final class NoopDelegate: DeviceSessionDelegate {
    func session(_ session: DeviceSession, didUpdateBattery battery: BatteryInfo) {}
    func session(_ session: DeviceSession, didReceive measurement: HeartRateMeasurement) {}
    func session(_ session: DeviceSession, didUpdateDeviceInfo device: Device) {}
}

final class ProtocolDiagnosticsTests: XCTestCase {
    func testHexDumpFormatsBytesReadably() {
        let bytes: [UInt8] = [0x04, 0x02, 0x00, 0xFF]
        XCTAssertEqual(bytes.hexDump, "04 02 00 FF")
        XCTAssertEqual(Data([0xAB, 0xCD]).hexDump, "AB CD")
    }

    func testLoggerKeepsMostRecentLinesOnly() {
        let logger = ProtocolLogger(maximumLines: 2, echoesToConsole: false)
        logger.log("first")
        logger.log("second")
        logger.log("third")

        let transcript = logger.transcript
        XCTAssertFalse(transcript.contains("first"))
        XCTAssertTrue(transcript.contains("second"))
        XCTAssertTrue(transcript.contains("third"))
    }

    func testLoggerClearEmptiesTranscript() {
        let logger = ProtocolLogger(echoesToConsole: false)
        logger.log("something")
        logger.clear()
        XCTAssertTrue(logger.transcript.isEmpty)
    }

    /// The scenario this diagnostics work exists for: the device answers,
    /// but not in the shape the guessed echo-byte convention expects. The
    /// handshake must fail with a timeout rather than hanging, and the raw
    /// response must still be in the log so the constants can be corrected.
    func testUnexpectedResponseIsLoggedVerbatimAndSurfacesAsTimeout() async {
        let logger = CapturingLogger()
        // byte[1] == 0x99 rather than the expected 0x04 echo.
        let unexpectedReply: [UInt8] = [0x10, 0x99, 0x01, 0xDE, 0xAD, 0xBE, 0xEF]
        let transport = ReplayingTransport(reply: unexpectedReply)
        let device = Device(name: "Helio", peripheralIdentifier: "id", family: .amazfit)
        let session = AmazfitHelioSession(
            device: device,
            authKey: HuamiAuthKey(hexString: String(repeating: "AB", count: 16)),
            logger: logger,
            responseTimeout: 0.3
        )

        do {
            try await session.start(transport: transport, delegate: NoopDelegate())
            XCTFail("Expected the handshake to time out when the response doesn't match expectations")
        } catch {
            guard let transportError = error as? DeviceTransportError, case .timedOut = transportError else {
                return XCTFail("Expected DeviceTransportError.timedOut, got \(error)")
            }
        }

        XCTAssertTrue(
            logger.transcript.contains("10 99 01 DE AD BE EF"),
            "The device's actual response must appear verbatim in the log, since that's what a fix would be based on"
        )
        XCTAssertTrue(
            logger.transcript.contains("IGNORED"),
            "The log should call out that a response arrived but was discarded by an unverified assumption"
        )
        XCTAssertTrue(logger.transcript.contains("timed out"))
    }

    func testOutgoingHandshakeBytesAreLogged() async {
        let logger = CapturingLogger()
        let transport = ReplayingTransport(reply: [])
        let device = Device(name: "Helio", peripheralIdentifier: "id", family: .amazfit)
        let session = AmazfitHelioSession(
            device: device,
            authKey: HuamiAuthKey(hexString: String(repeating: "AB", count: 16)),
            logger: logger,
            responseTimeout: 0.3
        )

        _ = try? await session.start(transport: transport, delegate: NoopDelegate())

        // 4-byte command prefix + 48-byte public key.
        XCTAssertEqual(transport.written.first?.count, 52)
        XCTAssertTrue(logger.transcript.contains("04 02 00 02"), "The outgoing command prefix should be logged")
        XCTAssertTrue(logger.transcript.contains("writing 52 bytes"))
    }
}
