import Foundation

struct RulesSummary: Codable, Equatable {
    let rules: [RuleItem]
}

struct RuleItem: Codable, Equatable {
    let type: String?
    let payload: String?
    let proxy: String?
}
