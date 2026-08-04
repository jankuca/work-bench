import Foundation

/// Where the GitHub credential comes from.
///
/// IMPLEMENTATION_PLAN §3 puts a fine-grained personal access token behind this seam so
/// that swapping in Device Flow later is a new conformance rather than a change to the
/// sync layer. Nothing above this protocol knows whether the string came from the
/// Keychain, the environment, or a test.
public protocol TokenProvider {
    /// Throws ``GitHubError/missingToken`` when nothing is configured — that is the
    /// first-run state, and the panel shows the connect prompt for it rather than an error.
    func token() throws -> String
}

/// A token held in memory. The dump tool uses this for `--token`; tests use it for
/// everything.
public struct StaticTokenProvider: TokenProvider {
    private let value: String

    public init(_ value: String) {
        self.value = value
    }

    public func token() throws -> String {
        // Tokens are pasted, and a paste routinely carries a trailing newline. Trimming
        // here rather than at every call site is what stops that becoming a 401 the user
        // cannot see the cause of.
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitHubError.missingToken }
        return trimmed
    }
}

/// A token read from the environment.
///
/// This is the credential path for the command-line dump and for CI; the app itself uses
/// the Keychain (``KeychainTokenStore``). Kept portable so the dump runs on Linux.
public struct EnvironmentTokenProvider: TokenProvider {
    public static let defaultNames = ["PRSTACK_GITHUB_TOKEN", "GITHUB_TOKEN"]

    public let names: [String]
    private let environment: [String: String]

    public init(names: [String] = EnvironmentTokenProvider.defaultNames,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.names = names
        self.environment = environment
    }

    public func token() throws -> String {
        for name in names {
            guard let raw = environment[name] else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        throw GitHubError.missingToken
    }
}

/// Tries each provider in turn and returns the first token found.
///
/// Used to express "the Keychain, or the environment if the Keychain has nothing" without
/// either provider knowing about the other.
public struct FirstAvailableTokenProvider: TokenProvider {
    private let providers: [any TokenProvider]

    public init(_ providers: [any TokenProvider]) {
        self.providers = providers
    }

    public func token() throws -> String {
        var lastError: (any Error)?
        for provider in providers {
            do {
                return try provider.token()
            } catch GitHubError.missingToken {
                continue
            } catch {
                // A Keychain that is present but refuses to answer is a real failure and
                // must not be masked by a later provider that happens to have nothing.
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw GitHubError.missingToken
    }
}
