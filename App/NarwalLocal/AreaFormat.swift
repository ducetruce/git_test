import Foundation

/// Areas in the owner's units: square feet where the phone uses US units,
/// unless Settings > Units says otherwise.
enum AreaFormat {
    static let unitKey = "areaUnit"

    enum Unit: String, CaseIterable, Identifiable {
        case automatic, squareFeet, squareMeters
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: return "Automatic"
            case .squareFeet: return "Square feet"
            case .squareMeters: return "Square meters"
            }
        }
    }

    static func string(squareMeters: Double) -> String {
        let chosen = Unit(rawValue: UserDefaults.standard.string(forKey: unitKey) ?? "") ?? .automatic
        let feet: Bool
        switch chosen {
        case .squareFeet: feet = true
        case .squareMeters: feet = false
        case .automatic: feet = Locale.current.measurementSystem == .us
        }
        if feet {
            let value = Measurement(value: squareMeters, unit: UnitArea.squareMeters).converted(to: .squareFeet).value
            return "\(Int(value.rounded())) sq ft"
        }
        return String(format: "%.1f m²", squareMeters)
    }
}
