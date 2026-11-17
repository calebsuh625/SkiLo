import Foundation

struct ImportSummary: Equatable { var doneCount: Int; var runCount: Int; var bucketCount: Int; var earliestDate: Date? }

enum ImportMode { case replace, merge }

enum ExportImport {
    static func summary(of d: UserData) -> ImportSummary {
        let dates = d.trailStates.values.compactMap(\.firstDoneDate) + d.runLog.map(\.date)
        return ImportSummary(doneCount: d.trailStates.values.filter(\.isDone).count, runCount: d.runLog.count,
                             bucketCount: d.trailStates.values.filter { $0.status == .bucket }.count, earliestDate: dates.min())
    }

    /// The same document as `userdata.json` plus a top-level `"exportedAt"` (ISO-8601).
    static func exportData(_ data: UserData, exportedAt: Date = .now) throws -> Data {
        var doc = data
        doc.trailStates = doc.trailStates.filter { !$0.value.isEmpty }
        let encoded = try UserDataStore.encode(doc)
        guard var dict = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { throw MigrationError.notAnObject }
        dict["exportedAt"] = ISO8601DateFormatter().string(from: exportedAt)
        return try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    }
    static func export(_ data: UserData, to url: URL) throws {
        try exportData(data).write(to: url, options: .atomic)
    }
    static func read(from url: URL) throws -> (UserData, ImportSummary) {
        let d = try UserDataStore.decode(Data(contentsOf: url))
        return (d, summary(of: d))
    }

    /// UX §7.8 merge. Local wins on conflicts that have no merge rule.
    static func merge(local: UserData, imported: UserData) -> UserData {
        var out = local
        out.createdAt = min(local.createdAt, imported.createdAt)

        var log = local.runLog
        let known = Set(log.map(\.id))
        log += imported.runLog.filter { !known.contains($0.id) }
        log.sort { $0.date < $1.date }
        out.runLog = log
        var runCounts: [Trail.ID: Int] = [:]
        for r in log { runCounts[r.trailID, default: 0] += 1 }

        func rank(_ s: TrailStatus) -> Int { switch s { case .notDone: 0; case .bucket: 1; case .done: 2 } }
        func earliest(_ a: Date?, _ b: Date?) -> Date? { [a, b].compactMap { $0 }.min() }
        func latest(_ a: Date?, _ b: Date?) -> Date? { [a, b].compactMap { $0 }.max() }

        var states: [Trail.ID: UserTrailState] = [:]
        for id in Set(local.trailStates.keys).union(imported.trailStates.keys) {
            let l = local.trailStates[id], i = imported.trailStates[id]
            guard let l else { states[id] = i; continue }
            guard let i else { states[id] = l; continue }
            var s = l
            s.status = rank(i.status) > rank(l.status) ? i.status : l.status
            s.bucketedAt = earliest(l.bucketedAt, i.bucketedAt)
            s.firstDoneDate = earliest(l.firstDoneDate, i.firstDoneDate)
            s.lastDoneDate = latest(l.lastDoneDate, i.lastDoneDate)
            s.timesSkied = max(runCounts[id] ?? 0, l.timesSkied, i.timesSkied)
            s.backfilled = l.backfilled && i.backfilled
            s.ratingOverride = l.ratingOverride ?? i.ratingOverride
            s.ratingOverrideNote = l.ratingOverride != nil ? l.ratingOverrideNote : (i.ratingOverrideNote ?? l.ratingOverrideNote)
            if l.notes.isEmpty { s.notes = i.notes }
            else if !i.notes.isEmpty && i.notes != l.notes { s.notes = l.notes + "\n---\n" + i.notes }
            s.photoFilenames = l.photoFilenames + i.photoFilenames.filter { !l.photoFilenames.contains($0) }
            states[id] = s
        }
        out.trailStates = states

        out.bucketOrder = local.bucketOrder
        for id in imported.bucketOrder where !out.bucketOrder.contains(id) { out.bucketOrder.append(id) }

        for (k, v) in imported.skiDays where out.skiDays[k] == nil { out.skiDays[k] = v }

        let knownEvents = Set(local.eloEvents.map(\.id))
        out.eloEvents = (local.eloEvents + imported.eloEvents.filter { !knownEvents.contains($0.id) }).sorted { $0.date < $1.date }

        var ms = local.profile.unlockedMilestones
        for (k, v) in imported.profile.unlockedMilestones { ms[k] = min(ms[k] ?? v, v) }
        out.profile.unlockedMilestones = ms
        out.profile.onboardingDone = local.profile.onboardingDone || imported.profile.onboardingDone
        return out
    }
}
