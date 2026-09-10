import SwiftUI

// MARK: - Admin panel

/// The fleet list, presented as a sheet from Settings → Admin. Rows are Cards (not a List) so it keeps the app's
/// look; the list refreshes every 10 s while open and the toggles are optimistic (revert if the server says no).
/// Main-actor so the Task-driven state writes (and the AppSettings nickname write) always land on main.
@MainActor
struct AdminView: View {
    let pw: String
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [FleetDevice] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var refreshing = false
    @State private var renaming: FleetDevice?
    @State private var newName = ""
    @State private var forgetting: FleetDevice?
    @State private var now = Date()
    /// Mutations in flight; while > 0 a refresh keeps the optimistic rows instead of showing a pre-mutation snapshot.
    @State private var pendingEdits = 0

    var onlineCount: Int { devices.filter { $0.isOnline }.count }
    /// Online first, then most recently seen.
    var sorted: [FleetDevice] {
        devices.sorted { a, b in
            if a.isOnline != b.isOnline { return a.isOnline }
            return (a.lastSeen ?? 0) > (b.lastSeen ?? 0)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    if let e = error { errorLine(e) }
                    if loaded && devices.isEmpty && error == nil {
                        Text("No devices have checked in yet.").font(.footnote).foregroundStyle(Theme.dim).padding(.horizontal, 4)
                    }
                    ForEach(sorted) { d in row(d) }
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationTitle("Admin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() }.foregroundStyle(.white) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .foregroundStyle(.white).disabled(refreshing).accessibilityLabel("Refresh")
                }
            }
            .task {
                // Auto-refresh while the sheet is open; cancelled with the view.
                while !Task.isCancelled {
                    await refresh()
                    try? await Task.sleep(for: .seconds(10))
                }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    now = Date()
                }
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") { if let r = renaming { rename(r, to: newName) }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .alert("Forget \(forgetting?.displayName ?? "")?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
                Button("Forget", role: .destructive) { if let f = forgetting { forget(f) }; forgetting = nil }
                Button("Cancel", role: .cancel) { forgetting = nil }
            } message: { Text("The row disappears until that device checks in again.") }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: pieces

