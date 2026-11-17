import AppKit
import MapKit
import QuartzCore

/// Midpoint status badge (DESIGN §8.5). Present only while the trail's badge is not `.none`.
final class BadgeAnnotation: NSObject, MKAnnotation {
    let trailID: Trail.ID
    let coordinate: CLLocationCoordinate2D
    var badge: TrailStyle.Badge
    init(trailID: Trail.ID, coordinate: CLLocationCoordinate2D, badge: TrailStyle.Badge) {
        self.trailID = trailID; self.coordinate = coordinate; self.badge = badge
    }
}

/// The selected trail's floating name label.
final class LabelAnnotation: NSObject, MKAnnotation {
    let trailID: Trail.ID
    let coordinate: CLLocationCoordinate2D
    let text: String
    init(trailID: Trail.ID, coordinate: CLLocationCoordinate2D, text: String) {
        self.trailID = trailID; self.coordinate = coordinate; self.text = text
    }
}

/// 18 pt disc: checkmark on #34C759 (done) or yellow star on dark (bucket). Drawn into a centred
/// sublayer so the pop animation can scale around the centre.
final class BadgeView: MKAnnotationView {
    static let reuseID = "badge"
    static let size: CGFloat = 18
    let disc = CALayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
        wantsLayer = true
        disc.frame = bounds
        disc.contentsGravity = .resizeAspect
        layer?.addSublayer(disc)
        displayPriority = .required
        collisionMode = .circle
        canShowCallout = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(_ badge: TrailStyle.Badge) {
        disc.contentsScale = window?.backingScaleFactor ?? 2
        disc.contents = Self.image(for: badge)
        isHidden = badge == .none
    }

    static func image(for badge: TrailStyle.Badge) -> NSImage? {
        guard badge != .none else { return nil }
        let s = size
        return NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            let disc = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            (badge == .done ? Ramp.doneGreen.nsColor : NSColor(white: 0.11, alpha: 0.92)).setFill()
            disc.fill()
            NSColor.white.setStroke(); disc.lineWidth = 1.5; disc.stroke()
            let name = badge == .done ? "checkmark" : "star.fill"
            let tint = badge == .done ? NSColor.white : Ramp.bucketYellow.nsColor
            let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .heavy).applying(.init(paletteColors: [tint]))
            if let g = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let gs = g.size
                g.draw(in: NSRect(x: rect.midX - gs.width / 2, y: rect.midY - gs.height / 2, width: gs.width, height: gs.height))
            }
            return true
        }
    }
}

/// Rounded dark pill with the trail label, floating above the midpoint.
final class TrailLabelView: MKAnnotationView {
    static let reuseID = "label"
    private let field = NSTextField(labelWithString: "")

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.82).cgColor
        layer?.cornerRadius = 7
        layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        layer?.borderWidth = 1
        field.font = .systemFont(ofSize: 12, weight: .semibold)
        field.textColor = .white
        field.drawsBackground = false
        addSubview(field)
        displayPriority = .required
        collisionMode = .rectangle
        canShowCallout = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(_ text: String) {
        field.stringValue = text
        field.sizeToFit()
        let w = ceil(field.frame.width) + 16, h = ceil(field.frame.height) + 6
        frame = NSRect(x: 0, y: 0, width: w, height: h)
        field.frame.origin = NSPoint(x: 8, y: 3)
        // Above the badge disc (18 pt) with a small gap. centerOffset is in flipped view coordinates.
        centerOffset = CGPoint(x: 0, y: -(h / 2 + 14))
    }
}

extension MapKitEngine {
    func annotationView(for annotation: MKAnnotation) -> MKAnnotationView? {
        let m = mapView
        if let a = annotation as? ProbeAnnotation {
            let v = m.dequeueReusableAnnotationView(withIdentifier: ProbeView.reuseID) ?? ProbeView(annotation: a, reuseIdentifier: ProbeView.reuseID)
            v.annotation = a
            return v
        }
        if let a = annotation as? BadgeAnnotation {
            let v = (m.dequeueReusableAnnotationView(withIdentifier: BadgeView.reuseID) as? BadgeView)
                ?? BadgeView(annotation: a, reuseIdentifier: BadgeView.reuseID)
            v.annotation = a
            v.configure(a.badge)
            v.zPriority = .defaultUnselected
            return v
        }
        if let a = annotation as? LabelAnnotation {
            let v = (m.dequeueReusableAnnotationView(withIdentifier: TrailLabelView.reuseID) as? TrailLabelView)
                ?? TrailLabelView(annotation: a, reuseIdentifier: TrailLabelView.reuseID)
            v.annotation = a
            v.configure(a.text)
            v.zPriority = .max
            return v
        }
        return nil
    }

    /// Adds, updates or removes the badge annotation after a style change.
    func updateBadge(_ id: Trail.ID, old: TrailStyle.Badge) {
        let new = lastStyles[id]?.badge ?? .none
        if new == .none {
            if let a = badgeAnnotations.removeValue(forKey: id) { mapView.removeAnnotation(a) }
            return
        }
        if let a = badgeAnnotations[id] {
            guard a.badge != new else { return }
            a.badge = new
            (mapView.view(for: a) as? BadgeView)?.configure(new)
            return
        }
        guard let t = scene?.trails.first(where: { $0.id == id }) else { return }
        let a = BadgeAnnotation(trailID: id, coordinate: t.midpoint.clCoordinate, badge: new)
        badgeAnnotations[id] = a
        mapView.addAnnotation(a)
    }

    /// Keeps exactly one label annotation for the selected trail (text from its style, else its name).
    func updateLabel() {
        var want: (Trail.ID, String, CLLocationCoordinate2D)?
        if let id = selectedID, let t = scene?.trails.first(where: { $0.id == id }) {
            want = (id, lastStyles[id]?.label ?? t.name, t.midpoint.clCoordinate)
        }
        if let cur = labelAnnotation, let w = want, cur.trailID == w.0, cur.text == w.1 { return }
        if let cur = labelAnnotation { mapView.removeAnnotation(cur); labelAnnotation = nil }
        if let w = want {
            let a = LabelAnnotation(trailID: w.0, coordinate: w.2, text: w.1)
            labelAnnotation = a
            mapView.addAnnotation(a)
        }
    }

    /// Badge pop: scale 0 → 1.3 → 1.0 over 0.45 s (DESIGN §8.8).
    static func pop(_ v: MKAnnotationView) {
        guard let disc = (v as? BadgeView)?.disc else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.scale")
        a.values = [0.0, 1.3, 1.0]
        a.keyTimes = [0, 0.55, 1]
        a.duration = 0.45
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        disc.add(a, forKey: "pop")
    }
}
