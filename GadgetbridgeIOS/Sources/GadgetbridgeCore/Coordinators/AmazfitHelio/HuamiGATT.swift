import Foundation

/// GATT identifiers for Huami/Zepp OS devices (Amazfit, and historically Mi
/// Band). Confidence varies by entry — see individual comments. Where
/// uncertain, this deliberately stops short of guessing rather than
/// shipping a plausible-looking but unverified UUID.
enum HuamiGATT {
    /// The Huami primary service. Widely and consistently documented
    /// across independent Mi Band/Amazfit reverse-engineering write-ups —
    /// high confidence.
    static let service: ServiceUUID = "0000fee0-0000-1000-8000-00805f9b34fb"

    /// The authentication characteristic, under `service`. Consistently
    /// documented across multiple independent Mi Band/Amazfit
    /// reverse-engineering sources — reasonably high confidence, but
    /// unverified against an actual Helio Strap capture.
    static let authCharacteristic: ServiceUUID = "00000009-0000-3512-2118-0009af100700"

    /// The base UUID family Huami characteristics follow:
    /// `0000XXXX-0000-3512-2118-0009af100700`. Beyond `authCharacteristic`,
    /// this codebase does not guess further characteristic IDs (e.g. for
    /// the chunked activity-data transfer protocol) — those require a BLE
    /// capture of the real app pairing with a real device to confirm.
    static func characteristic(_ shortId: UInt16) -> ServiceUUID {
        ServiceUUID(String(format: "%08x-0000-3512-2118-0009af100700", shortId))
    }
}
