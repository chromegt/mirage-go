import SwiftUI
import MapKit
import CoreLocation
import UniformTypeIdentifiers

// Monochrome look shared with Mirage on the PC: black, white, grey, and only the status colours.
enum Theme {
    static let bg = Color(red: 0.04, green: 0.04, blue: 0.05)
    static let card = Color.white.opacity(0.055)
    static let card2 = Color.white.opacity(0.09)
    static let line = Color.white.opacity(0.12)
    static let muted = Color(white: 0.68)
    static let dim = Color(white: 0.44)
    static let ok = Color(red: 0.13, green: 0.77, blue: 0.51)
    static let danger = Color(red: 1.0, green: 0.30, blue: 0.37)
    static let warn = Color(red: 0.96, green: 0.70, blue: 0.26)
}

struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(Theme.card)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// The "3D" white button from the desktop app: light face, darker bottom edge, soft glow, presses down.
struct Button3D: ButtonStyle {
    var dark = false
    var danger = false
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let face: LinearGradient = dark
            ? LinearGradient(colors: [Color(white: 0.22), Color(white: 0.13)], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [.white, Color(white: 0.86)], startPoint: .top, endPoint: .bottom)
        return configuration.label
            .font(.system(size: compact ? 14 : 16, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 11 : 15)
            .foregroundStyle(danger ? Theme.danger : (dark ? Color.white : Color.black))
            .background(face)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(dark ? Color.white.opacity(danger ? 0.0 : 0.22) : Color.white.opacity(0.9), lineWidth: 1))
            .overlay(danger ? RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.danger.opacity(0.45), lineWidth: 1) : nil)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: dark ? .black.opacity(0.7) : Color(white: 0.55), radius: 0, x: 0, y: pressed ? 1 : 4)
            .shadow(color: dark ? .clear : .white.opacity(0.14), radius: 16, x: 0, y: 8)
            .offset(y: pressed ? 3 : 0)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 8, height: 8).shadow(color: color.opacity(0.8), radius: 5) }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var engine: SpoofEngine
    @State private var tab = 0
    @State private var showSetup = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            Group {
                switch tab {
                case 1: PlacesView(tab: $tab)
                case 2: SettingsView(showSetup: $showSetup)
                default: HomeView(tab: $tab, showSetup: $showSetup)
                }
            }
            VStack { Spacer(); GlassTabBar(tab: $tab) }
        }
        .sheet(isPresented: $showSetup) { SetupView().environmentObject(engine) }
        .onAppear { if !Readiness.allGood && !UserDefaults.standard.bool(forKey: "setupSeen") { showSetup = true } }
    }
}

