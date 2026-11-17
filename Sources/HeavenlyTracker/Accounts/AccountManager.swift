import Foundation
import AppKit
import Observation

/// A local profile on this Mac. Each account keeps its own `userdata.json` (trails, log, Elo).
struct Account: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap(\.first).map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }
}

/// `accounts.json` in the data root.
struct AccountIndex: Codable, Equatable, Sendable {
    var accounts: [Account] = []
    var currentID: UUID? = nil
}

enum AccountError: LocalizedError, Equatable {
    case emptyName, duplicateName(String), notFound
    var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a name for the account."
        case .duplicateName(let n): "There is already an account called “\(n)”."
        case .notFound: "That account no longer exists."
        }
    }
}

/// Owns the account list and the `AppStore` of the signed-in account.
///
/// Layout under the data root (Application Support/HeavenlyTracker, or `HT_USERDATA_DIR`):
///   accounts.json
///   accounts/<uuid>/userdata.json (+ backups)
/// A pre-accounts `userdata.json` in the root is moved into the first account on launch.
@Observable @MainActor
final class AccountManager {
    let root: URL
    private(set) var index: AccountIndex
    /// The signed-in account's store; nil while signed out (the account picker is shown).
    private(set) var store: AppStore?
    /// Bumps on every sign-in/switch so views keyed on it are rebuilt.
    private(set) var sessionID = UUID()
    var lastError: String?

    /// Used by static menu actions (Reveal Data Folder) to find the current account's folder.
    static var currentDataDirectory: URL?

    var accounts: [Account] { index.accounts }
    var current: Account? { index.currentID.flatMap { id in index.accounts.first { $0.id == id } } }
    var indexURL: URL { root.appendingPathComponent("accounts.json") }
    func directory(for id: UUID) -> URL { root.appendingPathComponent("accounts", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true) }

    init(root: URL) {
        self.root = root
        self.index = Self.loadIndex(at: root.appendingPathComponent("accounts.json")) ?? AccountIndex()
        migrateLegacyDataIfNeeded()
        // Scripted runs (screenshots, HT_USERDATA_DIR) get an account without the picker.
        if index.accounts.isEmpty && DevHooks.userDataDirectory != nil {
            _ = try? createAccount(name: DevHooks.env["HT_ACCOUNT"] ?? "Tester")
        } else if let id = index.currentID, index.accounts.contains(where: { $0.id == id }) {
            openStore(for: id)
        } else {
            index.currentID = nil
        }
    }

    static func bootstrap() -> AccountManager { AccountManager(root: UserDataStore.defaultDirectory()) }

    // MARK: actions

    @discardableResult
    func createAccount(name raw: String) throws -> Account {
        let name = try validated(raw, excluding: nil)
        let account = Account(name: name)
        try FileManager.default.createDirectory(at: directory(for: account.id), withIntermediateDirectories: true)
        index.accounts.append(account)
        saveIndex()
        signIn(account.id)
        return account
    }

    func signIn(_ id: UUID) {
        guard index.accounts.contains(where: { $0.id == id }) else { lastError = AccountError.notFound.localizedDescription; return }
        store?.flush()
        index.currentID = id
        saveIndex()
        openStore(for: id)
    }

    func signOut() {
        store?.flush()
        store = nil
        index.currentID = nil
        Self.currentDataDirectory = nil
        sessionID = UUID()
        saveIndex()
    }

    func rename(_ id: UUID, to raw: String) throws {
        let name = try validated(raw, excluding: id)
        guard let i = index.accounts.firstIndex(where: { $0.id == id }) else { throw AccountError.notFound }
        index.accounts[i].name = name
        saveIndex()
    }

    /// Moves the account's folder to the Trash (recoverable from Finder) and removes it from the list.
    func deleteAccount(_ id: UUID) throws {
        if index.currentID == id { signOut() }
        let dir = directory(for: id)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        }
        index.accounts.removeAll { $0.id == id }
        saveIndex()
    }

    // MARK: internals

    private func openStore(for id: UUID) {
        let dir = directory(for: id)
        Self.currentDataDirectory = dir
        store = AppStore.bootstrap(directory: dir)
        sessionID = UUID()
    }

    private func validated(_ raw: String, excluding: UUID?) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AccountError.emptyName }
        if index.accounts.contains(where: { $0.id != excluding && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw AccountError.duplicateName(name)
        }
        return name
    }

    /// Before accounts existed, data lived at `<root>/userdata.json`. Move it into a first account
    /// (named after the Mac user) so nobody loses their history.
    private func migrateLegacyDataIfNeeded() {
        let fm = FileManager.default
        let legacy = ["userdata.json", "userdata.backup.json"].map { root.appendingPathComponent($0) }
        guard index.accounts.isEmpty, legacy.contains(where: { fm.fileExists(atPath: $0.path) }) else { return }
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        let account = Account(name: first.isEmpty ? "Me" : first)
        let dir = directory(for: account.id)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for url in legacy where fm.fileExists(atPath: url.path) {
                try fm.moveItem(at: url, to: dir.appendingPathComponent(url.lastPathComponent))
            }
            index.accounts = [account]
            index.currentID = account.id
            saveIndex()
        } catch {
            NSLog("AccountManager: legacy migration failed: \(error)")
            lastError = "Could not move your existing data into an account: \(error.localizedDescription)"
        }
    }

    private func saveIndex() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
            try e.encode(index).write(to: indexURL, options: .atomic)
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
