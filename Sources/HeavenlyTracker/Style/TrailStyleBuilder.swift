import Foundation

struct StyleContext: Hashable {
    var isVisible: Bool          // passes TrailFilter
    var isSelected: Bool
    var isHovered: Bool
    var base: MapBaseStyle
}

enum TrailStyleBuilder {
    static let casingLight = RGBA.white
    static let casingDark = RGBA(hex: "#1C1C1E")

    /// Pure. UX_SPEC §2.2 table. Selected wins over hovered; a filtered-out trail renders dimmed
    /// unless it is selected (then it renders as its status style, selected).
    static func style(rating: Int, status: TrailStatus, name: String, context: StyleContext) -> TrailStyle {
        if !context.isVisible && !context.isSelected {
            return TrailStyle(color: Ramp.dimmedGray, casing: .clear, opacity: 0.15, baseWidth: 1.5, dash: nil,
                              badge: .none, emphasis: .dimmed, label: nil)
        }
        let casing = context.base == .outline ? casingDark : casingLight
        var s: TrailStyle
        switch status {
        case .notDone:
            s = TrailStyle(color: Ramp.color(for: rating), casing: casing, opacity: 1, baseWidth: 2.5, dash: nil, badge: .none, emphasis: .normal, label: nil)
        case .bucket:
            s = TrailStyle(color: Ramp.color(for: rating), casing: Ramp.bucketYellow, opacity: 1, baseWidth: 3.0, dash: nil, badge: .bucket, emphasis: .normal, label: nil)
        case .done:
            s = TrailStyle(color: Ramp.doneColor(for: rating), casing: casing, opacity: 0.55, baseWidth: 2.0, dash: nil, badge: .done, emphasis: .normal, label: nil)
        }
        if context.isSelected {
            s.baseWidth *= 1.8; s.opacity = 1; s.emphasis = .selected; s.label = name
        } else if context.isHovered {
            s.baseWidth *= 1.3; s.emphasis = .hovered
        }
        return s
    }
    /// Convenience over the whole catalog; MainActor because it reads the store.
    @MainActor
    static func styles(for store: AppStore) -> [Trail.ID: TrailStyle] {
        var out: [Trail.ID: TrailStyle] = [:]
        let ratings = store.effectiveRatings
        for t in store.catalog.trails {
            let ctx = StyleContext(isVisible: store.isVisible(t), isSelected: store.selection == t.id,
                                   isHovered: store.hover == t.id, base: store.mapBaseStyle)
            out[t.id] = style(rating: ratings[t.id] ?? t.rating.total, status: store.state(for: t.id).status, name: t.name, context: ctx)
        }
        return out
    }
}
