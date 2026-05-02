import IPFSKit
import SwiftUI

extension IPFSStatus {
    var color: Color {
        switch self {
        case .running: .green
        case .starting, .stopping: .orange
        case .failed: .red
        case .idle, .stopped: .gray
        }
    }
}
