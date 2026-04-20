import Foundation

/// Runs a Process on a background thread and suspends the calling async task
/// until it exits. This avoids blocking the Swift cooperative thread pool
/// (which would happen with a bare process.waitUntilExit() inside async code)
/// and ensures the process is never killed prematurely by ARC.
func runProcess(_ process: Process) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        process.terminationHandler = { _ in
            continuation.resume()
        }
        do {
            try process.run()
        } catch {
            continuation.resume(throwing: error)
        }
    }
}
