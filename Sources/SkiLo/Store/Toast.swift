import Foundation

struct Toast: Identifiable, Equatable {
    enum Kind: Equatable { case info, done, bucket, milestone, error }
    struct Action: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let handler: @MainActor () -> Void
        init(_ title: String, _ handler: @escaping @MainActor () -> Void) { self.title = title; self.handler = handler }
        static func == (l: Action, r: Action) -> Bool { l.id == r.id }
    }
    let id = UUID()
    var kind: Kind
    var text: String
    var symbol: String
    var actions: [Action] = []
    var autoDismissSeconds: Double = 3
    init(kind: Kind, text: String, symbol: String, actions: [Action] = [], autoDismissSeconds: Double = 3) {
        self.kind = kind; self.text = text; self.symbol = symbol; self.actions = actions; self.autoDismissSeconds = autoDismissSeconds
    }
}
