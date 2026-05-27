import Foundation

public enum TabStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case waiting
    case error
}
