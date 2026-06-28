import SwiftUI
import LinkitMacCore

private enum PickerBrand {
    static let amber = Color(red: 0.82, green: 0.42, blue: 0.12)
    static let green = Color(red: 0.36, green: 0.55, blue: 0.34)
}

/// Backs the dedicated "Call on Android" picker window. Loads the phone's contacts and
/// recently dialed numbers (fetched once, kept only in memory) and filters them locally as
/// the user types, so search is instant and the address book never touches disk.
final class CallPickerViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var contacts: [PhonebookContact] = []
    @Published var recentCalls: [PhonebookRecentCall] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var permissions: PhonebookPermissions?

    /// Set by the menu delegate; performs the signed fetch + decrypt on a background thread.
    var loadPhonebook: () throws -> PhonebookResponse = {
        PhonebookResponse(contacts: [], recentCalls: [], permissions: PhonebookPermissions(contacts: false, callLog: false))
    }
    var onDial: (String) -> Void = { _ in }
    var onClose: () -> Void = {}

    static func digits(_ value: String) -> String {
        value.filter { $0.isNumber || $0 == "+" }
    }

    /// True once the typed query holds enough digits to dial directly (no contact match needed).
    var canDialTyped: Bool {
        let count = query.filter(\.isNumber).count
        return count >= 2 && count <= 15
    }

    var filteredRecent: [PhonebookRecentCall] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return recentCalls }
        let queryDigits = Self.digits(trimmed)
        return recentCalls.filter { call in
            if let name = contactName(forNumber: call.number) ?? call.name,
               name.localizedCaseInsensitiveContains(trimmed) {
                return true
            }
            return !queryDigits.isEmpty && Self.digits(call.number).contains(queryDigits)
        }
    }

    var filteredContacts: [PhonebookContact] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return contacts }
        let queryDigits = Self.digits(trimmed)
        return contacts.filter { contact in
            if contact.name.localizedCaseInsensitiveContains(trimmed) { return true }
            return !queryDigits.isEmpty && contact.numbers.contains { Self.digits($0).contains(queryDigits) }
        }
    }

    /// Resolves a recent-call number to a contact name using the address book we already hold,
    /// so recents show names even when the phone's call log didn't cache one.
    func contactName(forNumber number: String) -> String? {
        let target = Self.digits(number)
        guard !target.isEmpty else { return nil }
        return contacts.first { contact in
            contact.numbers.contains { stored in
                let storedDigits = Self.digits(stored)
                if storedDigits == target { return true }
                // Tolerate country-code differences (e.g. +91xxxx vs xxxx).
                return storedDigits.count >= 7 && target.count >= 7 &&
                    (storedDigits.hasSuffix(target) || target.hasSuffix(storedDigits))
            }
        }?.name
    }

    func reload() {
        isLoading = true
        errorMessage = nil
        let work = loadPhonebook
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let book = try work()
                DispatchQueue.main.async {
                    self.contacts = book.contacts
                    self.recentCalls = book.recentCalls
                    self.permissions = book.permissions
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    func dial(_ number: String) {
        let trimmed = number.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onDial(trimmed)
        onClose()
    }
}

struct CallPickerView: View {
    @ObservedObject var model: CallPickerViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 380, height: 480)
        .onAppear {
            model.reload()
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search name or number", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onSubmit { if model.canDialTyped { model.dial(model.query) } }
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            centered {
                ProgressView()
                Text("Loading contacts…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else if let errorMessage = model.errorMessage {
            centered {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 22)).foregroundStyle(.secondary)
                Text("Couldn't load contacts").font(.system(size: 13, weight: .medium))
                Text(errorMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
                Button("Try Again") { model.reload() }.controlSize(.small)
            }
        } else if model.filteredRecent.isEmpty && model.filteredContacts.isEmpty {
            centered {
                Image(systemName: emptyIcon).font(.system(size: 22)).foregroundStyle(.secondary)
                Text(emptyTitle).font(.system(size: 13, weight: .medium))
                Text(emptyHint).font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !model.filteredRecent.isEmpty {
                        sectionHeader("Recent")
                        ForEach(model.filteredRecent) { call in
                            CallRow(
                                title: model.contactName(forNumber: call.number) ?? call.name ?? call.number,
                                subtitle: subtitle(for: call),
                                systemImage: "arrow.up.right",
                                accent: true
                            ) { model.dial(call.number) }
                        }
                    }
                    if !model.filteredContacts.isEmpty {
                        sectionHeader("Contacts")
                        ForEach(model.filteredContacts) { contact in
                            ForEach(contact.numbers, id: \.self) { number in
                                CallRow(
                                    title: contact.name,
                                    subtitle: number,
                                    systemImage: "person.crop.circle",
                                    accent: false
                                ) { model.dial(number) }
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                model.dial(model.query)
            } label: {
                Label("Dial typed number", systemImage: "phone.arrow.up.right")
                    .font(.system(size: 12))
            }
            .disabled(!model.canDialTyped)
            Spacer()
            Button("Cancel") { model.onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 3)
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 8) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func subtitle(for call: PhonebookRecentCall) -> String {
        let when = Self.relativeTime(call.timestampMillis)
        return when.isEmpty ? call.number : "\(call.number) · \(when)"
    }

    private static func relativeTime(_ millis: Int64) -> String {
        guard millis > 0 else { return "" }
        let date = Date(timeIntervalSince1970: Double(millis) / 1000.0)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var emptyIcon: String {
        if model.query.isEmpty, model.permissions?.contacts == false { return "person.crop.circle.badge.questionmark" }
        return "magnifyingglass"
    }

    private var emptyTitle: String {
        if !model.query.isEmpty { return "No matches" }
        if model.permissions?.contacts == false { return "Contacts not shared" }
        return "Nothing here yet"
    }

    private var emptyHint: String {
        if !model.query.isEmpty { return "Type a full number, then “Dial typed number”." }
        let perms = model.permissions
        if perms?.contacts == false && perms?.callLog == false {
            return "On your phone, open Linkit and tap “Enable phone controls” to grant Contacts and Call log — then names and recent calls appear here. Or just type a number."
        }
        if perms?.contacts == false { return "On your phone, open Linkit and grant Contacts to see your address book. Or just type a number." }
        return "Your contacts and recent calls will appear here."
    }
}

private struct CallRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                    .foregroundStyle(accent ? PickerBrand.amber : Color.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "phone.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(PickerBrand.green)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(hovering ? Color.secondary.opacity(0.10) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
