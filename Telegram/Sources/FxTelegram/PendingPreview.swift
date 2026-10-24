import Foundation

private enum PendingPreviewEvent<Value> {
    case fetched(Result<Value, Error>)
    case delayElapsed
}

/// Returns provider failures as a result so the caller can also clean up a confirmed placeholder.
func fetchWithPendingPreview<Value>(
    api: BotAPI,
    parameters: [String: Any],
    originalMessageID: Int64,
    delayNanoseconds: UInt64,
    fetch: @escaping () async throws -> Value
) async throws -> (Result<Value, Error>, Int64?) {
    try await withThrowingTaskGroup(of: PendingPreviewEvent<Value>.self) { group in
        defer { group.cancelAll() }
        group.addTask {
            do { return .fetched(.success(try await fetch())) }
            catch { return .fetched(.failure(error)) }
        }
        group.addTask {
            try await Task.sleep(nanoseconds: delayNanoseconds)
            return .delayElapsed
        }

        guard let first = try await group.next() else { throw BotError.invalidResponse }
        if case .fetched(let result) = first { return (result, nil) }

        try Task.checkCancellation()
        let pendingMessageID: Int64?
        do {
            let response = try await api.call("sendMessage", parameters)
            guard let message = response as? [String: Any],
                  let id = confirmedMessageID(message["message_id"]),
                  id != originalMessageID else { throw BotError.invalidResponse }
            pendingMessageID = id
        } catch BotError.telegram(let code) where code == 400 || code == 403 {
            pendingMessageID = nil
        }

        guard case .fetched(let result)? = try await group.next() else {
            throw BotError.invalidResponse
        }
        return (result, pendingMessageID)
    }
}
