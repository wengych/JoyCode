import Foundation

/// Waits for read-only readiness evidence, then executes a single mutation.
/// The caller's final `perform` boundary must still verify its live target.
@MainActor
public enum ReadinessActionGate {
    public enum GateError: Error, Equatable {
        case timedOut
    }

    public static func run<T>(deadline: TimeInterval,
                              now: () -> TimeInterval,
                              wait: () async throws -> Void,
                              validate: () throws -> Void,
                              isReady: () throws -> Bool,
                              perform: () throws -> T) async throws -> T {
        func checkBudgetAndCancellation() throws {
            try Task.checkCancellation()
            guard now() < deadline else { throw GateError.timedOut }
        }

        while true {
            try checkBudgetAndCancellation()
            try validate()
            try checkBudgetAndCancellation()
            let ready = try isReady()
            try checkBudgetAndCancellation()
            if ready {
                // No await or retry after readiness. A thrown mutation may already
                // have reached the target and must be propagated exactly once.
                return try perform()
            }
            try await wait()
        }
    }
}
