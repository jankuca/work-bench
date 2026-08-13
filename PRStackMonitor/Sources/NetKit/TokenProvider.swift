import Foundation

/// Nothing is configured for this service.
///
/// This is the first-run state rather than a failure to authenticate, and the two are
/// handled differently everywhere above: no credential shows the connect prompt, a
/// rejected one shows the reconnect banner. Each service kit translates this into its own
/// error (`GitHubError.missingToken`, `LinearError.missingKey`) at the one place it reads
/// a credential.
public struct MissingCredential: Error, Equatable, CustomStringConvertible {
    /// What the credential was for — `github`, `linear`. Free-form: the providers below
    /// serve any service, and only the message ever reads it.
    public var service: String

    public init(service: String = "") {
        self.service = service
    }

    public var description: String {
        service.isEmpty ? "no credential configured" : "no \(service) credential configured"
    }
}

extension MissingCredential: LocalizedError {
    public var errorDescription: String? { description }
}

/// Where a service's credential comes from.
///
/// IMPLEMENTATION_PLAN §3 puts a pasted personal access token behind this seam so that
/// swapping in Device Flow later is a new conformance rather than a change to the sync
/// layer. Nothing above this protocol knows whether the string came from the Keychain, the
/// environment, or a test.
public protocol TokenProvider {
    /// Throws ``MissingCredential`` when nothing is configured.
    func token() throws -> String
}

extension TokenProvider {
    /// Whether this provider has anything to offer, without the caller having to care what
    /// went wrong if it does not.
    ///
    /// The question the connect prompt asks: a source with no credential is offered a
    /// `Connect` button, and one that has a credential the server rejected is not — that is
    /// the reconnect banner's job. A provider that throws for any other reason counts as
    /// having nothing, which is the same answer the poll would come to.
    public var hasCredential: Bool {
        (try? token()) != nil
    }
}

/// A token held in memory. The dump tool uses this for `--token`; tests use it for
/// everything.
public struct StaticTokenProvider: TokenProvider {
    private let value: String
    private let service: String

    public init(_ value: String, service: String = "") {
        self.value = value
        self.service = service
    }

    public func token() throws -> String {
        // Tokens are pasted, and a paste routinely carries a trailing newline. Trimming
        // here rather than at every call site is what stops that becoming a 401 the user
        // cannot see the cause of.
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MissingCredential(service: service) }
        return trimmed
    }
}

/// A token read from the environment.
///
/// This is the credential path for the command-line dump and for CI; the app itself uses
/// the Keychain (``KeychainTokenStore``). Kept portable so the dump runs on Linux.
///
/// The variable names are the caller's to supply — each service kit publishes its own set
/// as a factory (`EnvironmentTokenProvider.github()`, `.linear()`) so the spelling lives
/// next to the API that needs it rather than in a list here that grows a case per source.
public struct EnvironmentTokenProvider: TokenProvider {
    public let names: [String]
    private let service: String
    private let environment: [String: String]

    public init(
        names: [String],
        service: String = "",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.names = names
        self.service = service
        self.environment = environment
    }

    public func token() throws -> String {
        for name in names {
            guard let raw = environment[name] else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        throw MissingCredential(service: service)
    }
}

/// Which Keychain item a credential lives in — one per integration, so revoking Linear
/// cannot disturb GitHub.
///
/// Declared here rather than inside ``KeychainTokenStore`` because that type is fenced
/// behind `canImport(Security)`, and ``CredentialChain`` has to be able to name an account
/// on Linux, where there is no Keychain to read it from.
public enum KeychainAccount: String, Sendable {
    case github
    case linear
}

/// Tries each provider in turn and returns the first token found.
///
/// Used to express "the Keychain, or the environment if the Keychain has nothing" without
/// either provider knowing about the other.
public struct FirstAvailableTokenProvider: TokenProvider {
    private let providers: [any TokenProvider]
    private let service: String

    public init(_ providers: [any TokenProvider], service: String = "") {
        self.providers = providers
        self.service = service
    }

    /// A real failure is remembered but does not stop the search.
    ///
    /// The two outcomes it separates: a Keychain that is present but refuses to answer,
    /// with nothing else configured, must surface as *that* failure and not as "not
    /// connected" — so the error is rethrown once the chain is exhausted. But if a later
    /// provider does hold a credential, the credential wins: the app's job is to poll, and
    /// failing the poll to report a broken Keychain the user has already worked around
    /// would be choosing the diagnosis over the diagnosis's purpose.
    public func token() throws -> String {
        var lastError: (any Error)?
        for provider in providers {
            do {
                return try provider.token()
            } catch is MissingCredential {
                continue
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw MissingCredential(service: service)
    }
}

/// The credential chain every integration uses: an explicit value, then the environment,
/// then the login Keychain.
///
/// The Keychain is last because an explicit flag or an exported variable is always the more
/// deliberate intent — and because it is absent entirely off macOS, which is the reason the
/// `canImport(Security)` fence lives here, once, rather than at each of the four call sites
/// that would otherwise repeat it.
public enum CredentialChain {
    public static func standard(
        explicit: String? = nil,
        environment: EnvironmentTokenProvider,
        keychain account: KeychainAccount,
        service: String
    ) -> FirstAvailableTokenProvider {
        var providers: [any TokenProvider] = []
        if let explicit {
            providers.append(StaticTokenProvider(explicit, service: service))
        }
        providers.append(environment)
        #if canImport(Security)
        providers.append(KeychainTokenStore(account: account))
        #endif
        return FirstAvailableTokenProvider(providers, service: service)
    }
}
