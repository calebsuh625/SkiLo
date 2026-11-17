import Foundation

/// JSON document persistence (DESIGN §9): atomic writes, backup rotation, debounced saves,
/// corrupt-file quarantine, newer-schema refusal.
final class UserDataStore {
    enum LoadResult {
        case loaded(UserData)
        case fresh
        case recoveredFromBackup(UserData)
        case corrupt(movedTo: URL?, error: Error)
        case newerSchema(Int)
    }
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("userdata.json") }
    var backupURL: URL { directory.appendingPathComponent("userdata.backup.json") }
    private var tmpURL: URL { directory.appendingPathComponent("userdata.json.tmp") }

    /// Debounce window for `scheduleSave` (DESIGN §9: 500 ms). Tests may shorten/lengthen it.
    var debounce: TimeInterval = 0.5

    private let stateLock = NSLock()      // guards pending / work / counters
    private let writeLock = NSRecursiveLock()   // serialises disk writes
    private let queue = DispatchQueue(label: "HeavenlyTracker.UserDataStore", qos: .utility)
    private var pending: UserData?
    private var work: DispatchWorkItem?
    private var _writeCount = 0
    private var _lastError: Error?

    /// Number of successful disk writes since init (tests assert debounce coalescing with it).
    var writeCount: Int { stateLock.lock(); defer { stateLock.unlock() }; return _writeCount }
    var lastError: Error? { stateLock.lock(); defer { stateLock.unlock() }; return _lastError }
    var hasPendingSave: Bool { stateLock.lock(); defer { stateLock.unlock() }; return pending != nil }

    static func defaultDirectory() -> URL {
        if let d = DevHooks.userDataDirectory { return d }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("HeavenlyTracker", isDirectory: true)
    }
    init(directory: URL) { self.directory = directory }

    // MARK: load

    func load() -> LoadResult {
        let fm = FileManager.default
        let mainExists = fm.fileExists(atPath: fileURL.path)
        if !mainExists {
            if fm.fileExists(atPath: backupURL.path), let d = try? Self.decode(Data(contentsOf: backupURL)) { return .recoveredFromBackup(d) }
            return .fresh
        }
        do {
            return .loaded(try Self.decode(Data(contentsOf: fileURL)))
        } catch MigrationError.newerSchema(let n) {
            return .newerSchema(n)
        } catch {
            let moved = quarantineMainFile()
            if fm.fileExists(atPath: backupURL.path) {
                do { return .recoveredFromBackup(try Self.decode(Data(contentsOf: backupURL))) }
                catch MigrationError.newerSchema(let n) { return .newerSchema(n) }
                catch { /* fall through */ }
            }
            return .corrupt(movedTo: moved, error: error)
        }
    }

    private func quarantineMainFile() -> URL? {
        let fm = FileManager.default
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        var dest = directory.appendingPathComponent("userdata.corrupt-\(f.string(from: Date())).json")
        if fm.fileExists(atPath: dest.path) {
            dest = directory.appendingPathComponent("userdata.corrupt-\(f.string(from: Date()))-\(UUID().uuidString.prefix(6)).json")
        }
        do { try fm.moveItem(at: fileURL, to: dest); return dest } catch { NSLog("UserDataStore: could not quarantine corrupt file: \(error)"); return nil }
    }

    // MARK: save

    /// Coalescing save: only the latest snapshot within the debounce window is written.
    func scheduleSave(_ data: UserData) {
        stateLock.lock()
        pending = data
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.writePending() }
        work = item
        let delay = debounce
        stateLock.unlock()
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Synchronous write of any pending snapshot.
    func flush() {
        stateLock.lock(); work?.cancel(); work = nil; stateLock.unlock()
        writePending()
    }

    private func writePending() {
        stateLock.lock(); let data = pending; pending = nil; work = nil; stateLock.unlock()
        guard let data else { return }
        do { try write(data) } catch {
            NSLog("UserDataStore: save failed: \(error)")
            stateLock.lock(); _lastError = error; if pending == nil { pending = data }; stateLock.unlock()
        }
    }

    /// Atomic write: tmp file → previous file becomes the backup → replace.
    func write(_ data: UserData) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var doc = data
        doc.trailStates = doc.trailStates.filter { !$0.value.isEmpty }       // pruning (DESIGN §9)
        let bytes = try Self.encode(doc)
        try bytes.write(to: tmpURL)
        if fm.fileExists(atPath: fileURL.path) {
            // Only a readable previous document may become the backup.
            if let prev = try? Data(contentsOf: fileURL), (try? Self.decode(prev)) != nil {
                try? fm.removeItem(at: backupURL)
                try? fm.copyItem(at: fileURL, to: backupURL)
            }
            _ = try fm.replaceItemAt(fileURL, withItemAt: tmpURL)
        } else {
            try fm.moveItem(at: tmpURL, to: fileURL)
        }
        stateLock.lock(); _writeCount += 1; _lastError = nil; stateLock.unlock()
    }

    /// `userdata.pre-import-<ts>.json` — a copy of `data` taken before an import replaces it.
    @discardableResult
    func writePreImportBackup(_ data: UserData) throws -> URL {
        writeLock.lock(); defer { writeLock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        var url = directory.appendingPathComponent("userdata.pre-import-\(f.string(from: Date())).json")
        if FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("userdata.pre-import-\(f.string(from: Date()))-\(UUID().uuidString.prefix(6)).json")
        }
        try Self.encode(data).write(to: url, options: .atomic)
        return url
    }

    // MARK: coding

    static func encode(_ data: UserData) throws -> Data {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return try e.encode(data)
    }
    /// Runs `Migrations` on the raw JSON first; throws `MigrationError.newerSchema(n)` for a newer document.
    static func decode(_ data: Data) throws -> UserData {
        let migrated = try Migrations.migrate(data: data)
        let bytes = try JSONSerialization.data(withJSONObject: migrated)
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(UserData.self, from: bytes)
    }
}
