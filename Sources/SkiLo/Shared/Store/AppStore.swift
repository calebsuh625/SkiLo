import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Observation
import SwiftUI

enum SidebarSection: String, CaseIterable, Codable, Sendable {
    case map, today, trails, bucket, progress, log
    var title: String {
        switch self { case .map: "Map"; case .today: "Today"; case .trails: "Trails"; case .bucket: "Bucket List"; case .progress: "Progress"; case .log: "Log" }
    }
    var symbol: String {
        switch self {
        case .map: "map.fill"; case .today: "sun.snow.fill"; case .trails: "list.bullet.rectangle"; case .bucket: "star.fill"
        case .progress: "chart.line.uptrend.xyaxis"; case .log: "book.closed.fill"
        }
    }
}

struct LogRunRequest: Identifiable, Equatable {
    let id = UUID()
    var trailID: Trail.ID?
    var date: Date = .now
    var existing: RunLogEntry? = nil       // edit mode
}

/// Modal message RootView presents (corrupt file, newer schema, import problems).
struct StoreAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
    var revealURL: URL? = nil
}

struct StatusChange: Equatable {
    var trailID: Trail.ID
    var badge: TrailStyle.Badge
    var revision: Int
}

@Observable @MainActor
final class AppStore {
    // MARK: static data
    /// Every resort's catalog (Heavenly first).
    let catalogs: [TrailCatalog]
    /// The resort being shown: map, trail list, picks, routes and progress use this.
    private(set) var catalog: TrailCatalog
    /// Trails of every resort, so Elo, the bucket list and the log work across resorts.
    let trailsByID: [Trail.ID: Trail]
    private let allTrails: [Trail]
    private(set) var resortID: String
    var resort: ResortInfo { ResortInfo.info(for: resortID) }

    // MARK: persisted
    private(set) var userData: UserData
    /// Incremented on every userData mutation; views/map use it as a cheap change key.
    private(set) var revision: Int = 0

    // MARK: session / UI
    var filter = TrailFilter()
    var selection: Trail.ID?
    var hover: Trail.ID?
    var section: SidebarSection = .map { didSet { if section != oldValue { uiDefaults?.set(section.rawValue, forKey: "ui.section") } } }
    var inspectorShown = true { didSet { if inspectorShown != oldValue { uiDefaults?.set(inspectorShown, forKey: "ui.inspectorShown") } } }
    var legendShown = true { didSet { if legendShown != oldValue { uiDefaults?.set(legendShown, forKey: "ui.legendShown") } } }
    var mapBaseStyle: MapBaseStyle = .satellite { didSet { if mapBaseStyle != oldValue { uiDefaults?.set(mapBaseStyle.rawValue, forKey: "map.baseStyle") } } }
    var cameraRequest: CameraPreset?            // MapScreen consumes and sets back to nil
    var lastStatusChange: StatusChange?         // MapScreen animates and clears
    var toast: Toast?
    var logRunRequest: LogRunRequest?           // RootView presents LogRunSheet
    var showOnboarding = false
    // Routing & day planning (session state; closures persist for the day).
    var directions = DirectionsState()
    var closures = Closures() { didSet { if closures != oldValue, let d = try? JSONEncoder().encode(closures) { uiDefaults?.set(d, forKey: "plan.closures") } } }
    /// The plan drawn on the map (set from the Today screen's "Show on Map").
    var shownPlan: DayPlan?
    var planner = PlannerState()
    var forecast: ForecastState = .idle
    /// Fly-through the map should play next; MapScreen consumes it.
    var flyRequest: FlyRequest?
    /// True while a fly-through plays; set by the map.
    var isFlying = false
    /// Set to stop the playing fly-through (Esc); the map clears it.
    var stopFlyRequested = false
    /// Set by `bootstrap()` for load problems; RootView shows it and sets it back to nil.
    var pendingAlert: StoreAlert?
    /// True when the document on disk is from a newer app: edits stay in memory only.
    private(set) var isReadOnlySession = false
    weak var undoManager: UndoManager?

