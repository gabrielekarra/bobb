/// Collects up to `count` values from `stream`, giving up after
/// `timeoutSeconds` — so a test that expects the daemon side to behave can
/// fail fast instead of hanging forever when it does not.
func collect<T: Sendable>(_ stream: AsyncStream<T>, count: Int, timeoutSeconds: Double = 3.0) async -> [T] {
    await withTaskGroup(of: [T]?.self) { group in
        group.addTask {
            var results: [T] = []
            var iterator = stream.makeAsyncIterator()
            while results.count < count, let value = await iterator.next() {
                results.append(value)
            }
            return results
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? []
    }
}