struct GlassTabBar: View {
    @Binding var tab: Int
    let items: [(String, String)] = [("house.fill", "Home"), ("mappin.and.ellipse", "Places"), ("gearshape.fill", "Settings")]
    var body: some View {
        HStack {
            ForEach(items.indices, id: \.self) { i in
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    tab = i
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: items[i].0).font(.system(size: 20, weight: .semibold))
                        Text(items[i].1).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(tab == i ? .white : Theme.dim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(tab == i ? Color.white.opacity(0.1) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial)
        .background(Theme.bg.opacity(0.6))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.6), radius: 20, y: 10)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
}

// MARK: - Readiness

enum Readiness {
    static var vpnInstalled: Bool { VPNHelper.installed }
    static var vpnUp: Bool { VPNHelper.tunnelUp }
    static var pairing: Bool { PairingStore.present }
    static var ddiFiles: Bool { DDIStore.present }
    static var allGood: Bool { vpnInstalled && pairing }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var engine: SpoofEngine
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var net = NetworkMonitor.shared
    @Binding var tab: Int
    @Binding var showSetup: Bool
    @State private var camera: MapCameraPosition = .automatic
    @State private var didCenter = false
    @State private var now = Date()
    let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var statusColor: Color { engine.phase == .active ? Theme.ok : engine.phase == .connecting ? Theme.warn : Theme.danger }
    var statusText: String { engine.phase == .active ? "Protected" : engine.phase == .connecting ? "Connecting" : "Unprotected" }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                brandBar
                hero
                mapCard
                if engine.phase == .connecting && !engine.steps.isEmpty { stepsCard }
                if engine.travel != nil { travelCard }
                if let err = engine.error { errorCard(err) }
                if net.cellularOnly && !Readiness.vpnUp && engine.phase != .active { cellularTip }
                locationCard
                Text("Keep LocalDev VPN connected while spoofing. Disconnect or Kill switch restores the real location.")
                    .font(.caption2).foregroundStyle(Theme.dim).multilineTextAlignment(.center).padding(.horizontal, 36)
                Color.clear.frame(height: 90)
            }
            .padding(.top, 6)
        }
        .onReceive(clock) { now = $0 }
        .onAppear {
            if !didCenter { camera = .region(MKCoordinateRegion(center: engine.position, latitudinalMeters: 5000, longitudinalMeters: 5000)); didCenter = true }
        }
    }

    var brandBar: some View {
        HStack(spacing: 10) {
            Image("Logo").resizable().scaledToFit().frame(width: 26, height: 26)
            Text("Mirage Go").font(.system(size: 17, weight: .semibold))
            Spacer()
            HStack(spacing: 6) {
                StatusDot(color: Readiness.vpnUp ? Theme.ok : Theme.warn)
                Text(Readiness.vpnUp ? "VPN on" : "VPN off").font(.caption).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 6).background(Theme.card).clipShape(Capsule())
            .onTapGesture { if !Readiness.vpnUp { VPNHelper.open() } }
        }
        .padding(.horizontal, 20)
    }

    var hero: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(statusColor.opacity(0.14)).frame(width: 96, height: 96)
                Circle().stroke(statusColor.opacity(0.35), lineWidth: 1).frame(width: 96, height: 96)
                Image(systemName: engine.phase == .active ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 36, weight: .semibold)).foregroundStyle(statusColor)
                    .shadow(color: statusColor.opacity(0.7), radius: 14)
            }
            Text(statusText).font(.system(size: 30, weight: .bold)).foregroundStyle(statusColor)
            Text(subline).font(.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center).padding(.horizontal, 30)
        }
        .padding(.top, 6)
    }

    var subline: String {
        if engine.phase == .active {
            let ago = engine.lastSetAt.map { Int(now.timeIntervalSince($0)) } ?? 0
            return "Every app on this iPhone sees \(engine.positionName) · pushed \(ago)s ago"
        }
        if engine.phase == .connecting { return "Setting up the link to this phone" }
        if !Readiness.vpnInstalled { return "Install LocalDev VPN to get started" }
        if !Readiness.pairing { return "Import the pairing file from the PC" }
        return "Your real location is visible to apps"
    }

    var mapCard: some View {
        ZStack(alignment: .bottomLeading) {
            MapReader { proxy in
                Map(position: $camera, interactionModes: [.pan, .zoom]) {
                    Annotation("", coordinate: engine.position) { PulseDot(color: statusColor) }
                    if let tr = engine.travel {
                        Annotation("", coordinate: tr.to) { Circle().fill(.white).frame(width: 12, height: 12).overlay(Circle().stroke(Theme.bg, lineWidth: 2)) }
                        MapPolyline(coordinates: [engine.position, tr.to]).stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [4, 6]))
                    }
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
                .mapControlVisibility(.hidden)
                .onTapGesture { pt in
                    if let c = proxy.convert(pt, from: .local) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        engine.pick(c, name: "Custom point")
                    }
                }
            }
            LinearGradient(colors: [Theme.bg.opacity(0.85), .clear], startPoint: .bottom, endPoint: .center).allowsHitTesting(false)
            HStack {
                Text(Geo.fmt(engine.position)).font(.caption.monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6).background(.ultraThinMaterial).clipShape(Capsule())
                Spacer()
                Button {
                    withAnimation { camera = .region(MKCoordinateRegion(center: engine.position, latitudinalMeters: 3000, longitudinalMeters: 3000)) }
                } label: {
                    Image(systemName: "scope").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 34, height: 34).background(.ultraThinMaterial).clipShape(Circle())
                }
            }
            .padding(12)
        }
        .frame(height: 340)
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
    }

    var stepsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(engine.steps) { s in
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().stroke(stepColor(s.status), lineWidth: 1.5).frame(width: 14, height: 14)
                            if s.status == "done" { Circle().fill(Theme.ok).frame(width: 14, height: 14); Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.black) }
                            if s.status == "busy" { ProgressView().scaleEffect(0.5).tint(Theme.warn) }
                        }
                        Text(s.label).foregroundStyle(s.status == "todo" ? Theme.dim : .white)
                        if !s.detail.isEmpty { Text(s.detail).foregroundStyle(Theme.dim).lineLimit(1) }
                        Spacer()
                    }
                    .font(.footnote)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    var travelCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusDot(color: Theme.ok)
                    Text("Travelling to \(engine.travel?.name ?? "")").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Geo.fmtDist(max(0, (engine.travel?.dist ?? 0) * (1 - engine.travelProgress)))) · \(Geo.fmtDur(engine.travelETA))").font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                }
                ProgressView(value: engine.travelProgress).tint(.white)
                HStack(spacing: 8) {
                    Button("Teleport now") { engine.teleportNow() }.buttonStyle(Button3D(compact: true))
                    Button("Stop here") { engine.stopTravel() }.buttonStyle(Button3D(dark: true, compact: true))
                }
            }
        }
        .padding(.horizontal, 16)
    }

    func errorCard(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger); Text(err).font(.footnote.weight(.semibold)) }
            if let h = engine.hint { Text(h).font(.footnote).foregroundStyle(Theme.muted) }
            HStack {
                Button("Setup checklist") { showSetup = true }.font(.footnote.weight(.semibold)).foregroundStyle(.white)
                Spacer()
                Button("Dismiss") { engine.error = nil; engine.hint = nil }.font(.footnote).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).background(Theme.danger.opacity(0.10))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.danger.opacity(0.45), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
    }

    var cellularTip: some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "airplane").foregroundStyle(Theme.warn)
                VStack(alignment: .leading, spacing: 3) {
                    Text("On cellular only").font(.subheadline.weight(.semibold))
                    Text("Turn Airplane Mode on, connect LocalDev VPN, press Connect, then turn cellular back on (leave Airplane Mode on).").font(.caption).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    var locationCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Simulated location").font(.caption).foregroundStyle(Theme.muted)
                HStack(spacing: 12) {
                    Text(placeIcon).font(.title2).frame(width: 44, height: 44).background(Theme.card2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(engine.positionName).font(.headline)
                        Text(Geo.fmt(engine.position)).font(.footnote.monospacedDigit()).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if engine.phase == .active { engine.disconnect() } else if engine.phase == .idle { engine.connect() }
                } label: {
                    HStack(spacing: 8) {
                        if engine.phase == .connecting { ProgressView().tint(.white).scaleEffect(0.8) }
                        Text(engine.phase == .active ? "Disconnect" : engine.phase == .connecting ? "Connecting…" : "Connect")
                    }
                }
                .buttonStyle(Button3D(dark: engine.phase != .idle))
                .disabled(engine.phase == .connecting)
                Button("Change place") { tab = 1 }.buttonStyle(Button3D(dark: true))
                Button {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    engine.kill()
                } label: { Label("Kill switch", systemImage: "power") }
                .buttonStyle(Button3D(dark: true, danger: true, compact: true))
            }
        }
        .padding(.horizontal, 16)
    }

    var placeIcon: String { PlaceStore.shared.places.first { $0.name == engine.positionName }?.icon ?? "📍" }
    func stepColor(_ s: String) -> Color { s == "done" ? Theme.ok : s == "busy" ? Theme.warn : s == "fail" ? Theme.danger : Theme.dim }
}

