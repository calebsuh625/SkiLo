import Foundation

enum Units: String, Codable, CaseIterable, Sendable { case imperial, metric }
enum TrailStatus: String, Codable, CaseIterable, Hashable, Sendable { case notDone, bucket, done }

struct UserTrailState: Codable, Equatable, Hashable, Sendable {
    var status: TrailStatus = .notDone
    var bucketedAt: Date? = nil          // kept after .done → "crossed off"
    var firstDoneDate: Date? = nil
    var lastDoneDate: Date? = nil
    var timesSkied: Int = 0
    var backfilled: Bool = false
    var ratingOverride: Int? = nil       // 1…100
    var ratingOverrideNote: String? = nil
    var notes: String = ""
    var photoFilenames: [String] = []

    init() {}
    var isEmpty: Bool { self == UserTrailState() }
    var isDone: Bool { status == .done }

    private enum CodingKeys: String, CodingKey { case status, bucketedAt, firstDoneDate, lastDoneDate, timesSkied, backfilled, ratingOverride, ratingOverrideNote, notes, photoFilenames }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(TrailStatus.self, forKey: .status) ?? .notDone
        bucketedAt = try c.decodeIfPresent(Date.self, forKey: .bucketedAt)
        firstDoneDate = try c.decodeIfPresent(Date.self, forKey: .firstDoneDate)
        lastDoneDate = try c.decodeIfPresent(Date.self, forKey: .lastDoneDate)
        timesSkied = try c.decodeIfPresent(Int.self, forKey: .timesSkied) ?? 0
        backfilled = try c.decodeIfPresent(Bool.self, forKey: .backfilled) ?? false
        ratingOverride = try c.decodeIfPresent(Int.self, forKey: .ratingOverride)
        ratingOverrideNote = try c.decodeIfPresent(String.self, forKey: .ratingOverrideNote)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        photoFilenames = try c.decodeIfPresent([String].self, forKey: .photoFilenames) ?? []
    }
}

enum Conditions: String, Codable, CaseIterable, Hashable, Sendable {
    case groomed, packedPowder, powder, chopped, firm, slush, moguls, variable
    var multiplier: Double {
        switch self {
        case .groomed, .packedPowder: 1.00
        case .powder: 0.95
        case .chopped: 1.10
        case .firm: 1.15
        case .slush: 1.05
        case .moguls: 1.10
        case .variable: 1.10
        }
    }
    var label: String {
        switch self {
        case .groomed: "Groomed"
        case .packedPowder: "Packed"
        case .powder: "Powder"
        case .chopped: "Chopped"
        case .firm: "Firm/icy"
        case .slush: "Slush"
        case .moguls: "Bumped up"
        case .variable: "Variable"
        }
    }
}

struct RunLogEntry: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: UUID = UUID()
    var trailID: Trail.ID
    var date: Date
    var conditions: Conditions = .groomed
    var confidence: Int = 3            // 1…5
    var notes: String = ""
    var isFirstTime: Bool = false
    var dayKey: String { SkiDay.key(for: date) }

    init(id: UUID = UUID(), trailID: Trail.ID, date: Date, conditions: Conditions = .groomed, confidence: Int = 3, notes: String = "", isFirstTime: Bool = false) {
        self.id = id; self.trailID = trailID; self.date = date; self.conditions = conditions
        self.confidence = confidence; self.notes = notes; self.isFirstTime = isFirstTime
    }
    private enum CodingKeys: String, CodingKey { case id, trailID, date, conditions, confidence, notes, isFirstTime }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        trailID = try c.decode(Trail.ID.self, forKey: .trailID)
        date = try c.decode(Date.self, forKey: .date)
        conditions = try c.decodeIfPresent(Conditions.self, forKey: .conditions) ?? .groomed
        confidence = try c.decodeIfPresent(Int.self, forKey: .confidence) ?? 3
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        isFirstTime = try c.decodeIfPresent(Bool.self, forKey: .isFirstTime) ?? false
    }
}