    var header: some View {
        HStack(spacing: 8) {
            StatusDot(color: onlineCount > 0 ? Theme.ok : Theme.dim)
            Text("\(onlineCount) online · \(devices.count) total").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted).monospacedDigit()
            Spacer()
            if refreshing { ProgressView().tint(Theme.dim).scaleEffect(0.8) }
        }
        .padding(.horizontal, 4).padding(.bottom, 2)
        .animation(.easeOut(duration: 0.2), value: onlineCount)
    }

    func errorLine(_ e: String) -> some View {
        Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption.weight(.semibold)).foregroundStyle(Theme.danger).padding(.horizontal, 4)
    }

    func row(_ d: FleetDevice) -> some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: d.isPhone ? "iphone" : "desktopcomputer")
                    .font(.title3).foregroundStyle(d.isOnline ? .white : Theme.dim).frame(width: 28).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    nameLine(d)
                    Text(stateLine(d)).font(.footnote).foregroundStyle(d.isOnline ? Theme.muted : Theme.dim)
                    Text(factsLine(d)).font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { d.isEnabled }, set: { setEnabled(d, $0) }))
                    .labelsHidden().tint(Theme.ok)
                    .accessibilityLabel(d.isEnabled ? "Switched on" : "Switched off")
            }
        }
        .contextMenu {
            Button { newName = d.name ?? ""; renaming = d } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { forgetting = d } label: { Label("Forget", systemImage: "trash") }
        }
        .opacity(d.isEnabled ? 1 : 0.7)
    }

    func nameLine(_ d: FleetDevice) -> some View {
        HStack(spacing: 7) {
            StatusDot(color: d.isOnline ? Theme.ok : Theme.dim)
            Text(d.displayName).font(.subheadline.weight(.bold)).lineLimit(1)
            if d.id == Fleet.shared.deviceID {
                Text("this phone").font(.caption2.weight(.semibold)).foregroundStyle(Theme.dim)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.card2).clipShape(Capsule())
            }
        }
    }

    func stateLine(_ d: FleetDevice) -> String {
        let s: String
        switch d.state ?? "idle" {
        case "spoofing":
            let p = d.place ?? ""
            s = p.isEmpty ? "Spoofing" : "Spoofing · \(p)"
        case "connecting": s = "Connecting"
        default: s = "Idle"
        }
        return s + " · " + ago(d.lastSeen)
    }

    func factsLine(_ d: FleetDevice) -> String {
        [d.model, d.os, d.build].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "Just now / 45 s ago / 3 min ago / 2 h ago / 4 d ago" from a millisecond epoch.
    func ago(_ ms: Double?) -> String {
        guard let ms, ms > 0 else { return "never seen" }
        let s = max(0, now.timeIntervalSince1970 - ms / 1000)
        if s < 10 { return "just now" }
        if s < 60 { return "\(Int(s)) s ago" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        return "\(Int(s / 86400)) d ago"
    }

    // MARK: actions

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let list = try await Fleet.shared.devices(pw: pw)
            devices = pendingEdits == 0 ? list : merged(list)
            error = nil
        } catch {
            self.error = "Can't reach the server · \(error.localizedDescription)"
        }
        loaded = true
    }

    /// A GET that was already in flight when a toggle/rename/forget started carries the old state: keep the local
    /// row's `enabled`/`name`, and leave out rows removed locally (a pending Forget). The next refresh reconciles.
    func merged(_ list: [FleetDevice]) -> [FleetDevice] {
        list.compactMap { row -> FleetDevice? in
            guard let local = devices.first(where: { $0.id == row.id }) else { return nil }
            var r = row
            r.enabled = local.enabled
            r.name = local.name
            return r
        }
    }

    /// Optimistic: flip the row now, put it back if the server refuses.
    func setEnabled(_ d: FleetDevice, _ on: Bool) {
        UISelectionFeedbackGenerator().selectionChanged()
        let was = d.isEnabled
        update(d.id) { $0.enabled = on }
        Task {
            pendingEdits += 1
            defer { pendingEdits -= 1 }
            do {
                try await Fleet.shared.toggle(id: d.id, enabled: on, pw: pw)
                error = nil
                // The phone being switched off is this one: make the local state agree right away.
                if d.id == Fleet.shared.deviceID { await Fleet.shared.checkIn() }
            } catch {
                update(d.id) { $0.enabled = was }
                self.error = "Couldn't change \(d.displayName) · \(error.localizedDescription)"
            }
        }
    }

    func rename(_ d: FleetDevice, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let was = d.name
        update(d.id) { $0.name = n }
        Task {
            pendingEdits += 1
            defer { pendingEdits -= 1 }
            do {
                try await Fleet.shared.rename(id: d.id, name: n, pw: pw)
                error = nil
                // Other phones send an empty name until their user picks one, so the server keeps this name for them;
                // this phone may have a nickname set, so bring it in step.
                if d.id == Fleet.shared.deviceID { AppSettings.shared.nickname = n }
            } catch {
                update(d.id) { $0.name = was }
                self.error = "Couldn't rename · \(error.localizedDescription)"
            }
        }
    }

    func forget(_ d: FleetDevice) {
        let backup = devices
        withAnimation(.easeOut(duration: 0.2)) { devices.removeAll { $0.id == d.id } }
        Task {
            pendingEdits += 1
            defer { pendingEdits -= 1 }
            do {
                try await Fleet.shared.forget(id: d.id, pw: pw)
                error = nil
            } catch {
                devices = backup
                self.error = "Couldn't forget \(d.displayName) · \(error.localizedDescription)"
            }
        }
    }

    func update(_ id: String, _ change: (inout FleetDevice) -> Void) {
        if let i = devices.firstIndex(where: { $0.id == id }) { change(&devices[i]) }
    }
}
