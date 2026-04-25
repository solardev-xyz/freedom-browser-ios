import Foundation

/// Cosmetic — eligibility for the auto-approve toggle gates on
/// "non-zero selector", not on membership here. Unknown selectors fall
/// back to "calls to this contract" copy.
enum ERC20Selectors {
    static let labels: [String: String] = [
        "0xa9059cbb": "token transfers",
        "0x23b872dd": "token transfers",
        "0x095ea7b3": "token approvals",
    ]

    static func label(for selector: String) -> String? {
        labels[selector.lowercased()]
    }
}