struct PulseDot: View {
    let color: Color
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.35)).frame(width: 50, height: 50).scaleEffect(pulse ? 1.7 : 0.5).opacity(pulse ? 0 : 0.7)
            Circle().fill(color.opacity(0.35)).frame(width: 50, height: 50).scaleEffect(pulse ? 1.2 : 0.4).opacity(pulse ? 0 : 0.5)
            Circle().fill(.white).frame(width: 14, height: 14).overlay(Circle().stroke(color, lineWidth: 3)).shadow(color: color, radius: 8)
        }
        .onAppear { withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)) { pulse = true } }
    }
}

// MARK: - Places

struct PlacesView: View {
    @EnvironmentObject var engine: SpoofEngine
    @EnvironmentObject var store: PlaceStore
    @Binding var tab: Int
    @State private var naming = false
    @State private var newName = ""
    @State private var pendingDelete: Place?

    var favs: [Place] { store.places.filter { $0.fav }.sorted { $0.name < $1.name } }
    var rest: [Place] { store.places.filter { !$0.fav }.sorted { $0.name < $1.name } }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Places").font(.system(size: 30, weight: .bold))
                    Text("Tap a place to spoof there. Hold a custom place to delete it.").font(.footnote).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 20).padding(.top, 8)

                Button { newName = engine.positionName == "Custom point" ? "" : engine.positionName; naming = true } label: {
                    Label("Save current map point", systemImage: "plus")
                }
                .buttonStyle(Button3D(dark: true, compact: true)).padding(.horizontal, 16)

                if !favs.isEmpty { section("Favorites", favs) }
                section(favs.isEmpty ? "All places" : "More places", rest)
                Color.clear.frame(height: 90)
            }
        }
        .alert("Save this point", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") { let n = newName.isEmpty ? "My place" : newName; store.add(name: n, at: engine.position, icon: "🏠"); engine.positionName = n }
            Button("Cancel", role: .cancel) {}
        } message: { Text(Geo.fmt(engine.position)) }
        .alert("Delete \(pendingDelete?.name ?? "")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) { if let p = pendingDelete { store.delete(p) }; pendingDelete = nil }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    func section(_ title: String, _ items: [Place]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Theme.dim).padding(.horizontal, 24)
            VStack(spacing: 0) {
                ForEach(items) { p in
                    let selected = engine.positionName == p.name
                    HStack(spacing: 12) {
                        Text(p.icon).font(.title3).frame(width: 40, height: 34).background(Theme.card2).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            Text(Geo.fmt(p.coordinate)).font(.caption.monospacedDigit()).foregroundStyle(Theme.dim)
                        }
                        Spacer()
                        if selected { Text(engine.isActive ? "Here" : "Selected").font(.caption2.weight(.bold)).padding(.horizontal, 8).padding(.vertical, 4).background(engine.isActive ? Theme.ok : Color.white).foregroundStyle(.black).clipShape(Capsule()) }
                        Button { store.toggleFav(p) } label: { Image(systemName: p.fav ? "star.fill" : "star").foregroundStyle(p.fav ? .white : Theme.dim).frame(width: 30, height: 30) }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(selected ? Color.white.opacity(0.06) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        engine.pick(p.coordinate, name: p.name)
                        if engine.phase == .idle { engine.connect() }
                        tab = 0
                    }
                    .onLongPressGesture { if p.custom { pendingDelete = p } }
                    if p.id != items.last?.id { Divider().overlay(Theme.line).padding(.leading, 64) }
                }
            }
            .background(Theme.card)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var engine: SpoofEngine
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var log = AppLog.shared
    @Binding var showSetup: Bool
    @State private var importing = false
    @State private var busy = ""
    @State private var portText = ""
    @State private var refresh = 0

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings").font(.system(size: 30, weight: .bold))
                    Text("Changes apply right away.").font(.footnote).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 20).padding(.top, 8)

                group("Movement") {
                    toggleRow("Realistic travel", "Glide to a new place at a real speed instead of jumping.", isOn: $settings.travel)
                    Picker("Speed", selection: $settings.travelSpeed) {
                        ForEach(AppSettings.speeds, id: \.id) { s in Text(s.label).tag(s.id) }
                    }
                    .pickerStyle(.segmented).padding(.vertical, 6)
                    toggleRow("GPS jitter", "Drift a few metres every few seconds, like a real GPS fix.", isOn: Binding(get: { settings.jitter }, set: { engine.setJitter($0) }))
                    if settings.jitter {
                        HStack { Text("Max drift").font(.subheadline); Slider(value: $settings.jitterMeters, in: 1...15, step: 1).tint(.white); Text("\(Int(settings.jitterMeters)) m").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.muted) }
                    }
                }

                group("Phone link") {
                    statusRow("LocalDev VPN", Readiness.vpnUp ? "Connected" : Readiness.vpnInstalled ? "Installed, not connected" : "Not installed", Readiness.vpnUp ? Theme.ok : Theme.warn)
                    Button("Open LocalDev VPN") { VPNHelper.open() }.buttonStyle(Button3D(dark: true, compact: true))
                    statusRow("Pairing file", Readiness.pairing ? PairingStore.kind : "Missing", Readiness.pairing ? Theme.ok : Theme.warn)
                    Button("Import pairing file…") { importing = true }.buttonStyle(Button3D(dark: true, compact: true))
                    Text("Or drop pairingFile.plist into the Mirage Go folder (Files app or Apple Devices file sharing); it is picked up on the next launch.").font(.caption).foregroundStyle(Theme.dim)
                    statusRow("Developer image", Readiness.ddiFiles ? "Files ready · \(engine.ddiStatus)" : "Not downloaded yet", Readiness.ddiFiles ? Theme.ok : Theme.warn)
                    Button(busy.isEmpty ? "Download developer image (16 MB)" : busy) {
                        Task { busy = "Downloading…"; do { try await DDIStore.download { s in busy = s } } catch { busy = error.localizedDescription }; try? await Task.sleep(nanoseconds: 1_500_000_000); busy = ""; refresh += 1 }
                    }.buttonStyle(Button3D(dark: true, compact: true)).disabled(!busy.isEmpty)
                    Button("Setup checklist") { showSetup = true }.buttonStyle(Button3D(compact: true))
                }

                group("Advanced") {
                    HStack { Text("Device IP").font(.subheadline); Spacer(); TextField("10.7.0.1", text: $settings.deviceIP).multilineTextAlignment(.trailing).keyboardType(.decimalPad).foregroundStyle(Theme.muted) }
                    HStack { Text("Port").font(.subheadline); Spacer(); TextField("49152", text: $portText).multilineTextAlignment(.trailing).keyboardType(.numberPad).foregroundStyle(Theme.muted).onChange(of: portText) { _, v in if let p = Int(v), p > 0, p < 65536 { settings.devicePort = p } } }
                    Text("Leave these unless LocalDev VPN tells you otherwise. Cellular only: Airplane Mode on → connect the VPN → Connect → cellular back on.").font(.caption).foregroundStyle(Theme.dim)
                }

                group("Log") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(log.lines.suffix(80).enumerated()), id: \.offset) { _, l in
                                Text(l).font(.system(size: 11, design: .monospaced)).foregroundStyle(l.contains("failed") || l.contains("lost") ? Theme.danger : Theme.muted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 170)
                    Button("Copy log") { UIPasteboard.general.string = log.lines.joined(separator: "\n"); UINotificationFeedbackGenerator().notificationOccurred(.success) }.buttonStyle(Button3D(dark: true, compact: true))
                }

                group("About") {
                    statusRow("Mirage Go", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "", Theme.muted)
                    Text("Only changes what this iPhone reports. It uses Apple's developer location service through LocalDev VPN; nothing is jailbroken and nothing leaves the phone.").font(.caption).foregroundStyle(Theme.dim)
                }
                Color.clear.frame(height: 90)
            }
        }
        .id(refresh)
        .onAppear { portText = String(settings.devicePort) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .data, .item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let u = urls.first else { return }
                let ok = u.startAccessingSecurityScopedResource()
                defer { if ok { u.stopAccessingSecurityScopedResource() } }
                do { try PairingStore.install(from: u); AppLog.shared.add("pairing file imported"); UINotificationFeedbackGenerator().notificationOccurred(.success) }
                catch { AppLog.shared.add("import failed: \(error.localizedDescription)") }
                refresh += 1
            case .failure(let e): AppLog.shared.add("import cancelled: \(e.localizedDescription)")
            }
        }
    }

    func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Theme.dim).padding(.horizontal, 24)
            Card { VStack(alignment: .leading, spacing: 10) { content() } }.padding(.horizontal, 16)
        }
    }

    func toggleRow(_ title: String, _ desc: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.subheadline.weight(.semibold)); Text(desc).font(.caption).foregroundStyle(Theme.muted) }
        }
        .tint(.white)
    }

    func statusRow(_ k: String, _ v: String, _ c: Color) -> some View {
        HStack(spacing: 8) { Text(k).font(.subheadline); Spacer(); StatusDot(color: c); Text(v).font(.subheadline).foregroundStyle(c == Theme.muted ? Theme.muted : .white) }
    }
}

