import SwiftUI
import AppKit

/// Shown while signed out: pick an existing account or create one.
struct AccountGateView: View {
    @Environment(AccountManager.self) private var accounts
    @State private var newName = ""
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Image(systemName: "figure.skiing.downhill").font(.system(size: 44)).foregroundStyle(.tint)
                Text("Heavenly Tracker").font(.largeTitle.weight(.bold))
                Text(accounts.accounts.isEmpty ? "Create an account to start tracking your runs and Elo."
                                               : "Who’s skiing?")
                    .font(.title3).foregroundStyle(.secondary)
            }

            if !accounts.accounts.isEmpty {
                VStack(spacing: 8) {
                    ForEach(accounts.accounts) { a in
                        Button { accounts.signIn(a.id) } label: {
                            HStack(spacing: 12) {
                                AccountAvatar(account: a, size: 34)
                                Text(a.name).font(.headline)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 340)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(accounts.accounts.isEmpty ? "Your name" : "New account").font(.headline)
                HStack {
                    TextField("Name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit(create)
                    Button("Create", action: create)
                        .buttonStyle(.borderedProminent)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Text("Accounts are stored on this Mac. Each one has its own trails, log and Elo.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 340)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { nameFocused = accounts.accounts.isEmpty }
    }

    private func create() {
        do { try accounts.createAccount(name: newName); newName = ""; error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct AccountAvatar: View {
    let account: Account
    var size: CGFloat = 28
    var body: some View {
        let hue = Double(account.id.uuid.0) / 256   // stable across launches
        Text(account.initials)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color(hue: hue, saturation: 0.55, brightness: 0.75)))
            .accessibilityHidden(true)
    }
}

/// Sidebar header: current account, Elo, and a menu to switch / rename / sign out.
struct AccountHeader: View {
    @Environment(AccountManager.self) private var accounts
    @Environment(AppStore.self) private var store
    @State private var renaming = false
    @State private var confirmDelete = false
    @State private var draftName = ""
    @State private var error: String?

    var body: some View {
        if let me = accounts.current {
            Menu {
                Section("Signed in as \(me.name)") {
                    Button("Rename…") { draftName = me.name; error = nil; renaming = true }
                }
                let others = accounts.accounts.filter { $0.id != me.id }
                if !others.isEmpty {
                    Section("Switch account") {
                        ForEach(others) { a in Button(a.name) { accounts.signIn(a.id) } }
                    }
                }
                Divider()
                Button("New Account…") { accounts.signOut() }
                Button("Sign Out") { accounts.signOut() }
                Divider()
                Button("Delete Account…", role: .destructive) { confirmDelete = true }
            } label: {
                HStack(spacing: 10) {
                    AccountAvatar(account: me, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(me.name).font(.headline).lineLimit(1)
                        EloBadge()
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .help("Account")
            .sheet(isPresented: $renaming) { renameSheet(me) }
            .confirmationDialog("Delete “\(me.name)”?", isPresented: $confirmDelete) {
                Button("Move to Trash", role: .destructive) {
                    do { try accounts.deleteAccount(me.id) } catch { accounts.lastError = error.localizedDescription }
                }
            } message: {
                Text("Its trails, log and Elo are moved to the Trash. You can restore the folder from the Trash until you empty it.")
            }
        }
    }

    private func renameSheet(_ me: Account) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename account").font(.headline)
            TextField("Name", text: $draftName).textFieldStyle(.roundedBorder).frame(width: 260).onSubmit { save(me) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { renaming = false }; Button("Save") { save(me) }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
    }
    private func save(_ me: Account) {
        do { try accounts.rename(me.id, to: draftName); renaming = false } catch { self.error = error.localizedDescription }
    }
}

/// "Elo 1,240 ▲12" — the latest change is shown next to the number.
struct EloBadge: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        HStack(spacing: 4) {
            Text("Elo \(store.elo)").monospacedDigit()
            if let d = store.lastEloDelta, d != 0 {
                Text("\(d > 0 ? "▲" : "▼")\(abs(d))")
                    .foregroundStyle(d > 0 ? Color.green : Color.red)
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Elo \(store.elo)")
    }
}