struct SkiDayMeta: Codable, Equatable, Hashable, Sendable {
    var title: String = ""
    var conditions: Conditions? = nil
    var notes: String = ""
    init(title: String = "", conditions: Conditions? = nil, notes: String = "") { self.title = title; self.conditions = conditions; self.notes = notes }
    private enum CodingKeys: String, CodingKey { case title, conditions, notes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        conditions = try c.decodeIfPresent(Conditions.self, forKey: .conditions)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

struct SkillPoint: Codable, Equatable, Hashable, Sendable {
    var date: Date
    var value: Double
    var low: Double
    var high: Double
    var runCount: Int
}

struct UserProfile: Codable, Equatable, Hashable, Sendable {
    var selfAssessedStart: Int = 30
    var startDate: Date = Date()
    var units: Units = .imperial
    var onboardingDone: Bool = false
    var skillHistory: [SkillPoint] = []
    var unlockedMilestones: [String: Date] = [:]

    init() {}
    private enum CodingKeys: String, CodingKey { case selfAssessedStart, startDate, units, onboardingDone, skillHistory, unlockedMilestones }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selfAssessedStart = try c.decodeIfPresent(Int.self, forKey: .selfAssessedStart) ?? 30
        startDate = try c.decodeIfPresent(Date.self, forKey: .startDate) ?? Date()
        units = try c.decodeIfPresent(Units.self, forKey: .units) ?? .imperial
        onboardingDone = try c.decodeIfPresent(Bool.self, forKey: .onboardingDone) ?? false
        skillHistory = try c.decodeIfPresent([SkillPoint].self, forKey: .skillHistory) ?? []
        unlockedMilestones = try c.decodeIfPresent([String: Date].self, forKey: .unlockedMilestones) ?? [:]
    }
}

struct UserData: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0" }

    var schemaVersion: Int = UserData.currentSchemaVersion
    var appVersion: String = UserData.appVersion
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var profile: UserProfile = UserProfile()
    var trailStates: [Trail.ID: UserTrailState] = [:]
    var bucketOrder: [Trail.ID] = []
    var runLog: [RunLogEntry] = []
    var skiDays: [String: SkiDayMeta] = [:]
    /// Completed runs that count toward Elo (see `Elo`). Backfilled trails are not included.
    var eloEvents: [EloEvent] = []

    init() {}
    static func fresh() -> UserData { UserData() }
    func state(for id: Trail.ID) -> UserTrailState { trailStates[id] ?? UserTrailState() }

    private enum CodingKeys: String, CodingKey { case schemaVersion, appVersion, createdAt, updatedAt, profile, trailStates, bucketOrder, runLog, skiDays, eloEvents }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? "unknown"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        profile = try c.decodeIfPresent(UserProfile.self, forKey: .profile) ?? UserProfile()
        trailStates = try c.decodeIfPresent([Trail.ID: UserTrailState].self, forKey: .trailStates) ?? [:]
        bucketOrder = try c.decodeIfPresent([Trail.ID].self, forKey: .bucketOrder) ?? []
        runLog = try c.decodeIfPresent([RunLogEntry].self, forKey: .runLog) ?? []
        skiDays = try c.decodeIfPresent([String: SkiDayMeta].self, forKey: .skiDays) ?? [:]
        eloEvents = try c.decodeIfPresent([EloEvent].self, forKey: .eloEvents) ?? []
    }
}

/// Derived grouping of the log by local calendar day (newest first).
struct SkiDay: Identifiable, Equatable {
    let id: String                 // "yyyy-MM-dd" local
    let date: Date                 // start of day
    var entries: [RunLogEntry]     // chronological
    var meta: SkiDayMeta?

    static let keyFormatter: DateFormatter = {
        let f = DateFormatter(); f.calendar = .current; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static func key(for date: Date) -> String { keyFormatter.string(from: date) }
    static func group(_ log: [RunLogEntry], meta: [String: SkiDayMeta]) -> [SkiDay] {
        let byKey = Dictionary(grouping: log, by: { $0.dayKey })
        return byKey.map { key, entries in
            SkiDay(id: key, date: Calendar.current.startOfDay(for: entries.map(\.date).min() ?? Date()),
                   entries: entries.sorted { $0.date < $1.date }, meta: meta[key])
        }.sorted { $0.date > $1.date }
    }
}
