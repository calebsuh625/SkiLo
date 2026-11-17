import SwiftUI

/// "Me": account, Elo, the run log and account settings.
struct PhoneProfileView: View {
    @Environment(AccountManager.self) private var accounts
    @Environment(AppStore.self) private var store
    @State private var sheet: Sheet?
    @State private var confirmDelete = false
    enum Sheet: Identifiable { case rename, password; var id: Self { self } }

    var body: some View {
        NavigationStack {
            List {
                if let me = accounts.current {
                    Section {
                        HStack(spacing: 14) {
                            AccountAvatar(account: me, size: 52)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(me.username).font(.title2.weight(.semibold))
                                EloBadge().font(.subheadline)
                            }
                        }
                        .padding(.vertical, 4)
                        LabeledContent("Trails done", value: "\(store.doneCount) / \(store.catalog.trails.count)")
                        LabeledContent("Runs counted", value: "\(store.eloGames)")
                    }
                }

                Section {
                    if store.skiDays.isEmpty {
                        Text("Runs you log show up here, grouped by day.").foregroundStyle(.secondary)
                    }
                    ForEach(store.skiDays) { day in
                        DisclosureGroup {
                            ForEach(day.entries) { e in runRow(e) }
                        } label: {
                            HStack {
                                Text(Format.date(day.date))
                                Spacer()
                                Text("\(day.entries.count) run\(day.entries.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Run log")
                        Spacer()
                        Button("Log Run…") { store.requestLogRun(trailID: nil) }.font(.caption.weight(.semibold)).textCase(nil)
                    }
                }

                Section("Account") {
                    Button("Change Username…") { sheet = .rename }
                    Button("Change Password…") { sheet = .password }
                    Button("Sign Out") { accounts.signOut() }
                    Button("Delete Account…", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle("Me")
            .sheet(item: $sheet) { which in
                if let me = accounts.current {
                    switch which {
                    case .rename: RenameSheet(account: me).presentationDetents([.height(220)])
                    case .password: ChangePasswordSheet(account: me).presentationDetents([.height(320)])
                    }
                }
            }
            .confirmationDialog("Delete this account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Account", role: .destructive) {
                    if let id = accounts.current?.id {
                        do { try accounts.deleteAccount(id) } catch { accounts.lastError = error.localizedDescription }
                    }
                }
            } message: {
                Text("Its trails, run log and Elo are permanently deleted from this iPhone.")
            }
        }
    }

    private func runRow(_ e: RunLogEntry) -> some View {
        HStack {
            if let t = store.trail(e.trailID) {
                RatingPill(rating: store.effectiveRating(t), size: .caption).frame(width: 34)
                VStack(alignment: .leading) {
                    Text(t.name)
                    Text("\(Format.time(e.date)) · \(e.conditions.label) · confidence \(e.confidence)/5")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(e.trailID).foregroundStyle(.secondary)
            }
        }
        .swipeActions {
            Button(role: .destructive) { store.deleteRun(e.id) } label: { Label("Delete", systemImage: "trash") }
        }
    }
}
