import SwiftUI

/// Shown while signed out: sign in, or create an account (username + password).
struct AccountGateView: View {
    enum Mode { case signIn, create }
    @Environment(AccountManager.self) private var accounts
    @State private var mode: Mode = .signIn
    @State private var username = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var remember = true
    @State private var error: String?
    @FocusState private var focus: Field?
    enum Field { case username, password, confirm }

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && (mode == .signIn || !confirm.isEmpty)
    }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Image(systemName: "figure.skiing.downhill").font(.system(size: 44)).foregroundStyle(.tint)
                Text("SkiLo").font(.largeTitle.weight(.bold))
                Text(mode == .signIn ? "Sign in to track your runs and Elo." : "Create an account to start tracking.")
                    .font(.title3).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .usernameInput()
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .password }
                SecureField("Password", text: $password)
                    .textContentType(mode == .signIn ? .password : .newPassword)
                    .focused($focus, equals: .password)
                    .onSubmit { mode == .create ? (focus = .confirm) : submit() }
                if mode == .create {
                    SecureField("Confirm password", text: $confirm)
                        .textContentType(.newPassword)
                        .focused($focus, equals: .confirm)
                        .onSubmit(submit)
                }
                Toggle("Remember me", isOn: $remember)
                    .help("Stay signed in when SkiLo is reopened")
                if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                Button(action: submit) {
                    Text(mode == .signIn ? "Sign In" : "Create Account").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 320)

            HStack(spacing: 4) {
                Text(mode == .signIn ? "New to SkiLo?" : "Already have an account?").foregroundStyle(.secondary)
                Button(mode == .signIn ? "Create an account" : "Sign in") {
                    mode = mode == .signIn ? .create : .signIn
                    error = nil; password = ""; confirm = ""
                    focus = .username
                }
                .linkButtonStyle()
            }
            .font(.callout)

            Text("Accounts are stored on this Mac only.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if accounts.accounts.isEmpty { mode = .create }
            focus = .username
        }
    }

    private func submit() {
        guard canSubmit else { return }
        do {
            switch mode {
            case .signIn:
                try accounts.signIn(username: username, password: password, remember: remember)
            case .create:
                guard password == confirm else { error = "The passwords don’t match."; return }
                try accounts.createAccount(username: username, password: password, remember: remember)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
            password = ""; confirm = ""
            focus = .password
        }
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

/// Sidebar header: current account, Elo, and a menu to rename / change password / sign out.
struct AccountHeader: View {
    @Environment(AccountManager.self) private var accounts
    @Environment(AppStore.self) private var store
    @State private var sheet: Sheet?
    @State private var confirmDelete = false
    enum Sheet: Identifiable { case rename, password; var id: Self { self } }

    var body: some View {
        if let me = accounts.current {
            Menu {
                Section("Signed in as \(me.username)") {
                    Button("Change Username…") { sheet = .rename }
                    Button("Change Password…") { sheet = .password }
                }
                Divider()
                Button("Switch Account…") { accounts.signOut() }
                Button("Sign Out") { accounts.signOut() }
                Divider()
                Button("Delete Account…", role: .destructive) { confirmDelete = true }
            } label: {
                HStack(spacing: 10) {
                    AccountAvatar(account: me, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(me.username).font(.headline).lineLimit(1)
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
            .sheet(item: $sheet) { which in
                switch which {
                case .rename: RenameSheet(account: me)
                case .password: ChangePasswordSheet(account: me)
                }
            }
            .confirmationDialog("Delete “\(me.username)”?", isPresented: $confirmDelete) {
                Button("Move to Trash", role: .destructive) {
                    do { try accounts.deleteAccount(me.id) } catch { accounts.lastError = error.localizedDescription }
                }
            } message: {
                Text("Its trails, log and Elo are moved to the Trash. You can restore the folder from the Trash until you empty it.")
            }
        }
    }
}

struct RenameSheet: View {
    let account: Account
    @Environment(AccountManager.self) private var accounts
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change username").font(.headline)
            TextField("Username", text: $name).usernameInput().textFieldStyle(.roundedBorder).frame(width: 260).onSubmit(save)
            if let error { Text(error).font(.caption).foregroundStyle(.red).frame(width: 260, alignment: .leading) }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save", action: save).keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .onAppear { name = account.username }
    }
    private func save() {
        do { try accounts.rename(account.id, to: name); dismiss() } catch { self.error = error.localizedDescription }
    }
}

struct ChangePasswordSheet: View {
    let account: Account
    @Environment(AccountManager.self) private var accounts
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Change password").font(.headline)
            Group {
                SecureField("Current password", text: $current).textContentType(.password)
                SecureField("New password", text: $new).textContentType(.newPassword)
                SecureField("Confirm new password", text: $confirm).textContentType(.newPassword).onSubmit(save)
            }
            .textFieldStyle(.roundedBorder).frame(width: 260)
            if let error { Text(error).font(.caption).foregroundStyle(.red).frame(width: 260, alignment: .leading) }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save", action: save).keyboardShortcut(.defaultAction) }
        }
        .padding(20)
    }
    private func save() {
        guard new == confirm else { error = "The new passwords don’t match."; return }
        do { try accounts.changePassword(account.id, current: current, new: new); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

/// "Elo 31.4 ▲0.8" — the latest change is shown next to the number.
struct EloBadge: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        HStack(spacing: 4) {
            Text("Elo \(Elo.format(store.elo))").monospacedDigit()
            if store.eloIsProvisional { Text("est.") }
            if let d = store.lastEloDelta, let text = Elo.formatDelta(d) {
                Text((d > 0 ? "▲" : "▼") + text.dropFirst())
                    .foregroundStyle(d > 0 ? Color.green : Color.red)
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Elo \(Elo.format(store.elo))\(store.eloIsProvisional ? ", estimated" : "")")
    }
}

extension View {
    /// Usernames: no auto-capitalisation or autocorrect on iPhone.
    @ViewBuilder func usernameInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self
        #endif
    }
}
