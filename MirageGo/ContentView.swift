import SwiftUI
import MapKit
import CoreLocation
import UniformTypeIdentifiers

// Monochrome look shared by the whole app (matches Mirage on the PC).
enum Theme {
    static let bg = Color(red: 0.04, green: 0.04, blue: 0.05)
    static let card = Color.white.opacity(0.06)
    static let line = Color.white.opacity(0.12)
    static let muted = Color(white: 0.66)
    static let dim = Color(white: 0.42)
    static let ok = Color(red: 0.13, green: 0.77, blue: 0.51)
    static let danger = Color(red: 1.0, green: 0.30, blue: 0.37)
    static let warn = Color(red: 0.96, green: 0.70, blue: 0.26)
}

struct ContentView: View {
    @EnvironmentObject var engine: SpoofEngine
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView(tab: $tab).tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
            PlacesView(tab: $tab).tabItem { Label("Places", systemImage: "mappin.and.ellipse") }.tag(1)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(2)
        }
        .tint(.white)
        .background(Theme.bg)
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var engine: SpoofEngine
    @EnvironmentObject var settings: AppSettings
    @Binding var tab: Int
    @State private var camera: MapCameraPosition = .automatic
    @State private var didCenter = false

    var statusColor: Color { engine.phase == .active ? Theme.ok : engine.phase == .connecting ? Theme.warn : Theme.danger }
    var statusText: String { engine.phase == .active ? "Protected" : engine.phase == .connecting ? "Connecting…" : "Unprotected" }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: engine.phase == .active ? "lock.fill" : "lock.open.fill")
                        Text(statusText).font(.system(size: 26, weight: .bold))
                    }
                    .foregroundStyle(statusColor)
                    Text(subline).font(.footnote).foregroundStyle(Theme.muted)
                }
                .padding(.top, 8)

                Button { tab = 2 } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "figure.walk.motion").font(.title2).frame(width: 40, height: 40).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Realistic travel").font(.headline).foregroundStyle(.white)
                            Text(settings.travel ? "\(AppSettings.speeds.first { $0.id == settings.travelSpeed }?.label ?? "Drive") · \(settings.speedMps, specifier: "%.1f") m/s" : "Off · new places teleport").font(.footnote).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.dim)
                    }
                    .padding(12).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal)

                mapView.frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal)

                if engine.phase == .connecting && !engine.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(engine.steps) { s in
                            HStack(spacing: 8) {
                                Circle().stroke(stepColor(s.status), lineWidth: 1.5).background(Circle().fill(s.status == "done" ? Theme.ok : .clear)).frame(width: 12, height: 12)
                                Text(s.label).foregroundStyle(s.status == "todo" ? Theme.dim : .white)
                                if !s.detail.isEmpty { Text("· \(s.detail)").foregroundStyle(Theme.dim).lineLimit(1) }
                                Spacer()
                            }
                            .font(.footnote)
                        }
                    }
                    .padding(12).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 14)).padding(.horizontal)
                }

                if let tr = engine.travel {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Circle().fill(Theme.ok).frame(width: 8, height: 8); Text("Travelling · \(Geo.fmtDist(max(0, tr.dist * (1 - engine.travelProgress)))) left · \(Geo.fmtDur(engine.travelETA))").font(.footnote) }
                        ProgressView(value: engine.travelProgress).tint(.white)
                        HStack {
                            Button("Teleport now") { engine.teleportNow() }.buttonStyle(PrimaryButton(compact: true))
                            Button("Stop here") { engine.stopTravel() }.buttonStyle(SecondaryButton(compact: true))
                        }
                    }
                    .padding(12).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 14)).padding(.horizontal)
                }

                if let err = engine.error {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(err).font(.footnote).foregroundStyle(.white)
                        if let h = engine.hint { Text(h).font(.footnote).foregroundStyle(Theme.muted) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(Theme.danger.opacity(0.12)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.danger.opacity(0.4)))
                    .clipShape(RoundedRectangle(cornerRadius: 14)).padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Simulated location").font(.footnote).foregroundStyle(Theme.muted)
                    HStack(spacing: 12) {
                        Text("📍").font(.title2).frame(width: 40, height: 40).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.positionName).font(.headline)
                            Text(Geo.fmt(engine.position)).font(.footnote).foregroundStyle(Theme.muted).monospacedDigit()
                        }
                        Spacer()
                    }
                    Button(engine.phase == .active ? "Disconnect" : engine.phase == .connecting ? "Connecting…" : "Connect") {
                        if engine.phase == .active { engine.disconnect() } else if engine.phase == .idle { engine.connect() }
                    }
                    .buttonStyle(PrimaryButton(dark: engine.phase != .idle))
                    .disabled(engine.phase == .connecting)
                    Button("Change place") { tab = 1 }.buttonStyle(SecondaryButton())
                    Button("Kill switch") { engine.kill() }.font(.subheadline.weight(.semibold)).foregroundStyle(Theme.danger).frame(maxWidth: .infinity).padding(.top, 2)
                }
                .padding(14).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal)

                Text("Keep Mirage Go installed and LocalDev VPN connected. Disconnect restores your real location.")
                    .font(.caption2).foregroundStyle(Theme.dim).multilineTextAlignment(.center).padding(.horizontal, 30).padding(.bottom, 20)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .onAppear { if !didCenter { camera = .region(MKCoordinateRegion(center: engine.position, latitudinalMeters: 4000, longitudinalMeters: 4000)); didCenter = true } }
    }

    var subline: String {
        let vpn = VPNHelper.tunnelUp ? "LocalDev VPN on" : (VPNHelper.installed ? "LocalDev VPN off" : "LocalDev VPN missing")
        let pair = PairingStore.present ? "pairing file ok" : "no pairing file"
        if engine.phase == .active, let t = engine.lastSetAt { return "This iPhone · via loopback · last push \(Int(Date().timeIntervalSince(t)))s ago" }
        return "\(vpn) · \(pair)"
    }

    func stepColor(_ s: String) -> Color { s == "done" ? Theme.ok : s == "busy" ? Theme.warn : s == "fail" ? Theme.danger : Theme.dim }

    var mapView: some View {
        MapReader { proxy in
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                Annotation("", coordinate: engine.position) { PulseDot(color: statusColor) }
                if let tr = engine.travel {
                    Annotation("", coordinate: tr.to) { Circle().fill(.white).frame(width: 12, height: 12).overlay(Circle().stroke(Theme.bg, lineWidth: 2)) }
                    MapPolyline(coordinates: [engine.position, tr.to]).stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [4, 6]))
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
            .onTapGesture { pt in
                if let c = proxy.convert(pt, from: .local) { engine.pick(c, name: "Custom point") }
            }
        }
    }
}