    // MARK: collaborators
    let progression: any ProgressionEngine
    let persistence: UserDataStore?
    @ObservationIgnored private var uiDefaults: UserDefaults?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?
    @ObservationIgnored private var ratingsCache: (revision: Int, ratings: [Trail.ID: Int])?
    @ObservationIgnored private var eloCache: (revision: Int, history: [EloPoint])?
    @ObservationIgnored private var routerCache: (resort: String, router: Router)?
    /// The current resort's route graph, built on first use (~50 ms).
    var router: Router {
        if let c = routerCache, c.resort == resortID { return c.router }
        let r = Router(catalog: catalog)
        routerCache = (resortID, r)
        return r
    }

    convenience init(catalog: TrailCatalog, userData: UserData, persistence: UserDataStore?, progression: any ProgressionEngine = DefaultProgressionEngine()) {
        self.init(catalogs: [catalog], userData: userData, persistence: persistence, progression: progression)
    }

    init(catalogs: [TrailCatalog], userData: UserData, persistence: UserDataStore?, progression: any ProgressionEngine = DefaultProgressionEngine()) {
        let catalogs = catalogs.isEmpty ? [.empty] : catalogs
        self.catalogs = catalogs
        self.catalog = catalogs[0]
        self.resortID = catalogs[0].id
        self.allTrails = catalogs.flatMap(\.trails)
        self.trailsByID = Dictionary(allTrails.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.userData = userData
        self.persistence = persistence
        self.progression = progression
        self.showOnboarding = !userData.profile.onboardingDone && !DevHooks.skipOnboarding
        // UI prefs live in UserDefaults only for the real app (never for tests or scripted runs).
        if persistence != nil && DevHooks.userDataDirectory == nil {
            let d = UserDefaults.standard
            uiDefaults = d
            if let s = d.string(forKey: "ui.section"), let v = SidebarSection(rawValue: s) { section = v }
            if d.object(forKey: "ui.inspectorShown") != nil { inspectorShown = d.bool(forKey: "ui.inspectorShown") }
            if d.object(forKey: "ui.legendShown") != nil { legendShown = d.bool(forKey: "ui.legendShown") }
            if let s = d.string(forKey: "map.baseStyle"), let v = MapBaseStyle(rawValue: s) { mapBaseStyle = v }
            if let data = d.data(forKey: "plan.closures"), let c = try? JSONDecoder().decode(Closures.self, from: data) { closures = c }
            if let r = d.string(forKey: "ui.resort"), let c = catalogs.first(where: { $0.id == r }) { catalog = c; resortID = r }
        }
    }

    /// Loads the bundled catalog and the user document, handling every `LoadResult`.
    static func bootstrap(directory: URL? = nil) -> AppStore {
        let catalogs: [TrailCatalog]
        do { catalogs = try CatalogLoader.loadAllBundled() } catch {
            NSLog("FATAL: \(error)")
            catalogs = [.empty]
        }
        let dir = directory ?? UserDataStore.defaultDirectory()
        let disk = UserDataStore(directory: dir)
        var data = UserData.fresh()
        var alert: StoreAlert?
        var persistence: UserDataStore? = disk
        switch disk.load() {
        case .loaded(let d): data = d
        case .fresh: break
        case .recoveredFromBackup(let d):
            data = d
            alert = StoreAlert(title: "Recovered from backup",
                               message: "Your data file could not be read, so the most recent backup was restored. Recent changes may be missing.",
                               revealURL: dir)
        case .corrupt(let moved, let error):
            alert = StoreAlert(title: "Your data file was unreadable",
                               message: "Starting fresh. The damaged file was kept\(moved.map { " as \($0.lastPathComponent)" } ?? "") so it can be recovered.\n\n\(error.localizedDescription)",
                               revealURL: moved ?? dir)
        case .newerSchema(let n):
            persistence = nil
            alert = StoreAlert(title: "Data is from a newer version",
                               message: "Your data file uses format v\(n), which this version (v\(UserData.currentSchemaVersion)) cannot read. It will not be modified. Changes made in this session will not be saved.",
                               revealURL: dir)
        }
        let store = AppStore(catalogs: catalogs, userData: data, persistence: persistence)
        store.isReadOnlySession = persistence == nil
        store.pendingAlert = alert
        // Skill history is a cache of the Elo games: recompute on load (DESIGN §10).
        let history = store.skillHistory(for: data)
        if history != store.userData.profile.skillHistory { store.userData.profile.skillHistory = history }
        store.startObservingTermination()
        return store
    }

    private func startObservingTermination() {
        guard terminateObserver == nil else { return }
        #if os(macOS)
        let note = NSApplication.willTerminateNotification
        #else
        let note = UIApplication.didEnterBackgroundNotification      // iOS may kill a backgrounded app without warning
        #endif
        terminateObserver = NotificationCenter.default.addObserver(forName: note, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    // MARK: derived (read-only)
    func trail(_ id: Trail.ID) -> Trail? { trailsByID[id] }
    func state(for id: Trail.ID) -> UserTrailState { userData.state(for: id) }
    func effectiveRating(_ id: Trail.ID) -> Int { state(for: id).ratingOverride ?? (trailsByID[id]?.rating.total ?? 0) }
    func effectiveRating(_ t: Trail) -> Int { effectiveRating(t.id) }
    /// Cached per `revision`.
    var effectiveRatings: [Trail.ID: Int] {
        if let c = ratingsCache, c.revision == revision { return c.ratings }
        let r = ratings(for: userData)
        ratingsCache = (revision, r)
        return r
    }
    private func ratings(for d: UserData) -> [Trail.ID: Int] {
        Dictionary(allTrails.map { ($0.id, d.state(for: $0.id).ratingOverride ?? $0.rating.total) }, uniquingKeysWith: { a, _ in a })
    }
    // MARK: Elo
    var eloStart: Double { Elo.startElo(selfAssessed: userData.profile.selfAssessedStart) }
    /// Cached per `revision`.
    var eloHistory: [EloPoint] {
        if let c = eloCache, c.revision == revision { return c.history }
        let h = Elo.history(start: eloStart, events: userData.eloEvents, ratings: effectiveRatings)
        eloCache = (revision, h)
        return h
    }
    /// Your Elo = your skill rating, 1–100.
    var elo: Double { eloHistory.last?.elo ?? eloStart }
    /// Runs that have counted toward Elo so far.
    var eloGames: Int { eloHistory.count }
    /// Shown as "est." until a few runs have counted.
    var eloIsProvisional: Bool { eloGames < Elo.provisionalGames }
    /// Change from the most recent counted run (nil before the first one).
    var lastEloDelta: Double? { eloHistory.last?.delta }
    /// What a clean run of `id` would be worth right now.
    func eloPreview(for id: Trail.ID) -> Double {
        let prior = userData.eloEvents.filter { $0.trailID == id }.count
        return Elo.delta(player: elo, trailRating: effectiveRating(id), score: 1, priorRunsOnTrail: prior)
    }
    private func eloSuffix(since before: Double) -> String {
        Elo.formatDelta(elo - before).map { " · \($0) Elo" } ?? ""
    }
    /// The skill chart / readiness series, derived from the Elo games.
    private func skillHistory(for d: UserData) -> [SkillPoint] {
        Elo.skillHistory(profile: d.profile, events: d.eloEvents, ratings: ratings(for: d))
    }

    /// The skill estimate *is* the Elo (readiness, suggestions and the Progress chart use it).
    var skill: SkillEstimate {
        let half = Elo.uncertainty(games: eloGames)
        return SkillEstimate(value: elo, low: max(1, elo - half), high: min(100, elo + half), basisRuns: eloGames)
    }
    func readiness(for id: Trail.ID) -> Readiness {
        progression.readiness(rating: effectiveRating(id), modifiers: trailsByID[id]?.modifiers ?? .none, skill: skill)
    }
    func isVisible(_ t: Trail) -> Bool {
        filter.matches(trail: t, rating: effectiveRating(t), state: state(for: t.id), isReady: readiness(for: t.id).kind == .ready)
    }
    var visibleTrails: [Trail] { catalog.trails.filter(isVisible) }
    var doneCount: Int { catalog.trails.filter { state(for: $0.id).isDone }.count }
    /// Pending bucket items in manual order (the order `moveBucket` offsets refer to).
    var bucketPending: [Trail.ID] { userData.bucketOrder.filter { state(for: $0).status == .bucket } }
    /// Sidebar badge: pending bucket ids that exist in the catalog (stale ids are ignored).
    var bucketBadgeCount: Int { bucketPending.filter { trailsByID[$0] != nil }.count }
    var bucketCrossedOff: [Trail.ID] {
        catalog.trails.map(\.id).filter { let s = state(for: $0); return s.isDone && s.bucketedAt != nil }
            .sorted { (state(for: $0).lastDoneDate ?? .distantPast) > (state(for: $1).lastDoneDate ?? .distantPast) }
    }
    var skiDays: [SkiDay] { SkiDay.group(userData.runLog, meta: userData.skiDays) }

    private func name(of id: Trail.ID) -> String { trailsByID[id]?.name ?? id }

    // MARK: mutations
    func markDone(_ id: Trail.ID, on date: Date = .now, backfilled: Bool = false) {
        markDone(ids: [id], on: date, backfilled: backfilled)
    }
    func markDone(_ ids: [Trail.ID], backfilled: Bool) { markDone(ids: ids, backfilled: backfilled) }

    /// Bulk and single path. One mutation = one undo step; one toast.
    func markDone(ids: [Trail.ID], on date: Date = .now, backfilled: Bool = false) {
        let unique = ids.reduce(into: [Trail.ID]()) { if !$0.contains($1) { $0.append($1) } }
        guard !unique.isEmpty else { return }
        let wasBucketed = unique.count == 1 ? state(for: unique[0]).bucketedAt != nil : false
        let loggedToday = unique.count == 1 ? hasRun(userData, trail: unique[0], on: date) : true
        let eloBefore = elo
        let before = revision
        let achieved = mutate(unique.count == 1 ? "Mark Done" : "Mark \(unique.count) Trails Done") { d in
            for id in unique { Self.applyDone(&d, id: id, date: date, backfilled: backfilled) }
        }
        guard revision != before, !backfilled else { return }
        Haptics.success()
        if unique.count == 1 {
            let id = unique[0]
            lastStatusChange = StatusChange(trailID: id, badge: .done, revision: revision)
            var actions = [Toast.Action("Undo") { [weak self] in self?.undoManager?.undo() }]
            if !loggedToday { actions.append(Toast.Action("Log run…") { [weak self] in self?.requestLogRun(trailID: id) }) }
            showToast(Toast(kind: wasBucketed ? .bucket : .done,
                            text: (wasBucketed ? "★ \(name(of: id)) crossed off your bucket list" : "✓ \(name(of: id)) crossed off") + eloSuffix(since: eloBefore),
                            symbol: wasBucketed ? "star.fill" : "checkmark.circle.fill", actions: actions))
        } else {
            lastStatusChange = StatusChange(trailID: unique[unique.count - 1], badge: .done, revision: revision)
            showToast(Toast(kind: .done, text: "\(unique.count) trails marked done" + eloSuffix(since: eloBefore), symbol: "checkmark.circle.fill",
                            actions: [Toast.Action("Undo") { [weak self] in self?.undoManager?.undo() }]))
        }
        showMilestoneToasts(achieved)
    }

    func markNotDone(_ id: Trail.ID) {
        guard state(for: id).isDone else { return }
        mutate("Mark Not Done") { d in
            var s = d.state(for: id)
            s.status = s.bucketedAt != nil ? .bucket : .notDone
            s.firstDoneDate = nil; s.lastDoneDate = nil; s.backfilled = false
            s.timesSkied = d.runLog.filter { $0.trailID == id }.count
            d.trailStates[id] = s.isEmpty ? nil : s
            d.eloEvents.removeAll { $0.trailID == id && $0.source == .markDone }
        }
        lastStatusChange = StatusChange(trailID: id, badge: state(for: id).bucketedAt != nil ? .bucket : .none, revision: revision)
        showToast(Toast(kind: .info, text: "\(name(of: id)) marked not done", symbol: "arrow.uturn.backward.circle",
                        actions: [Toast.Action("Undo") { [weak self] in self?.undoManager?.undo() }]))
    }
    func toggleDone(_ id: Trail.ID) { state(for: id).isDone ? markNotDone(id) : markDone(id) }

    /// "Ran it again": one more run of a trail, counted for Elo every time (even the same day).
    /// On a trail that isn't done yet this is the same as `markDone`.
    func recordAnotherRun(_ id: Trail.ID, on date: Date = .now) {
        guard state(for: id).isDone else { markDone(id, on: date); return }
        let eloBefore = elo
        let achieved = mutate("Ran It Again") { d in
            var s = d.state(for: id)
            s.timesSkied += 1
            s.lastDoneDate = max(s.lastDoneDate ?? date, date)
            d.trailStates[id] = s
            d.eloEvents.append(EloEvent(trailID: id, date: date, score: 1, source: .markDone))
        }
        Haptics.success()
        lastStatusChange = StatusChange(trailID: id, badge: .done, revision: revision)
        showToast(Toast(kind: .done, text: "↻ \(name(of: id)) again" + eloSuffix(since: eloBefore), symbol: "arrow.clockwise.circle.fill",
                        actions: [Toast.Action("Undo") { [weak self] in self?.undoManager?.undo() }]))
        showMilestoneToasts(achieved)
    }

    func addToBucket(_ ids: [Trail.ID]) {
        let before = revision
        let now = Date()
        mutate("Add to Bucket List") { d in
            for id in ids {
                var s = d.state(for: id)
                if s.bucketedAt == nil { s.bucketedAt = now }
                if s.status == .notDone { s.status = .bucket }
                d.trailStates[id] = s
                if !d.bucketOrder.contains(id) { d.bucketOrder.append(id) }
            }
        }
        guard revision != before else { return }
        if ids.count == 1 { lastStatusChange = StatusChange(trailID: ids[0], badge: state(for: ids[0]).isDone ? .done : .bucket, revision: revision) }
        showToast(Toast(kind: .bucket, text: ids.count > 1 ? "★ Added \(ids.count) trails to bucket list" : "★ Added to bucket list", symbol: "star.fill",
                        actions: [Toast.Action("Undo") { [weak self] in self?.undoManager?.undo() }]))
    }
    func removeFromBucket(_ id: Trail.ID) {
        mutate("Remove from Bucket List") { d in
            var s = d.state(for: id)
            s.bucketedAt = nil
            if s.status == .bucket { s.status = .notDone }
            d.trailStates[id] = s.isEmpty ? nil : s
            d.bucketOrder.removeAll { $0 == id }
        }
        lastStatusChange = StatusChange(trailID: id, badge: state(for: id).isDone ? .done : .none, revision: revision)
    }
    func toggleBucket(_ id: Trail.ID) { state(for: id).bucketedAt == nil ? addToBucket([id]) : removeFromBucket(id) }

    /// `from`/`to` are offsets into `bucketPending` (SwiftUI `onMove` semantics). Crossed-off ids
    /// keep their relative order after the pending items.
    func moveBucket(from: IndexSet, to: Int) {
        mutate("Reorder Bucket List") { d in
            var pending = d.bucketOrder.filter { d.state(for: $0).status == .bucket }
            let rest = d.bucketOrder.filter { d.state(for: $0).status != .bucket }
            pending.move(fromOffsets: from, toOffset: to)
            d.bucketOrder = pending + rest
        }
    }

    func logRun(_ entry: RunLogEntry, alsoMarkDone: Bool) {
        var e = entry
        e.isFirstTime = !userData.runLog.contains { $0.trailID == entry.trailID }
        let wasDone = state(for: e.trailID).isDone
        let eloBefore = elo
        let achieved = mutate("Log Run") { d in
            d.runLog.append(e)
            d.eloEvents.append(EloEvent(trailID: e.trailID, date: e.date, score: Elo.score(confidence: e.confidence), source: .logRun, runID: e.id))
            var s = d.state(for: e.trailID); s.timesSkied += 1; d.trailStates[e.trailID] = s
            if alsoMarkDone && !wasDone { Self.applyDone(&d, id: e.trailID, date: e.date, backfilled: false) }
        }
        if alsoMarkDone && !wasDone {
            Haptics.success()
            lastStatusChange = StatusChange(trailID: e.trailID, badge: .done, revision: revision)
        }
        showToast(Toast(kind: .info, text: "Run logged" + eloSuffix(since: eloBefore), symbol: "book.closed.fill",
                        actions: [Toast.Action("Undo") { [weak self] in self?.undoManager?.undo() }]))
        showMilestoneToasts(achieved)
    }
    func updateRun(_ entry: RunLogEntry) {
        mutate("Edit Run") { d in
            if let i = d.runLog.firstIndex(where: { $0.id == entry.id }) { d.runLog[i] = entry }
            if let j = d.eloEvents.firstIndex(where: { $0.runID == entry.id }) {
                d.eloEvents[j].trailID = entry.trailID; d.eloEvents[j].date = entry.date
                d.eloEvents[j].score = Elo.score(confidence: entry.confidence)
            }
        }
    }
    func deleteRun(_ id: UUID) {
        mutate("Delete Run") { d in
            d.runLog.removeAll { $0.id == id }
            d.eloEvents.removeAll { $0.runID == id }
        }
    }
    func setSkiDayMeta(_ key: String, _ meta: SkiDayMeta) { mutate("Edit Ski Day") { $0.skiDays[key] = meta } }
    func setOverride(_ id: Trail.ID, rating: Int?, note: String?) {
        mutate("Override Rating") { d in
            var s = d.state(for: id)
            s.ratingOverride = rating.map { min(max($0, 1), 100) }
            s.ratingOverrideNote = rating == nil ? nil : note
            d.trailStates[id] = s.isEmpty ? nil : s
        }
    }
    func setNotes(_ id: Trail.ID, _ text: String) {
        mutate("Edit Notes") { d in var s = d.state(for: id); s.notes = text; d.trailStates[id] = s.isEmpty ? nil : s }
    }
    func completeOnboarding(selfAssessed: Int, backfill: Set<Band>) {
        let ids = catalog.trails.filter { backfill.contains(Band.of($0.rating.total)) }.map(\.id)
        let now = Date()
        mutate("Onboarding") { d in
            d.profile.selfAssessedStart = selfAssessed; d.profile.onboardingDone = true; d.profile.startDate = now
            for id in ids { Self.applyDone(&d, id: id, date: now, backfilled: true) }
        }
        showOnboarding = false
    }
    func replaceUserData(_ data: UserData, actionName: String) { mutate(actionName) { $0 = data } }
    func resetAllUserData() { replaceUserData(.fresh(), actionName: "Reset All Data") }

    /// Import entry point for the menu command: flushes, writes `userdata.pre-import-<ts>.json`,
    /// then replaces or merges as one undo step.
    func applyImport(_ imported: UserData, mode: ImportMode) {
        persistence?.flush()
        do { try persistence?.writePreImportBackup(userData) } catch {
            pendingAlert = StoreAlert(title: "Could not back up current data", message: error.localizedDescription)
            return
        }
        switch mode {
        case .replace: replaceUserData(imported, actionName: "Import Data")
        case .merge: replaceUserData(ExportImport.merge(local: userData, imported: imported), actionName: "Merge Data")
        }
        showToast(Toast(kind: .info, text: mode == .replace ? "Data imported" : "Data merged", symbol: "square.and.arrow.down",
                        actions: [Toast.Action("Undo") { [weak self] in self?.undoManager?.undo() }]))
    }
    func flush() { persistence?.flush() }

    // MARK: resorts

    /// Switch the resort being shown. Your Elo, log and bucket list span every resort.
    func switchResort(to id: String) {
        guard id != resortID, let c = catalogs.first(where: { $0.id == id }) else { return }
        catalog = c
        resortID = id
        uiDefaults?.set(id, forKey: "ui.resort")
        selection = nil
        hover = nil
        filter = TrailFilter()
        directions = DirectionsState(difficulty: directions.difficulty)
        shownPlan = nil
        planner = PlannerState(difficulty: planner.difficulty)
        forecast = .idle
        cameraRequest = overviewPreset
    }

    /// The overview camera for the current resort.
    var overviewPreset: CameraPreset { resortID == "heavenly" ? .overview : .camera(resort.overview) }

    /// Which resort a trail belongs to.
    func resortID(of trailID: Trail.ID) -> String {
        catalogs.first { c in c.trails.contains { $0.id == trailID } }?.id ?? resortID
    }

    // MARK: UI helpers
    func select(_ id: Trail.ID?, showInspector: Bool) { selection = id; if id != nil && showInspector { inspectorShown = true } }
    func showOnMap(_ id: Trail.ID) {
        let r = resortID(of: id)
        if r != resortID { switchResort(to: r) }
        section = .map; select(id, showInspector: true); cameraRequest = .fit(id)
    }
    func requestCamera(_ p: CameraPreset) { cameraRequest = p == .overview ? overviewPreset : p }
    func requestLogRun(trailID: Trail.ID?) { logRunRequest = LogRunRequest(trailID: trailID ?? selection) }
    func showToast(_ t: Toast) { toast = t }

    private func showMilestoneToasts(_ ms: [Milestone]) {
        guard let m = ms.first else { return }
        let t = Toast(kind: .milestone, text: "🏅 \(m.title)", symbol: m.symbol, actions: [Toast.Action("Show") { [weak self] in self?.section = .progress }])
        let current = toast
        // The toast slot holds one toast: queue the milestone one behind the status toast.
        DispatchQueue.main.asyncAfter(deadline: .now() + (current?.autoDismissSeconds ?? 0) + 0.2) { [weak self] in
            guard let self, self.toast == nil || self.toast?.id == current?.id else { return }
            self.showToast(t)
        }
    }

    // MARK: pure helpers
    private func hasRun(_ d: UserData, trail id: Trail.ID, on date: Date) -> Bool {
        let key = SkiDay.key(for: date)
        return d.runLog.contains { $0.trailID == id && $0.dayKey == key }
    }

    /// UX §2.4/§7.2 done semantics on a document.
    private static func applyDone(_ d: inout UserData, id: Trail.ID, date: Date, backfilled: Bool) {
        var s = d.state(for: id)
        let key = SkiDay.key(for: date)
        let alreadyToday = s.isDone && s.lastDoneDate.map { SkiDay.key(for: $0) == key } == true
        let runToday = d.runLog.contains { $0.trailID == id && $0.dayKey == key }
        s.firstDoneDate = s.firstDoneDate ?? date
        s.lastDoneDate = max(s.lastDoneDate ?? date, date)
        if !runToday && !alreadyToday {
            s.timesSkied += 1
            // A newly counted run is an Elo "game" (backfilled history only seeds the start).
            if !backfilled { d.eloEvents.append(EloEvent(trailID: id, date: date, score: 1, source: .markDone)) }
        }
        s.backfilled = s.isDone ? (s.backfilled && backfilled) : backfilled
        s.status = .done
        d.trailStates[id] = s
    }

    /// UX §7.2 invariants, enforced after every mutation.
    private func normalize(_ d: inout UserData) {
        for (id, var s) in d.trailStates {
            if s.status == .bucket && s.bucketedAt == nil { s.bucketedAt = d.updatedAt }
            if s.status == .done && s.firstDoneDate == nil { s.firstDoneDate = s.lastDoneDate ?? d.updatedAt }
            if s.status == .done && s.lastDoneDate == nil { s.lastDoneDate = s.firstDoneDate }
            if let o = s.ratingOverride { s.ratingOverride = min(max(o, 1), 100) }
            d.trailStates[id] = s.isEmpty ? nil : s
        }
        var seen = Set<Trail.ID>()
        var order: [Trail.ID] = []
        for id in d.bucketOrder where d.trailStates[id]?.bucketedAt != nil && seen.insert(id).inserted { order.append(id) }
        let missing = d.trailStates.filter { $0.value.status == .bucket && !seen.contains($0.key) }
            .sorted { ($0.value.bucketedAt ?? .distantPast, $0.key) < ($1.value.bucketedAt ?? .distantPast, $1.key) }
        order += missing.map(\.key)
        d.bucketOrder = order
    }

    // MARK: core mutation path
    @discardableResult
    private func mutate(_ actionName: String, _ body: (inout UserData) -> Void) -> [Milestone] {
        let before = userData
        var d = before
        body(&d)
        d.updatedAt = .now
        normalize(&d)
        let skillInputsChanged = d.runLog != before.runLog || d.trailStates != before.trailStates || d.eloEvents != before.eloEvents
            || d.profile.selfAssessedStart != before.profile.selfAssessedStart || d.profile.startDate != before.profile.startDate
        if skillInputsChanged {
            d.profile.skillHistory = skillHistory(for: d)
        }
        var achieved: [Milestone] = []
        if skillInputsChanged || d.profile.onboardingDone != before.profile.onboardingDone {
            achieved = MilestoneRegistry.newlyAchieved(in: MilestoneContext(userData: d, catalog: catalog, ratings: ratings(for: d)))
            let now = Date()
            for m in achieved { d.profile.unlockedMilestones[m.id] = now }
        }
        // A mutation that changes nothing (ignoring the timestamp) is not an undo step.
        var cmp = d; cmp.updatedAt = before.updatedAt
        if cmp == before { return [] }
        commit(d, previous: before, actionName: actionName)
        return achieved
    }

    private func commit(_ d: UserData, previous: UserData, actionName: String) {
        userData = d
        revision += 1
        persistence?.scheduleSave(d)
        registerUndo(actionName) { s in s.restore(previous, redoTo: d, actionName: actionName) }
    }

    private func restore(_ snapshot: UserData, redoTo: UserData, actionName: String) {
        let current = userData
        var d = snapshot
        d.updatedAt = .now
        userData = d
        revision += 1
        persistence?.scheduleSave(d)
        registerUndo(actionName) { s in s.restore(current, redoTo: d, actionName: actionName) }
    }

    private func registerUndo(_ actionName: String, _ handler: @escaping @MainActor (AppStore) -> Void) {
        guard let um = undoManager else { return }
        // Outside an event-loop group (e.g. tests) make each mutation its own undo step, unless the
        // caller opened a group on purpose or we are mid undo/redo.
        let needsGroup = um.groupingLevel == 0 && !um.isUndoing && !um.isRedoing
        if needsGroup { um.beginUndoGrouping() }
        um.registerUndo(withTarget: self) { s in MainActor.assumeIsolated { handler(s) } }
        if !um.isUndoing && !um.isRedoing { um.setActionName(actionName) }
        if needsGroup { um.endUndoGrouping() }
    }
}

extension TrailCatalog {
    /// Placeholder when the bundled catalog cannot be loaded (or no account is signed in).
    static var empty: TrailCatalog {
        TrailCatalog(schemaVersion: 1, resort: "Heavenly Mountain Resort", generatedAt: "", source: Provenance(osm: "", license: "", osmTimestamp: "", elevation: "", pipeline: "", modifiersVersion: ""), ratingEngineVersion: DifficultyRating.version, bounds: GeoBounds(minLat: 38.914, minLon: -119.943, maxLat: 38.966, maxLon: -119.881), trails: [], connectors: [], lifts: [], boundary: [])
    }
}

/// One "you did it" tap: trackpad haptic on the Mac, success feedback on iPhone.
@MainActor
enum Haptics {
    static func success() {
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        #elseif os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}
