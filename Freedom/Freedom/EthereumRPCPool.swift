import Foundation

@MainActor
final class EthereumRPCPool {
    func availableProviders() -> [URL] { [] }
    func markSuccess(_ url: URL) {}
    func markFailure(_ url: URL) {}
    func invalidate() {}
}