struct PulseDot: View {
    let color: Color
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.35)).frame(width: 46, height: 46).scaleEffect(pulse ? 1.6 : 0.6).opacity(pulse ? 0 : 0.6)
            Circle().fill(.white).frame(width: 14, height: 14).overlay(Circle().stroke(color, lineWidth: 3))
        }
        .onAppear { withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) { pulse = true } }
    }
}

struct PrimaryButton: ButtonStyle {
    var dark = false
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, compact ? 10 : 15)
            .background(dark ? Color(white: 0.16) : .white).foregroundStyle(dark ? .white : .black)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(dark ? Color.white.opacity(0.35) : .clear))
            .clipShape(RoundedRectangle(cornerRadius: 12)).opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct SecondaryButton: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, compact ? 10 : 15)
            .background(Color(white: 0.14)).foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12)).opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - Places

struct PlacesView: View {
    @EnvironmentObject var engine: SpoofEngine
    @EnvironmentObject var store: PlaceStore
    @Binding var tab: Int
    @State private var naming = false
    @State private var newName = ""

    var sorted: [Place] { store.places.sorted { ($0.fav ? 0 : 1, $0.name) < ($1.fav ? 0 : 1, $1.name) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { newName = engine.positionName == "Custom point" ? "" : engine.positionName; naming = true } label: {
                        Label("Save current map point", systemImage: "plus").foregroundStyle(.white)
                    }
                }
                Section("Places") {
                    ForEach(sorted) { p in
                        HStack(spacing: 12) {
                            Text(p.icon).font(.title3).frame(width: 36, height: 30).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).foregroundStyle(.white)
                                Text(Geo.fmt(p.coordinate)).font(.caption).foregroundStyle(Theme.dim).monospacedDigit()
                            }
                            Spacer()
                            Button { store.toggleFav(p) } label: { Image(systemName: p.fav ? "star.fill" : "star").foregroundStyle(p.fav ? .white : Theme.dim) }.buttonStyle(.plain)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            engine.pick(p.coordinate, name: p.name)
                            if engine.phase == .idle { engine.connect() }
                            tab = 0
                        }
                        .swipeActions { if p.custom { Button(role: .destructive) { store.delete(p) } label: { Label("Delete", systemImage: "trash") } } }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Places")
            .alert("Save this point", isPresented: $naming) {
                TextField("Name", text: $newName)
                Button("Save") { store.add(name: newName.isEmpty ? "My place" : newName, at: engine.position, icon: "🏠"); engine.positionName = newName.isEmpty ? "My place" : newName }
                Button("Cancel", role: .cancel) {}
            } message: { Text(Geo.fmt(engine.position)) }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var engine: SpoofEngine
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var log = AppLog.shared
    @State private var importing = false
    @State private var busy = ""
    @State private var tick = 0
    @State private var portText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Movement") {
                    Toggle("Realistic travel", isOn: $settings.travel)
                    Picker("Speed", selection: $settings.travelSpeed) {
                        ForEach(AppSettings.speeds, id: \.id) { s in Text("\(s.label) \(s.mps, specifier: "%.1f")").tag(s.id) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("GPS jitter", isOn: Binding(get: { settings.jitter }, set: { engine.setJitter($0) }))
                    if settings.jitter {
                        HStack { Text("Max drift"); Slider(value: $settings.jitterMeters, in: 1...15, step: 1); Text("\(Int(settings.jitterMeters)) m").monospacedDigit().foregroundStyle(Theme.muted) }
                    }
                }
                Section("Phone link") {
                    row("LocalDev VPN", VPNHelper.tunnelUp ? "Connected" : VPNHelper.installed ? "Installed, off" : "Not installed", VPNHelper.tunnelUp ? Theme.ok : Theme.warn)
                    Button("Open LocalDev VPN") { VPNHelper.open() }
                    row("Pairing file", PairingStore.present ? PairingStore.kind : "Missing", PairingStore.present ? Theme.ok : Theme.warn)
                    Button("Import pairing file…") { importing = true }
                    Text("Or drop pairingFile.plist into Mirage Go's folder in the Files app / Apple Devices file sharing; it is picked up automatically.").font(.caption).foregroundStyle(Theme.dim)
                    row("Developer image", DDIStore.present ? "Files ready · \(engine.ddiStatus)" : "Not downloaded", DDIStore.present ? Theme.ok : Theme.warn)
                    Button(busy.isEmpty ? "Download developer image (16 MB)" : busy) {
                        Task { busy = "Downloading…"; do { try await DDIStore.download { s in busy = s } } catch { busy = error.localizedDescription }; try? await Task.sleep(nanoseconds: 1_500_000_000); busy = "" }
                    }.disabled(!busy.isEmpty)
                }
                Section("Advanced") {
                    HStack { Text("Device IP"); Spacer(); TextField("10.7.0.1", text: $settings.deviceIP).multilineTextAlignment(.trailing).keyboardType(.decimalPad) }
                    HStack { Text("Port"); Spacer(); TextField("49152", text: $portText).multilineTextAlignment(.trailing).keyboardType(.numberPad).onChange(of: portText) { _, v in if let p = Int(v), p > 0, p < 65536 { settings.devicePort = p } } }
                    Text("Cellular only? Turn Airplane Mode on, connect LocalDev VPN, press Connect, then turn cellular back on with Airplane Mode still on.").font(.caption).foregroundStyle(Theme.dim)
                }
                Section("Log") {
                    ScrollView { VStack(alignment: .leading, spacing: 2) { ForEach(Array(log.lines.suffix(60).enumerated()), id: \.offset) { _, l in Text(l).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted) } }.frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 180)
                    Button("Copy log") { UIPasteboard.general.string = log.lines.joined(separator: "\n") }
                }
                Section("About") {
                    row("Mirage Go", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "", Theme.muted)
                    Text("Only changes what this iPhone reports. Uses Apple's developer location service through LocalDev VPN; nothing is jailbroken.").font(.caption).foregroundStyle(Theme.dim)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Settings")
            .onAppear { portText = String(settings.devicePort); tick += 1 }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .data, .item], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let u = urls.first else { return }
                    let ok = u.startAccessingSecurityScopedResource()
                    defer { if ok { u.stopAccessingSecurityScopedResource() } }
                    do { try PairingStore.install(from: u); AppLog.shared.add("pairing file imported"); tick += 1 }
                    catch { AppLog.shared.add("import failed: \(error.localizedDescription)") }
                case .failure(let e): AppLog.shared.add("import cancelled: \(e.localizedDescription)")
                }
            }
        }
    }

    func row(_ k: String, _ v: String, _ c: Color) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(c).font(.subheadline) }
    }
}
