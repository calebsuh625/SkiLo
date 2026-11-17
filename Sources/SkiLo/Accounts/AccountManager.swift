import Foundation
import AppKit
import Observation
import CommonCrypto

/// A local SkiLo account: username + password. Each account keeps its own `userdata.json`.
struct Account: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: UUID = UUID()
    var username: String
    var createdAt: Date = Date()
    var password: PasswordHash

    var initials: String { username.first.map { String($0).uppercased() } ?? "?" }
}

/// Salted PBKDF2-SHA256. Only the hash is stored, never the password.
struct PasswordHash: Codable, Equatable, Hashable, Sendable {
    var salt: Data
    var hash: Data
    var iterations: Int

    /// Lowered by tests to keep them fast.
    nonisolated(unsafe) static var defaultIterations = 210_000

    static func make(_ password: String, iterations: Int = defaultIterations) -> PasswordHash {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return PasswordHash(salt: salt, hash: derive(password, salt: salt, iterations: iterations), iterations: iterations)
    }

    func matches(_ password: String) -> Bool {
        let candidate = Self.derive(password, salt: salt, iterations: iterations)
        guard candidate.count == hash.count else { return false }
        return zip(candidate, hash).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0     // constant time
    }

    static func derive(_ password: String, salt: Data, iterations: Int) -> Data {
        let pw = Array(password.utf8).map { Int8(bitPattern: $0) }
        var out = Data(count: 32)
        out.withUnsafeMutableBytes { outBuf in
            salt.withUnsafeBytes { saltBuf in
                _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count,
                                         saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         outBuf.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return out
    }
}

/// `accounts.json` in the data root.
struct AccountIndex: Codable, Equatable, Sendable {
    var accounts: [Account] = []
    /// Set only when the user ticked "Remember me": that account is signed in at launch.
    var rememberedID: UUID? = nil
}

enum AccountError: LocalizedError, Equatable {
    case invalidUsername, usernameTaken(String), weakPassword, wrongCredentials, notFound
    var errorDescription: String? {
        switch self {
        case .invalidUsername: "Usernames are 3–20 characters: letters, numbers, “.”, “_” or “-”."
        case .usernameTaken(let n): "The username “\(n)” is already taken."
        case .weakPassword: "Use a password with at least \(AccountManager.minPasswordLength) characters."
        case .wrongCredentials: "Wrong username or password."
        case .notFound: "That account no longer exists."
        }
    }
}

/// Owns the account list and the `AppStore` of the signed-in account.
///
/// Layout under the data root (Application Support/SkiLo, or `HT_USERDATA_DIR`):
///   accounts.json
///   accounts/<uuid>/userdata.json (+ backups)
@Observable @MainActor
final class AccountManager {
    nonisolated static let minPasswordLength = 8

    let root: URL
    private(set) var index: AccountIndex
    private(set) var currentID: UUID?
    /// The signed-in account's store; nil while signed out (the sign-in screen is shown).
    private(set) var store: AppStore?
    /// Bumps on every sign-in/switch so views keyed on it are rebuilt.
    private(set) var sessionID = UUID()
    var lastError: String?

    /// Used by static menu actions (Reveal Data Folder) to find the current account's folder.
    static var currentDataDirectory: URL?

    var accounts: [Account] { index.accounts }
    var current: Account? { currentID.flatMap { id in index.accounts.first { $0.id == id } } }
    var isRemembered: Bool { currentID != nil && index.rememberedID == currentID }
    var indexURL: URL { root.appendingPathComponent("accounts.json") }
    func directory(for id: UUID) -> URL { root.appendingPathComponent("accounts", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true) }

    init(root: URL) {
        self.root = root
        self.index = Self.loadIndex(at: root.appendingPathComponent("accounts.json")) ?? AccountIndex()
        if let id = index.rememberedID, index.accounts.contains(where: { $0.id == id }) {
            open(id)
        } else if DevHooks.userDataDirectory != nil, DevHooks.env["HT_SHOW_SIGNIN"] != "1" {
            // Scripted runs (screenshots, HT_USERDATA_DIR) get a throwaway account without the form.
            let name = DevHooks.env["HT_ACCOUNT"] ?? "tester"
            if let existing = index.accounts.first(where: { $0.username.caseInsensitiveCompare(name) == .orderedSame }) { open(existing.id) }
            else { _ = try? createAccount(username: name, password: "scripted-run", remember: false) }
        }
    }

    static func bootstrap() -> AccountManager { AccountManager(root: UserDataStore.defaultDirectory()) }

    // MARK: actions

    @discardableResult
    func createAccount(username raw: String, password: String, remember: Bool) throws -> Account {
        let username = try validatedUsername(raw, excluding: nil)
        guard password.count >= Self.minPasswordLength else { throw AccountError.weakPassword }
        let account = Account(username: username, password: .make(password))
        try FileManager.default.createDirectory(at: directory(for: account.id), withIntermediateDirectories: true)
        index.accounts.append(account)
        finishSignIn(account.id, remember: remember)
        return account
    }

    func signIn(username: String, password: String, remember: Bool) throws {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let account = index.accounts.first(where: { $0.username.caseInsensitiveCompare(name) == .orderedSame }),
              account.password.matches(password) else { throw AccountError.wrongCredentials }
        finishSignIn(account.id, remember: remember)
    }

    /// Signs out and forgets "Remember me", so the next launch asks for the password.
    func signOut() {
        store?.flush()
        store = nil
        currentID = nil
        index.rememberedID = nil
        Self.currentDataDirectory = nil
        sessionID = UUID()
        saveIndex()
    }

    func rename(_ id: UUID, to raw: String) throws {
        let name = try validatedUsername(raw, excluding: id)
        guard let i = index.accounts.firstIndex(where: { $0.id == id }) else { throw AccountError.notFound }
        index.accounts[i].username = name
        saveIndex()
    }

    func changePassword(_ id: UUID, current: String, new: String) throws {
        guard let i = index.accounts.firstIndex(where: { $0.id == id }) else { throw AccountError.notFound }
        guard index.accounts[i].password.matches(current) else { throw AccountError.wrongCredentials }
        guard new.count >= Self.minPasswordLength else { throw AccountError.weakPassword }
        index.accounts[i].password = .make(new)
        saveIndex()
    }

    /// Moves the account's folder to the Trash (recoverable from Finder) and removes it from the list.
    func deleteAccount(_ id: UUID) throws {
        if currentID == id { signOut() }
        let dir = directory(for: id)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        }
        index.accounts.removeAll { $0.id == id }
        if index.rememberedID == id { index.rememberedID = nil }
        saveIndex()
    }

    // MARK: internals

    private func finishSignIn(_ id: UUID, remember: Bool) {
        store?.flush()
        index.rememberedID = remember ? id : nil
        saveIndex()
        open(id)
    }

    private func open(_ id: UUID) {
        let dir = directory(for: id)
        currentID = id
        Self.currentDataDirectory = dir
        store = AppStore.bootstrap(directory: dir)
        sessionID = UUID()
    }

    private func validatedUsername(_ raw: String, excluding: UUID?) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard (3...20).contains(name.count), name.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }) else {
            throw AccountError.invalidUsername
        }
        if index.accounts.contains(where: { $0.id != excluding && $0.username.caseInsensitiveCompare(name) == .orderedSame }) {
            throw AccountError.usernameTaken(name)
        }
        return name
    }

    private func saveIndex() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
            try e.encode(index).write(to: indexURL, options: .atomic)
            // Password hashes live here: keep the file private to this macOS user.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
        } catch {
            NSLog("AccountManager: could not save accounts.json: \(error)")
            lastError = error.localizedDescription
        }
    }

    private static func loadIndex(at url: URL) -> AccountIndex? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(AccountIndex.self, from: data)
    }
}
