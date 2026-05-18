import Foundation

struct SharedCredentialCoordinationKey: Hashable, Sendable {
    let transport: ResponsesTransportKind
    let descriptor: String
}

actor SharedCredentialCoordinator {
    static let shared = SharedCredentialCoordinator()

    private struct Entry {
        var activeSends: Int = 0
        var refreshPending: Bool = false
        var refreshTask: Task<ResolvedResponsesAuth, Error>?
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private var entries: [SharedCredentialCoordinationKey: Entry] = [:]

    func beginSend(for key: SharedCredentialCoordinationKey) async {
        while true {
            var entry = entries[key] ?? Entry()
            if !entry.refreshPending, entry.refreshTask == nil {
                entry.activeSends += 1
                entries[key] = entry
                return
            }
            await suspend(for: key, entry: entry)
        }
    }

    func endSend(for key: SharedCredentialCoordinationKey) {
        guard var entry = entries[key] else { return }
        entry.activeSends = max(0, entry.activeSends - 1)
        entries[key] = entry
        resumeAllWaiters(for: key)
        cleanupIfIdle(for: key)
    }

    func refresh(
        for key: SharedCredentialCoordinationKey,
        operation: @Sendable @escaping () async throws -> ResolvedResponsesAuth
    ) async throws -> ResolvedResponsesAuth {
        while true {
            var entry = entries[key] ?? Entry()
            if let task = entry.refreshTask {
                return try await task.value
            }
            if !entry.refreshPending {
                entry.refreshPending = true
                entries[key] = entry
            }
            if entry.activeSends > 0 {
                await suspend(for: key, entry: entry)
                continue
            }

            entry = entries[key] ?? Entry()
            if let task = entry.refreshTask {
                return try await task.value
            }

            let task = Task<ResolvedResponsesAuth, Error> {
                try await operation()
            }
            entry.refreshPending = true
            entry.refreshTask = task
            entries[key] = entry

            do {
                let resolved = try await task.value
                completeRefresh(for: key)
                return resolved
            } catch {
                completeRefresh(for: key)
                throw error
            }
        }
    }

    private func completeRefresh(for key: SharedCredentialCoordinationKey) {
        guard var entry = entries[key] else { return }
        entry.refreshPending = false
        entry.refreshTask = nil
        entries[key] = entry
        resumeAllWaiters(for: key)
        cleanupIfIdle(for: key)
    }

    private func suspend(for key: SharedCredentialCoordinationKey, entry: Entry) async {
        await withCheckedContinuation { continuation in
            var next = entries[key] ?? entry
            next.waiters.append(continuation)
            entries[key] = next
        }
    }

    private func resumeAllWaiters(for key: SharedCredentialCoordinationKey) {
        guard var entry = entries[key] else { return }
        let waiters = entry.waiters
        entry.waiters.removeAll(keepingCapacity: false)
        entries[key] = entry
        waiters.forEach { $0.resume() }
    }

    private func cleanupIfIdle(for key: SharedCredentialCoordinationKey) {
        guard let entry = entries[key] else { return }
        guard entry.activeSends == 0,
              entry.refreshPending == false,
              entry.refreshTask == nil,
              entry.waiters.isEmpty
        else {
            return
        }
        entries.removeValue(forKey: key)
    }
}