// MARK: - Setup checklist

struct SetupView: View {
    @EnvironmentObject var engine: SpoofEngine
    @Environment(\.dismiss) private var dismiss
    @State private var refresh = 0
    @State private var importing = false
    @State private var busy = ""

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Three things, once. After that it's just Connect.").font(.footnote).foregroundStyle(Theme.muted).padding(.horizontal, 4)
                    step(1, "LocalDev VPN", Readiness.vpnUp ? "Connected" : Readiness.vpnInstalled ? "Installed. Open it and tap Connect." : "Install it from the App Store, open it once, allow the VPN configuration.",
                         ok: Readiness.vpnUp, partial: Readiness.vpnInstalled) {
                        Button(Readiness.vpnInstalled ? "Open LocalDev VPN" : "Get LocalDev VPN") {
                            if Readiness.vpnInstalled { VPNHelper.open() } else if let u = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044") { UIApplication.shared.open(u) }
                        }
                    }
                    step(2, "Pairing file", Readiness.pairing ? "Imported (\(PairingStore.kind))" : "Made on the PC with the cable. Import it here, or have it dropped into the Mirage Go folder.",
                         ok: Readiness.pairing, partial: false) {
                        Button("Import pairing file…") { importing = true }
                    }
                    step(3, "Developer image", Readiness.ddiFiles ? "Downloaded. It gets signed by Apple on the first Connect (needs internet)." : "16 MB download. Mirage Go grabs it on the first Connect, or now.",
                         ok: Readiness.ddiFiles, partial: false) {
                        Button(busy.isEmpty ? "Download now" : busy) {
                            Task { busy = "Downloading…"; do { try await DDIStore.download { s in busy = s } } catch { busy = error.localizedDescription }; try? await Task.sleep(nanoseconds: 1_200_000_000); busy = ""; refresh += 1 }
                        }.disabled(!busy.isEmpty)
                    }
                    Card {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "wifi").foregroundStyle(Theme.warn)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Wi-Fi for the first run").font(.subheadline.weight(.semibold))
                                Text("The first Connect needs internet to get the developer image signed. After that, cellular works with Airplane Mode on while you connect.").font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                    Button("Done") { UserDefaults.standard.set(true, forKey: "setupSeen"); dismiss() }.buttonStyle(Button3D()).padding(.top, 4)
                }
                .padding(16)
            }
            .id(refresh)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { UserDefaults.standard.set(true, forKey: "setupSeen"); dismiss() }.foregroundStyle(.white) } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .data, .item], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let u = urls.first {
                    let ok = u.startAccessingSecurityScopedResource()
                    defer { if ok { u.stopAccessingSecurityScopedResource() } }
                    do { try PairingStore.install(from: u); AppLog.shared.add("pairing file imported") } catch { AppLog.shared.add("import failed: \(error.localizedDescription)") }
                    refresh += 1
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    func step<A: View>(_ n: Int, _ title: String, _ desc: String, ok: Bool, partial: Bool, @ViewBuilder action: () -> A) -> some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(ok ? Theme.ok : partial ? Theme.warn : Theme.card2).frame(width: 30, height: 30)
                    if ok { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.black) } else { Text("\(n)").font(.system(size: 13, weight: .bold)).foregroundStyle(partial ? .black : .white) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline)
                    Text(desc).font(.caption).foregroundStyle(Theme.muted)
                    if !ok { action().buttonStyle(Button3D(dark: true, compact: true)).padding(.top, 4) }
                }
            }
        }
    }
}
