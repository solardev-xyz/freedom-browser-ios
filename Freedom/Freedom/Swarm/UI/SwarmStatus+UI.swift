import SwarmKit
import SwiftUI

extension SwarmStatus {
    var color: Color {
        switch self {
        case .running: .green
        case .starting, .stopping: .orange
        case .failed: .red
        case .idle, .stopped: .gray
        }
    }
}
