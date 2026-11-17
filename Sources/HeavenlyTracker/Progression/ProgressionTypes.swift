import Foundation

struct SkillEstimate: Equatable, Sendable {
    var value: Double
    var low: Double
    var high: Double
    var basisRuns: Int
    var isProvisional: Bool { basisRuns < 3 }
    var rounded: Int { Int(value.rounded()) }
}

struct Readiness: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case belowYou, ready, stretch, bigStretch }
    var kind: Kind
    var delta: Int            // rating − round(skill)
    var reason: String
}

protocol ProgressionEngine: Sendable {
    /// Relative to the skill estimate, e.g. -7...7.
    var readyWindow: ClosedRange<Int> { get }
    func skillHistory(profile: UserProfile, log: [RunLogEntry], ratings: [Trail.ID: Int]) -> [SkillPoint]
    func currentSkill(history: [SkillPoint], profile: UserProfile) -> SkillEstimate
    func readiness(rating: Int, modifiers: CuratedModifiers, skill: SkillEstimate) -> Readiness
    func readyFor(trails: [Trail], ratings: [Trail.ID: Int], states: [Trail.ID: UserTrailState], skill: SkillEstimate, limit: Int) -> [Trail.ID]
    func suggestedNext(bucket: [Trail.ID], trails: [Trail.ID: Trail], ratings: [Trail.ID: Int], states: [Trail.ID: UserTrailState], skill: SkillEstimate) -> (id: Trail.ID, reason: String)?
}

enum MilestoneEvaluation: Equatable, Sendable { case locked(fraction: Double?), achieved }

struct MilestoneContext: Sendable {
    let userData: UserData
    let catalog: TrailCatalog
    let ratings: [Trail.ID: Int]       // effective ratings
}

struct Milestone: Identifiable, Sendable {
    let id: String                     // e.g. "first.green", "trail.gunbarrel", "area.bothStates", "count.25"
    let title: String
    let symbol: String                 // SF Symbol
    let detail: String                 // predicate in words
    let evaluate: @Sendable (MilestoneContext) -> MilestoneEvaluation
}
