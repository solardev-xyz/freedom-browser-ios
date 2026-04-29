import Foundation

/// Per-topic serialization for feed writes (SWIP §"Write serialization").
/// Failures don't poison the queue — a throwing call still releases its
/// slot, matching desktop's `withWriteLock`.
@MainActor
final class SwarmFeedWriteLock {
    /// Generation tag stands in for Task reference identity: `Task` is
    /// a non-Equatable struct, so cleanup can't compare `===`.
    private struct Slot {
        let generation: Int
        let task: Task<Void, Never>
    }

    private var chains: [String: Slot] = [:]
    private var generationCounter: Int = 0

    func withLock<T: Sendable>(
        topicHex: String,
        _ fn: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let previousTask = chains[topicHex]?.task
        generationCounter += 1
        let myGeneration = generationCounter

        // `Result`-wrap the throwing fn so the chain-extension Task
        // can be the uniform `Task<Void, Never>` later callers wait on.
        let task = Task<Result<T, Error>, Never> {
            await previousTask?.value
            do {
                return .success(try await fn())
            } catch {
                return .failure(error)
            }
        }

        let chainExtension = Task<Void, Never> { _ = await task.value }
        chains[topicHex] = Slot(generation: myGeneration, task: chainExtension)

        let result = await task.value
        // Only clear if no one queued behind us — they're awaiting our
        // chainExtension and need it reachable until they finish.
        if chains[topicHex]?.generation == myGeneration {
            chains.removeValue(forKey: topicHex)
        }
        return try result.get()
    }
}
