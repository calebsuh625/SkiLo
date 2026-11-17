import Foundation

struct TrailFilter: Equatable, Hashable, Codable, Sendable {
    var areas: Set<Area> = Set(Area.allCases)
    var subAreas: Set<SubArea>? = nil
    var ratingRange: ClosedRange<Int> = 1...100
    var statuses: Set<TrailStatus> = Set(TrailStatus.allCases)
    var grooming: Set<Grooming>? = nil
    var gladedOnly: Bool = false
    var readyForMe: Bool = false
    var searchText: String = ""

    init() {}
    init(searchText: String) { self.searchText = searchText }
    var isActive: Bool { self != TrailFilter(searchText: searchText) }

    /// Pure predicate; `isReady` comes from the progression engine.
    func matches(trail: Trail, rating: Int, state: UserTrailState, isReady: Bool) -> Bool {
        guard areas.contains(trail.area) else { return false }
        if let s = subAreas, !s.contains(trail.subArea) { return false }
        guard ratingRange.contains(rating) else { return false }
        guard statuses.contains(state.status) else { return false }
        if let g = grooming, !g.contains(trail.grooming) { return false }
        if gladedOnly && !trail.gladed { return false }
        if readyForMe && !isReady { return false }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty && !trail.name.localizedCaseInsensitiveContains(q) { return false }
        return true
    }
}
