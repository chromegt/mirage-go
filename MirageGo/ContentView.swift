import SwiftUI
import Combine
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
    /// ~6:1 on `bg`; used for help copy, so it has to clear WCAG AA.
    static let dim = Color(white: 0.56)
    /// Section headers only (never sentences).
    static let header = Color(white: 0.5)
    static let idle = Color(white: 0.8)
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
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let face: LinearGradient = dark
            ? LinearGradient(colors: [Color(white: 0.22), Color(white: 0.13)], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [.white, Color(white: 0.86)], startPoint: .top, endPoint: .bottom)
        return configuration.label
            .font(compact ? .callout.bold() : .body.bold())
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
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 8, height: 8).shadow(color: color.opacity(0.8), radius: 5) }
}

/// The round glass control shared by the map stage and the tab headers: 44 pt, material, hairline, plain style.
struct GlassCircleButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.callout.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial)
                .overlay(Circle().stroke(Theme.line, lineWidth: 1))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Top scrim for the scrolling tabs: solid under the status bar, a short fade below it, so scrolled rows never run
/// under the clock. Overlay it on the ScrollView with `alignment: .top`.
/// Stars around the planet while the stage is zoomed all the way out: the desktop app's space backdrop. Positions
/// are deterministic, the brightest few twinkle slowly, and a radial mask keeps the centre (where the globe sits)
/// clear so the stars only live in space. Drawn with plusLighter so they only ever add light.
struct Starfield: View {
    struct Star { let x: CGFloat; let y: CGFloat; let r: CGFloat; let a: Double }
    static let stars: [Star] = {
        var g = SeededRandom(seed: 0x5EED_1234)
        return (0..<190).map { _ in
            Star(x: CGFloat(g.next()), y: CGFloat(g.next()), r: CGFloat(0.45 + g.next() * 1.05), a: 0.22 + g.next() * 0.7)
        }
    }()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 3600 : 0.6)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                for (i, s) in Self.stars.enumerated() {
                    let twinkle = (!reduceMotion && i % 7 == 0) ? 0.45 + 0.55 * abs(sin(t * 0.8 + Double(i))) : 1.0
                    let p = CGPoint(x: s.x * size.width, y: s.y * size.height)
                    g.fill(Path(ellipseIn: CGRect(x: p.x - s.r, y: p.y - s.r, width: s.r * 2, height: s.r * 2)),
                           with: .color(.white.opacity(s.a * twinkle)))
                    if s.r > 1.3 {   // a soft halo on the biggest ones
                        g.fill(Path(ellipseIn: CGRect(x: p.x - s.r * 3, y: p.y - s.r * 3, width: s.r * 6, height: s.r * 6)),
                               with: .color(.white.opacity(0.06 * twinkle)))
                    }
                }
            }
        }
        .blendMode(.plusLighter)
        .mask(RadialGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.4), .init(color: .white, location: 0.68)],
                             center: .center, startRadius: 0, endRadius: 300))
        .allowsHitTesting(false)
    }
}

/// Tiny LCG so the star layout is the same on every launch (no Foundation randomness in a view body).
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }
}

struct TopScrim: View {
    var body: some View {
        LinearGradient(stops: [.init(color: Theme.bg, location: 0),
                               .init(color: Theme.bg, location: 0.35),
                               .init(color: Theme.bg.opacity(0), location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: 24)
            .background(Theme.bg, ignoresSafeAreaEdges: .top)
            .allowsHitTesting(false)
    }
}

/// List rows: a light wash while pressed, nothing else (the row keeps its own layout).
struct PressRow: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Color.white.opacity(0.08) : .clear)
    }
}

// MARK: - Readiness

/// Observable snapshot of the prerequisites. The underlying checks (getifaddrs, canOpenURL, fileExists) have no
/// publisher, so this polls once a second and on foreground; views bind to it instead of re-checking ad hoc.
@MainActor
final class Readiness: ObservableObject {
    static let shared = Readiness()
    @Published var vpnInstalled = false
    @Published var vpnUp = false
    @Published var pairing = false
    @Published var pairingKind = "none"
    @Published var ddiFiles = false
    @Published var locationAuth: CLAuthorizationStatus = .notDetermined
    private var timer: Timer?

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        // A pairing file pushed from the PC while the app is already in the foreground is adopted by this poll
        // (App.init and the .active handler only cover launch / background -> foreground).
        if !pairing { PairingStore.adoptFromDocuments() }
        let vi = VPNHelper.installed, vu = VPNHelper.tunnelUp, k = PairingStore.kind, p = k == PairingStore.remoteKind
        let d = DDIStore.present, a = LocationKeeper.shared.authorization
        if vi != vpnInstalled { vpnInstalled = vi }
        if vu != vpnUp { vpnUp = vu }
        if p != pairing { pairing = p }
        if k != pairingKind { pairingKind = k }
        if d != ddiFiles { ddiFiles = d }
        if a != locationAuth { locationAuth = a }
    }

    var allGood: Bool { vpnInstalled && pairing }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var engine: SpoofEngine
    @EnvironmentObject var ready: Readiness
    @State private var tab = 0
    @State private var showSetup = false
    /// First launch only: the checklist is a full-screen cover (branded, no accidental swipe-away); later opens are a sheet.
    @State private var showFirstRun = false
    /// The first-run check runs once per launch: a dismissed fullScreenCover re-inserts the presenter and re-fires onAppear.
    @State private var autoOpened = false
    // Map camera lives here so switching tabs does not reset the user's zoom. It starts on the globe, centred on
    // the last place, so the first frame is already the stage (no .automatic -> fly-in jump).
    @State private var camera: MapCameraPosition = .camera(MapCamera(
        centerCoordinate: CLLocationCoordinate2D(latitude: AppSettings.shared.lastLat, longitude: AppSettings.shared.lastLon),
        distance: globeDistance, heading: 0, pitch: 0))
    // The bottom inset is keyboard-aware, so it would float above the keyboard while typing; hide it instead
    // (native tab bars stay under the keyboard). Not `.ignoresSafeArea(.keyboard)`: the Settings IP/Port fields
    // near the bottom of their scroll still need keyboard avoidance.
    @State private var keyboardUp = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            Group {
                switch tab {
                case 1: PlacesView(tab: $tab)
                case 2: SettingsView(showSetup: $showSetup)
                default: HomeView(tab: $tab, showSetup: $showSetup, camera: $camera)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { keyboardUp = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { keyboardUp = false }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !keyboardUp {
                VStack(spacing: 8) {
                    if tab == 0 { PrimaryActionBar(showSetup: $showSetup) }
                    GlassTabBar(tab: $tab)
                }
                .padding(.top, 16)
                .background(
                    LinearGradient(stops: [.init(color: Theme.bg.opacity(0), location: 0),
                                           .init(color: Theme.bg.opacity(0.9), location: 0.35),
                                           .init(color: Theme.bg.opacity(0.96), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .padding(.top, -24)   // the fade starts above the button, not at its edge
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                )
            }
        }
        .sheet(isPresented: $showSetup, onDismiss: markSetupSeen) {
            SetupView().environmentObject(engine).environmentObject(ready)
                .presentationBackground(Theme.bg)
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showFirstRun, onDismiss: markSetupSeen) {
            SetupView(firstRun: true).environmentObject(engine).environmentObject(ready)
        }
        .onAppear {
            guard !autoOpened else { return }
            autoOpened = true
            if !ready.allGood && !UserDefaults.standard.bool(forKey: "setupSeen") {
                markSetupSeen()   // shown once = seen, so nothing can re-trigger it
                showFirstRun = true
            }
        }
        // Camera follow lives here (not in HomeView) so a pick made on the Places tab still recentres Home.
        // A travel frames both ends; when it ends (arrival, stop, teleport) the camera settles on the position.
        .onChange(of: engine.travel) { _, tr in
            withAnimation(.easeInOut(duration: 1.0)) {
                camera = tr.map { MapCameraPosition.region(regionFitting([$0.from, $0.to])) } ?? stageCamera(engine.position, phase: engine.phase)
            }
        }
        // Keyed on position + name so picking a second place with the same name still moves the camera.
        .onChange(of: PlaceKey(engine.position, engine.positionName)) { _, _ in
            guard engine.travel == nil else { return }
            withAnimation(.easeInOut(duration: 1.2)) { camera = stageCamera(engine.position, phase: engine.phase) }
        }
        // The stage flies in from the globe when a session starts and back out when it ends.
        .onChange(of: engine.phase) { _, p in
            guard engine.travel == nil else { return }
            withAnimation(.easeInOut(duration: 2.2)) { camera = stageCamera(engine.position, phase: p) }
        }
    }

    /// Any dismissal (button, Close, swipe) counts as "seen"; the checklist never auto-opens twice.
    func markSetupSeen() { UserDefaults.standard.set(true, forKey: "setupSeen") }
}

/// Equatable key for the camera follow: the coordinate plus the name, so `onChange` fires on either.
struct PlaceKey: Equatable {
    let lat: Double
    let lon: Double
    let name: String
    init(_ c: CLLocationCoordinate2D, _ n: String) { lat = c.latitude; lon = c.longitude; name = n }
}

/// The one button that matters, pinned above the tab bar so it is never below the fold.
struct PrimaryActionBar: View {
    @EnvironmentObject var engine: SpoofEngine
    @EnvironmentObject var ready: Readiness
    @Binding var showSetup: Bool

    var body: some View {
        Group {
            if !ready.allGood && engine.phase == .idle {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    showSetup = true
                } label: { Label("Finish setup", systemImage: "checklist") }
                .buttonStyle(Button3D())
            } else {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    switch engine.phase {
                    case .active: engine.disconnect()
                    case .connecting: engine.cancelConnect()
                    case .idle: engine.connect()
                    }
                } label: {
                    Text(engine.phase == .active ? "Disconnect" : engine.phase == .connecting ? "Cancel" : "Connect")
                }
                // Disconnect is the red action while spoofing; Cancel stays the plain dark one.
                .buttonStyle(Button3D(dark: engine.phase != .idle, danger: engine.phase == .active))
                .accessibilityHint(engine.phase == .connecting ? "Stops the connection attempt" : "")
            }
        }
        .padding(.horizontal, 16)
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
                        Image(systemName: items[i].0).font(.title3.weight(.semibold))
                        Text(items[i].1).font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(tab == i ? .white : Theme.dim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(tab == i ? Color.white.opacity(0.1) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(items[i].1)
                .accessibilityAddTraits(tab == i ? [.isSelected] : [])
            }
        }
        .padding(5)
        .background(.ultraThinMaterial)
        .background(Theme.bg.opacity(0.6))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.6), radius: 20, y: 10)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
}

// MARK: - Home

/// Camera altitudes for the stage map: the whole planet while nothing is running, city scale once the phone
/// actually appears somewhere. The stage flies between the two on phase changes.
let globeDistance: Double = 18_000_000
let cityDistance: Double = 60_000
let homeSpan: CLLocationDistance = 3000

func stageCamera(_ c: CLLocationCoordinate2D, phase: SpoofEngine.Phase) -> MapCameraPosition {
    .camera(MapCamera(centerCoordinate: c, distance: phase == .idle ? globeDistance : cityDistance, heading: 0, pitch: 0))
}

/// A region that shows every point with some padding around it.
func regionFitting(_ pts: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
    let lats = pts.map(\.latitude), lons = pts.map(\.longitude)
    guard let minLat = lats.min(), let maxLat = lats.max(), let minLon = lons.min(), let maxLon = lons.max() else {
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0), latitudinalMeters: homeSpan, longitudinalMeters: homeSpan)
    }
    let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
    let span = MKCoordinateSpan(latitudeDelta: min(170, max((maxLat - minLat) * 1.4, 0.02)),
                                longitudeDelta: min(340, max((maxLon - minLon) * 1.4, 0.02)))
    return MKCoordinateRegion(center: center, span: span)
}

/// Home = a full-bleed map "stage" (the world, Proton-style) with the status pill and the place name written over
/// its lower edge, then a scrolling column of cards. The map is outside the scroll view, so panning it never
/// fights the page and the cards never cover it.
struct HomeView: View {
    @EnvironmentObject var engine: SpoofEngine
    @EnvironmentObject var ready: Readiness
    @EnvironmentObject var store: PlaceStore
    @ObservedObject var net = NetworkMonitor.shared
    @Binding var tab: Int
    @Binding var showSetup: Bool
    @Binding var camera: MapCameraPosition
    @State private var now = Date()
    @State private var pending: CLLocationCoordinate2D?
    /// Tracks the live camera so the single zoom button knows which way to go.
    @State private var zoomedOut = true
    @AppStorage("mapHintSeen") private var mapHintSeen = false

    /// While the link is being rebuilt the phone shows its REAL location, so that state must not look like "Spoofing".
    var statusColor: Color {
        switch engine.phase {
        case .active: return engine.rebuilding ? Theme.warn : Theme.ok
        case .connecting: return Theme.warn
        // The error card carries the red; the headline is not the failure. Before setup the pill is the
        // "action needed" amber, same as the brand-bar VPN dot.
        case .idle: return ready.allGood ? Theme.idle : Theme.warn
        }
    }
    var statusText: String {
        switch engine.phase {
        case .active: return engine.rebuilding ? "Reconnecting…" : "Spoofing"
        case .connecting: return "Connecting…"
        case .idle: return ready.allGood ? "Not connected" : "Setup needed"
        }
    }
    /// Small caps pill copy; the session clock runs while spoofing.
    var pillText: String {
        switch engine.phase {
        case .active:
            if engine.rebuilding { return "RECONNECTING" }
            if let t = engine.connectedAt { return "SPOOFING · " + Geo.fmtClock(now.timeIntervalSince(t)) }
            return "SPOOFING"
        case .connecting: return "CONNECTING"
        case .idle: return ready.allGood ? "NOT CONNECTED" : "SETUP NEEDED"
        }
    }
    /// The stage takes the top ~46 % of the screen (never under 300 pt) and runs up under the status bar.
    var stageHeight: CGFloat { max(300, UIScreen.main.bounds.height * 0.46) }

    var body: some View {
        VStack(spacing: 0) {
            stage.frame(height: stageHeight)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    // The failure comes first; the step list under it says where it stopped. Steps are hidden once
                    // the session is active (the engine clears them then anyway).
                    if let err = engine.error { errorCard(err).transition(.move(edge: .top).combined(with: .opacity)) }
                    if !engine.steps.isEmpty && engine.phase != .active { stepsCard.transition(.move(edge: .top).combined(with: .opacity)) }
                    if engine.travel != nil { travelCard.transition(.opacity) }
                    if net.cellularOnly && !ready.vpnUp && engine.phase != .active { cellularTip.transition(.opacity) }
                    quickPlaces
                    locationCard
                    Color.clear.frame(height: 8)
                }
                .padding(.top, 10)
                .animation(.spring(duration: 0.4), value: engine.steps.isEmpty)
                .animation(.spring(duration: 0.4), value: engine.error == nil)
                .animation(.spring(duration: 0.4), value: engine.travel == nil)
                .animation(.spring(duration: 0.4), value: engine.phase)
                .animation(.easeOut(duration: 0.2), value: net.cellularOnly && !ready.vpnUp)
            }
        }
        .task {
            // Session clock / "last push" ticker; cancelled with the view.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
            }
        }
    }

    // MARK: stage

    var stage: some View {
        ZStack(alignment: .top) {
            stageMap.ignoresSafeArea(edges: .top)
            if zoomedOut { Starfield().ignoresSafeArea(edges: .top).transition(.opacity) }
            // Scrims: a legible brand bar under the status bar, and a fade into the page so the cards sit on black.
            VStack(spacing: 0) {
                // 150 = ~59 safe area + 4 + 44 pill + ~40 of fade, so the bar is scrimmed on every device.
                LinearGradient(stops: [.init(color: Theme.bg.opacity(0.75), location: 0),
                                       .init(color: Theme.bg.opacity(0.4), location: 0.55),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 150)
                Spacer(minLength: 0)
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: Theme.bg.opacity(0.55), location: 0.45),
                                       .init(color: Theme.bg, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: max(170, stageHeight * 0.5))
            }
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            VStack(spacing: 0) {
                brandBar
                // One zoom toggle: the globe while zoomed in, the place while zoomed out.
                HStack {
                    Spacer()
                    mapButton(zoomedOut ? "scope" : "globe.americas.fill", zoomedOut ? "Zoom to the place" : "Show the whole world") {
                        withAnimation(.easeInOut(duration: 1.0)) {
                            camera = .camera(MapCamera(centerCoordinate: engine.position, distance: zoomedOut ? cityDistance : globeDistance, heading: 0, pitch: 0))
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 10)
                Spacer(minLength: 0)
                stageFooter
            }
        }
        .animation(.easeInOut(duration: 0.6), value: zoomedOut)
    }

    var stageMap: some View {
        MapReader { proxy in
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                Annotation("", coordinate: engine.position) { PulseDot(live: engine.phase != .idle) }
                if let tr = engine.travel {
                    Annotation("", coordinate: tr.to) { Circle().fill(.white).frame(width: 12, height: 12).overlay(Circle().stroke(Theme.bg, lineWidth: 2)) }
                    MapPolyline(coordinates: [engine.position, tr.to], contourStyle: .geodesic).stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [4, 6]))
                }
                if let p = pending {
                    // Bottom anchor: the pin's tip sits on the tapped point, not its centre.
                    Annotation("", coordinate: p, anchor: .bottom) { Image(systemName: "mappin").font(.title2).foregroundStyle(.white).shadow(radius: 4) }
                }
            }
            // Muted standard style = the monochrome world of the desktop app; realistic elevation gives the 3D globe.
            .mapStyle(.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
            .grayscale(1)   // the monochrome world; the annotations are drawn in white/black so they survive the filter
            .mapControlVisibility(.hidden)
            .onMapCameraChange(frequency: .onEnd) { ctx in zoomedOut = ctx.camera.distance > 1_500_000 }
            // A double-tap is the zoom gesture; registering it first keeps it from dropping a pin.
            .onTapGesture(count: 2) { }
            .onTapGesture { pt in
                // Drop a pin first; nothing moves until "Go here" is confirmed.
                if let c = proxy.convert(pt, from: .local) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeOut(duration: 0.15)) { pending = c }
                    mapHintSeen = true
                }
            }
        }
    }

    var brandBar: some View {
        HStack(spacing: 10) {
            Image("Logo").resizable().scaledToFit().frame(width: 26, height: 26)
            Text("Mirage Go").font(.headline)
            Spacer()
            Button {
                if !ready.vpnInstalled { VPNHelper.openStore() } else if !ready.vpnUp { VPNHelper.open() }
            } label: {
                HStack(spacing: 6) {
                    StatusDot(color: ready.vpnUp ? Theme.ok : Theme.warn)
                    Text(ready.vpnInstalled ? (ready.vpnUp ? (engine.isActive ? "Link ready · keep it on" : "Link ready") : "Link off") : "Get link app").font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                .clipShape(Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ready.vpnInstalled ? (ready.vpnUp ? (engine.isActive ? "VPN connected, keep it connected while spoofing" : "VPN connected") : "VPN off, tap to open LocalDev VPN") : "LocalDev VPN not installed, tap to get it from the App Store")
        }
        .padding(.horizontal, 20).padding(.top, 4)
    }

    /// Bottom of the stage: the status pill, the place the phone appears at (the headline) and one line of context;
    /// or, while a pin is pending, the confirm bar.
    @ViewBuilder var stageFooter: some View {
        Group {
            if let p = pending {
                pendingBar(p)
            } else {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        statusPill
                        Text(engine.travel?.name ?? engine.positionName)
                            .font(.system(size: 32, weight: .bold, design: .rounded)).foregroundStyle(.white)
                            .lineLimit(2).minimumScaleFactor(0.85)
                            .contentTransition(.opacity)
                            .animation(.easeInOut(duration: 0.25), value: engine.travel?.name ?? engine.positionName)
                        Text(subline).font(.footnote).foregroundStyle(Theme.muted)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 20).padding(.bottom, 12)
                .contentShape(Rectangle())   // taps on the text band must never fall through and drop a pin
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: pending == nil)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    var statusPill: some View {
        HStack(spacing: 7) {
            Circle().fill(statusColor).frame(width: 8, height: 8).shadow(color: statusColor.opacity(0.9), radius: 5)
            Text(pillText).font(.caption.weight(.bold)).tracking(0.7).monospacedDigit().foregroundStyle(statusColor)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .background(statusColor.opacity(0.10))
        .overlay(Capsule().stroke(statusColor.opacity(0.35), lineWidth: 1))
        .clipShape(Capsule())
        .animation(.easeOut(duration: 0.25), value: engine.phase)
        .accessibilityLabel(statusText)
    }

    func mapButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        GlassCircleButton(symbol: symbol, label: label, action: action)
    }

    /// Same rhythm as the normal footer (pill, headline, detail) so the stage does not jump when a pin drops.
    func pendingBar(_ p: CLLocationCoordinate2D) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            statusPill
            Text("Dropped pin")
                .font(.system(size: 32, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .lineLimit(2).minimumScaleFactor(0.85)
            Text(Geo.fmt(p)).font(.footnote.monospacedDigit()).foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                // Same behaviour as a Places tap: when idle and set up, "Go here" actually connects.
                Button(ready.allGood || engine.phase != .idle ? "Go here" : "Pick here") {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    engine.pick(p, name: "Dropped pin")
                    pending = nil
                    if engine.phase == .idle && ready.allGood { engine.connect() }
                    // Give the pin a real name when the phone is online; skipped if the user has moved on since.
                    // While travelling the pin is the destination, so rename the travel (arrival copies its name).
                    Task {
                        if let pm = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: p.latitude, longitude: p.longitude)).first,
                           let n = pm.name ?? pm.locality,
                           Geo.distance(engine.travel?.to ?? engine.position, p) < 2 {
                            if engine.travel != nil { engine.travel?.name = n } else { engine.positionName = n }
                            AppSettings.shared.lastName = n
                        }
                    }
                }
                .buttonStyle(Button3D(compact: true))
                mapButton("xmark", "Remove pin") { withAnimation(.easeOut(duration: 0.15)) { pending = nil } }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 20).padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    var subline: String {
        if engine.phase == .active && engine.rebuilding { return "The link dropped — your real location may show until it is back" }
        if engine.phase == .active {
            if let tr = engine.travel { return "On the way · \(Geo.fmtDist(max(0, tr.dist * (1 - engine.travelProgress)))) to go" }
            let ago = engine.lastSetAt.map { Int(now.timeIntervalSince($0)) } ?? 0
            return ago > 15
                ? "Every app sees this place · last push \(ago)s ago — link may be stalling"
                : "Every app on this iPhone sees this place"
        }
        if engine.phase == .connecting { return "Setting up the link to this phone" }
        if !ready.vpnInstalled { return "Install LocalDev VPN to get started" }
        if !ready.pairing { return "Import the pairing file from the PC" }
        return mapHintSeen ? "Press Connect to appear here" : "Press Connect to appear here · tap the map to pick a spot"
    }

    // MARK: cards

    /// One-tap destinations: favourites first, then the presets. Same behaviour as a tap on the Places tab.
    var quickPlaces: some View {
        // Favourites first, then most recently used, then by name.
        let list = store.places.sorted { ($0.fav ? 0 : 1, -($0.used ?? 0), $0.name) < ($1.fav ? 0 : 1, -($1.used ?? 0), $1.name) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("QUICK PLACES").font(.caption.weight(.semibold)).foregroundStyle(Theme.header)
                Spacer()
                Button { tab = 1 } label: {
                    HStack(spacing: 3) {
                        Text("All places")
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 30)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(list) { p in
                        let selected = Geo.distance(engine.position, p.coordinate) < 2
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            store.touch(p)
                            engine.pick(p.coordinate, name: p.name)
                            if engine.phase == .idle && ready.allGood { engine.connect() }
                        } label: {
                            HStack(spacing: 8) {
                                Text(p.icon).font(.body)
                                Text(p.name).font(.subheadline.weight(.semibold)).foregroundStyle(selected ? .black : .white).lineLimit(1)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(selected ? Color.white : Theme.card)
                            .overlay(Capsule().stroke(selected ? Color.white : Theme.line, lineWidth: 1))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    var stepsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(engine.phase == .connecting ? "CONNECTING" : "STOPPED").font(.caption.weight(.semibold)).foregroundStyle(Theme.header)
                    Spacer()
                    Text("\(engine.steps.filter { $0.status == "done" }.count)/\(engine.steps.count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.dim)
                }
                ForEach(engine.steps) { s in
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().stroke(stepColor(s.status), lineWidth: 1.5).frame(width: 14, height: 14)
                            if s.status == "done" { Circle().fill(Theme.ok).frame(width: 14, height: 14); Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.black) }
                            if s.status == "busy" { ProgressView().scaleEffect(0.5).tint(Theme.warn) }
                            if s.status == "fail" { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.danger) }
                        }
                        Text(s.label).foregroundStyle(s.status == "todo" ? Theme.dim : s.status == "fail" ? Theme.danger : .white)
                        if !s.detail.isEmpty { Text(s.detail).foregroundStyle(Theme.dim).lineLimit(1) }
                        Spacer()
                    }
                    .font(.footnote)
                    .animation(.easeOut(duration: 0.2), value: s.status)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    var travelCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    StatusDot(color: Theme.ok).padding(.top, 5)
                    Text("Travelling to \(engine.travel?.name ?? "")").font(.subheadline.weight(.semibold))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text("\(Geo.fmtDist(max(0, (engine.travel?.dist ?? 0) * (1 - engine.travelProgress)))) · \(Geo.fmtDur(engine.travelETA))")
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.muted).lineLimit(1).layoutPriority(1)
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
        let failed = engine.steps.first { $0.status == "fail" }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                // The human hint is the headline; the raw engine string is the detail.
                Text(engine.hint ?? err).font(.subheadline).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            }
            if engine.hint != nil { Text(err).font(.footnote).foregroundStyle(Theme.muted).textSelection(.enabled) }
            if let failed { Text("Stopped at: " + failed.label).font(.caption).foregroundStyle(Theme.dim) }
            HStack {
                Button("Setup checklist") { showSetup = true }
                    .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                    .padding(.vertical, 10).padding(.trailing, 12).contentShape(Rectangle())
                Spacer()
                Button("Dismiss") { engine.error = nil; engine.hint = nil; engine.steps = [] }
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    .padding(.vertical, 10).padding(.leading, 12).contentShape(Rectangle())
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
                    Text("Turn Airplane Mode on, connect LocalDev VPN, press Connect, then turn cellular back on (leave Airplane Mode on).").font(.footnote).lineSpacing(2).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    /// The exact coordinates (the name is already the headline on the stage).
    var locationCard: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "location.fill").font(.callout).foregroundStyle(Theme.muted).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Coordinates").font(.caption).foregroundStyle(Theme.muted)
                    Text(Geo.fmt(engine.position)).font(.subheadline.monospacedDigit())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
    }

    func stepColor(_ s: String) -> Color { s == "done" ? Theme.ok : s == "busy" ? Theme.warn : s == "fail" ? Theme.danger : Theme.dim }
}

/// The position marker. Deliberately monochrome: the map is under `.grayscale(1)`, so any colour here would be
/// desaturated anyway; the status colour lives in the pill and the brand bar instead.
struct PulseDot: View {
    /// The rings only pulse while a session is running; idle is a plain marker.
    var live: Bool = true
    var body: some View {
        ZStack {
            if live { PulseRings() }
            Circle().fill(.white).frame(width: 14, height: 14)
                .overlay(Circle().stroke(Theme.bg, lineWidth: 3))
                .shadow(color: .black.opacity(0.6), radius: 6)
        }
    }
}

/// Own view so its @State is created fresh each time the rings are inserted: the animation starts from the
/// collapsed state on every Connect instead of being stuck at its end state.
struct PulseRings: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.35)).frame(width: 50, height: 50).scaleEffect(pulse ? 1.7 : 0.5).opacity(pulse ? 0 : 0.7)
                .animation(.easeOut(duration: 2.2).repeatForever(autoreverses: false), value: pulse)
            Circle().fill(.white.opacity(0.35)).frame(width: 50, height: 50).scaleEffect(pulse ? 1.2 : 0.4).opacity(pulse ? 0 : 0.5)
                .animation(.easeOut(duration: 2.2).repeatForever(autoreverses: false).delay(1.1), value: pulse)
        }
        .onAppear { if !reduceMotion { pulse = true } }
    }
}

// MARK: - Places

/// Address / point-of-interest search backed by MapKit's completer.
final class SearchModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" { didSet { completer.queryFragment = query; pending = query.count >= 3 } }
    @Published var results: [MKLocalSearchCompletion] = []
    /// The completer reported an error (offline is the normal state on cellular with Airplane Mode on).
    @Published var failed = false
    /// A completer round-trip is in flight for the current query, so an empty `results` is not "no matches" yet.
    @Published var pending = false
    /// An MKLocalSearch for a tapped result is in flight (1-3 s); the row shows a spinner and taps are ignored.
    @Published var resolving = false
    /// title + subtitle of the completion being resolved, so only that row spins.
    @Published var resolvingKey: String?
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func completerDidUpdateResults(_ c: MKLocalSearchCompleter) { results = c.results; failed = false; pending = false }
    func completer(_ c: MKLocalSearchCompleter, didFailWithError error: Error) { results = []; failed = true; pending = false }

    @MainActor
    func resolve(_ completion: MKLocalSearchCompletion) async -> CLLocationCoordinate2D? {
        resolving = true; resolvingKey = completion.title + completion.subtitle
        defer { resolving = false; resolvingKey = nil }
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
        guard let response = try? await search.start() else { return nil }
        return response.mapItems.first?.placemark.coordinate
    }

    func clear() { query = ""; results = []; failed = false }
}

struct PlacesView: View {
    @EnvironmentObject var engine: SpoofEngine
    @EnvironmentObject var store: PlaceStore
    @EnvironmentObject var ready: Readiness
    @StateObject private var search = SearchModel()
    @Binding var tab: Int
    @State private var naming = false
    @State private var newName = ""
    @State private var pendingDelete: Place?
    @State private var coordsEntry = false
    @State private var latText = ""
    @State private var lonText = ""
    @State private var searchError: String?
    /// The coordinates dialog's own message, so a rejected entry never flashes in the search card.
    @State private var coordsError: String?
    @State private var renaming: Place?
    @FocusState private var searchFocused: Bool

    var favs: [Place] { store.places.filter { $0.fav }.sorted { $0.name < $1.name } }
    var rest: [Place] { store.places.filter { !$0.fav }.sorted { $0.name < $1.name } }
    /// What "Save map point" stores: the destination while travelling (position is an interpolated road point then).
    var saveTarget: CLLocationCoordinate2D { engine.travel?.to ?? engine.position }
    var alreadySaved: Bool { engine.travel == nil && store.places.contains { Geo.distance($0.coordinate, engine.position) < 2 } }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                header
                searchCard
                if favs.isEmpty { favHint } else { section("Favorites", favs) }
                section(favs.isEmpty ? "All places" : "More places", rest)
                Color.clear.frame(height: 8)
            }
        }
        .overlay(alignment: .top) { TopScrim() }
        .scrollDismissesKeyboard(.interactively)
        // A stale red error must not persist while the user retypes.
        .onChange(of: search.query) { _, _ in searchError = nil }
        .alert("Save this point", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") {
                var n = newName.trimmingCharacters(in: .whitespaces)
                if n.isEmpty { n = "My place" }
                if store.places.contains(where: { $0.name == n }) { n += " 2" }
                withAnimation { store.add(name: n, at: saveTarget, icon: "📍") }
                if engine.travel == nil { engine.positionName = n; AppSettings.shared.lastName = n }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text(Geo.fmt(saveTarget)) }
        .alert("Enter coordinates", isPresented: $coordsEntry) {
            TextField("Latitude (e.g. 34.0522)", text: $latText).keyboardType(.numbersAndPunctuation)
            TextField("Longitude (e.g. -118.2437)", text: $lonText).keyboardType(.numbersAndPunctuation)
            Button("Go") {
                if let lat = Double(latText.trimmingCharacters(in: .whitespaces)), let lon = Double(lonText.trimmingCharacters(in: .whitespaces)),
                   (-90...90).contains(lat), (-180...180).contains(lon) {
                    latText = ""; lonText = ""; coordsError = nil
                    go(CLLocationCoordinate2D(latitude: lat, longitude: lon), name: "Typed coordinates")
                } else {
                    // Keep what was typed and re-open the dialog with the message in it, instead of surfacing the
                    // error in the search card after the dialog has closed.
                    coordsError = "That doesn't look right. Latitude is -90 to 90, longitude -180 to 180."
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        coordsEntry = true
                    }
                }
            }
            Button("Cancel", role: .cancel) { latText = ""; lonText = ""; coordsError = nil }
        } message: { Text(coordsError ?? "Decimal degrees, as shown on any map app.") }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let r = renaming {
                    let n = newName.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty {
                        store.rename(r, to: n)
                        if engine.positionName == r.name { engine.positionName = n; AppSettings.shared.lastName = n }
                        if engine.travel?.name == r.name { engine.travel?.name = n }
                    }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Delete \(pendingDelete?.name ?? "")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) { if let p = pendingDelete { withAnimation { store.delete(p) } }; pendingDelete = nil }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    /// Select the place; only start a session when setup is complete (Home shows "Finish setup" otherwise).
    func go(_ c: CLLocationCoordinate2D, name: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        engine.pick(c, name: name)
        if engine.phase == .idle && ready.allGood { engine.connect() }
        search.clear(); searchFocused = false
        tab = 0
    }

    /// Rounded title (same face as the Home headline) with the save-point button in the title row.
    var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("Places").font(.system(size: 34, weight: .bold, design: .rounded))
                Spacer()
                GlassCircleButton(symbol: "plus", label: alreadySaved ? "Current point already saved" : "Save the current map point") {
                    let n = engine.travel?.name ?? engine.positionName
                    newName = Geo.isGeneric(n) ? "" : n
                    naming = true
                }
                .disabled(alreadySaved).opacity(alreadySaved ? 0.4 : 1)
            }
            Text("Tap to go there · hold for more").font(.footnote).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 20).padding(.top, 24)   // clears the TopScrim so the title is never under it at rest
    }

    /// Presets ship unstarred, so the first run needs one line saying what the star does.
    var favHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "star").foregroundStyle(Theme.dim)
            Text("Star places to pin them here and first on Home.").font(.footnote).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 30)
    }

    var searchCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
                TextField("Search an address or place", text: $search.query)
                    .textFieldStyle(.plain).submitLabel(.search).focused($searchFocused)
                    .autocorrectionDisabled()
                    .onSubmit { if let first = search.results.first { pick(first) } }
                if search.query.isEmpty {
                    // The coordinates entry lives in the field while it is empty; the clear button takes the slot while typing.
                    Button { searchError = nil; coordsError = nil; coordsEntry = true } label: {
                        Image(systemName: "number").foregroundStyle(Theme.dim).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Type coordinates")
                } else {
                    Button { search.clear() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.dim).frame(width: 44, height: 44) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12).frame(minHeight: 48)
            if let e = searchError {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption.weight(.semibold)).foregroundStyle(Theme.danger)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
            // Offline is this app's normal state on cellular, so an empty list needs to say why it is empty.
            if !search.query.isEmpty && search.results.isEmpty {
                if search.failed {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "wifi.slash").foregroundStyle(Theme.warn)
                        Text("No internet, so search is off. Tap the map on Home, or use # to type coordinates.")
                            .font(.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                } else {
                    Text(search.query.count < 3 ? "Keep typing…" : search.pending ? "Searching…" : "No matches")
                        .font(.caption).foregroundStyle(Theme.dim).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            }
            if !search.results.isEmpty && !search.query.isEmpty {
                Divider().overlay(Theme.line)
                ForEach(Array(search.results.prefix(6).enumerated()), id: \.offset) { _, r in
                    Button { pick(r) } label: {
                        HStack(spacing: 10) {
                            if search.resolvingKey == r.title + r.subtitle { ProgressView().tint(Theme.muted) } else { Image(systemName: "mappin.circle").foregroundStyle(Theme.muted) }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                                if !r.subtitle.isEmpty { Text(r.subtitle).font(.caption).foregroundStyle(Theme.dim).lineLimit(1) }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
    }

    func pick(_ r: MKLocalSearchCompletion) {
        guard !search.resolving else { return }   // a second tap must not start a second go()
        searchError = nil
        Task {
            if let c = await search.resolve(r) { go(c, name: r.title) }
            else { searchError = "Could not look that place up — check you have internet." }
        }
    }

    func section(_ title: String, _ items: [Place]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Theme.header).padding(.horizontal, 30)
            VStack(spacing: 0) {
                ForEach(items) { p in
                    placeRow(p)
                    if p.id != items.last?.id { Divider().overlay(Theme.line).padding(.leading, 64) }
                }
            }
            .background(Theme.card)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    /// A real Button (pressed wash, VoiceOver button trait) with the star kept outside it as a trailing overlay,
    /// so the two taps never nest. 56 pt tall: 44 min content + 6 top/bottom.
    func placeRow(_ p: Place) -> some View {
        let selected = Geo.distance(engine.position, p.coordinate) < 2
        // "Here" only while the channel is really open; during a rebuild the phone shows its real location.
        let here = engine.isActive && !engine.rebuilding
        return ZStack(alignment: .trailing) {
            Button { store.touch(p); go(p.coordinate, name: p.name) } label: {
                HStack(spacing: 12) {
                    Text(p.icon).font(.title3).frame(width: 36, height: 36).background(Theme.card2)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(selected ? Color.white : .clear, lineWidth: 1.5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        // Coordinates only where the name is weak (user-saved points); presets read as icon + name.
                        if p.custom { Text(Geo.fmt(p.coordinate)).font(.caption.monospacedDigit()).foregroundStyle(Theme.dim) }
                    }
                    Spacer()
                    if selected {
                        Text(here ? "Here" : "Selected").font(.caption2.weight(.bold)).padding(.horizontal, 8).padding(.vertical, 4).background(here ? Theme.ok : Color.white).foregroundStyle(.black).clipShape(Capsule())
                    }
                }
                .frame(minHeight: 44)
                .padding(.leading, 12).padding(.trailing, 60).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressRow())
            .accessibilityLabel(p.name)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            Button { UISelectionFeedbackGenerator().selectionChanged(); withAnimation { store.toggleFav(p) } } label: {
                Image(systemName: p.fav ? "star.fill" : "star").foregroundStyle(p.fav ? .white : Theme.dim)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(p.fav ? "Remove from favourites" : "Add to favourites")
            .padding(.trailing, 8)
        }
        .background(selected ? Color.white.opacity(0.06) : .clear)
        .contextMenu {
            Button { withAnimation { store.toggleFav(p) } } label: { Label(p.fav ? "Unfavourite" : "Favourite", systemImage: "star") }
            Button { UIPasteboard.general.string = Geo.fmt(p.coordinate) } label: { Label("Copy coordinates", systemImage: "doc.on.doc") }
            if p.custom {
                Button { newName = p.name; renaming = p } label: { Label("Rename", systemImage: "pencil") }
                Button(role: .destructive) { pendingDelete = p } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }
}

// MARK: - Settings

func isIPv4(_ s: String) -> Bool {
    var tmp = in_addr()
    return s.withCString { inet_pton(AF_INET, $0, &tmp) } == 1
}

/// Small capsule for secondary row actions (open, copy, reset); the 3D button stays for the primary ones.
struct RowAction: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Theme.card2)
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct SettingsView: View {
    enum Field: Hashable { case ip, port }

    @EnvironmentObject var engine: SpoofEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ready: Readiness
    @ObservedObject var log = AppLog.shared
    @Binding var showSetup: Bool
    @State private var importing = false
    @State private var importError: String?
    @State private var busy = ""
    @State private var downloadError: String?
    // Seeded from the store (not in onAppear) so the validation lines never flash red on the first frame.
    @State private var ipText = AppSettings.shared.deviceIP
    @State private var portText = String(AppSettings.shared.devicePort)
    @State private var showLog = false
    @State private var copied = false
    @FocusState private var focus: Field?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings").font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("How the phone moves, and whether it is ready.").font(.footnote).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 20).padding(.top, 24)   // clears the TopScrim so the title is never under it at rest
                movement
                phoneLink
                advanced
                logGroup
                about
                Color.clear.frame(height: 8)
            }
        }
        .overlay(alignment: .top) { TopScrim() }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus = nil }.fontWeight(.semibold).tint(.white)
            }
        }
        .onChange(of: focus) { _, f in
            // Commit the buffered fields only when they lose focus, so half-typed values never reach the engine.
            if f != .ip {
                if isIPv4(ipText) { settings.deviceIP = ipText } else { ipText = settings.deviceIP }
            }
            if f != .port {
                if let p = Int(portText), p > 0, p < 65536 { settings.devicePort = p } else { portText = String(settings.devicePort) }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .data, .item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let u = urls.first else { return }
                let ok = u.startAccessingSecurityScopedResource()
                defer { if ok { u.stopAccessingSecurityScopedResource() } }
                do {
                    try PairingStore.install(from: u)
                    AppLog.shared.add("pairing file imported")
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    importError = nil
                } catch {
                    AppLog.shared.add("import failed: \(error.localizedDescription)")
                    importError = error.localizedDescription
                }
                ready.refresh()
            case .failure(let e): AppLog.shared.add("import cancelled: \(e.localizedDescription)")
            }
        }
    }

    // MARK: groups

    var movement: some View {
        group("Movement") {
            toggleRow("Realistic travel", "Glide to a new place at a real speed instead of jumping.", isOn: $settings.travel)
            speedChips
            sep
            toggleRow("GPS jitter", "Drift a few metres every few seconds, like a real GPS fix.", isOn: Binding(get: { settings.jitter }, set: { engine.setJitter($0) }))
            if settings.jitter {
                HStack {
                    Text("Max drift").font(.subheadline)
                    Slider(value: $settings.jitterMeters, in: 1...15, step: 1).tint(.white)
                    // Fixed width so "4 m" -> "15 m" does not shorten the track mid-drag.
                    Text("\(Int(settings.jitterMeters)) m").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.muted).frame(width: 40, alignment: .trailing)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: settings.jitter)
    }

    /// Home's quick-places chip language (selected = white/black) with a real label, instead of the grey segmented picker.
    var speedChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speed").font(.subheadline)
            HStack(spacing: 6) {
                ForEach(AppSettings.speeds, id: \.id) { s in
                    let on = settings.travelSpeed == s.id
                    Button { UISelectionFeedbackGenerator().selectionChanged(); settings.travelSpeed = s.id } label: {
                        Text(s.label).font(.subheadline.weight(.semibold))
                            .foregroundStyle(on ? .black : .white)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(on ? Color.white : Theme.card2)
                            .overlay(Capsule().stroke(on ? Color.white : Theme.line, lineWidth: 1))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                }
            }
            .animation(.easeOut(duration: 0.15), value: settings.travelSpeed)
        }
        .disabled(!settings.travel).opacity(settings.travel ? 1 : 0.4)
        .animation(.easeOut(duration: 0.15), value: settings.travel)
    }

    /// Status lines; the one fix action shows only while a row is amber, maintenance only when nothing is wrong.
    var phoneLink: some View {
        group("Phone link", action: ("Setup checklist", { showSetup = true })) {
            linkRow("LocalDev VPN", ready.vpnUp ? "Connected" : ready.vpnInstalled ? "Not connected" : "Not installed", ok: ready.vpnUp) {
                Button(ready.vpnInstalled ? "Open LocalDev VPN" : "Get LocalDev VPN") { if ready.vpnInstalled { VPNHelper.open() } else { VPNHelper.openStore() } }
            }
            sep
            linkRow("Pairing file", ready.pairing ? "Imported" : ready.pairingKind == "none" ? "Missing" : "Wrong kind", ok: ready.pairing) {
                Button("Import pairing file…") { importing = true }
                if let e = importError {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption.weight(.semibold)).foregroundStyle(Theme.danger)
                }
                Text("Or drop pairingFile.plist into the Mirage Go folder (Files app or Apple Devices file sharing); it is picked up automatically.").font(.footnote).lineSpacing(2).foregroundStyle(Theme.dim)
            }
            sep
            linkRow("Developer image", ready.ddiFiles ? (engine.ddiStatus == "mounted" ? "Mounted" : "Ready") : "Not downloaded", ok: ready.ddiFiles) {
                Button(busy.isEmpty ? "Download (16 MB)" : busy) { downloadImage(fresh: false) }.disabled(!busy.isEmpty)
                if let e = downloadError {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption.weight(.semibold)).foregroundStyle(Theme.danger)
                }
            }
            sep
            linkRow("Background location", authText, ok: ready.locationAuth == .authorizedAlways) {
                if ready.locationAuth == .authorizedWhenInUse {
                    // The one-shot "Always" upgrade prompt is asked here, in the foreground with nothing
                    // pending, so no app switch can dismiss it (it used to be burned inside Connect).
                    Button("Allow Always") { LocationKeeper.shared.requestAlwaysUpgrade() }
                } else if ready.locationAuth != .notDetermined {
                    // Before the first request the app is not listed in iOS Settings > Location, so there is nothing to open.
                    Button("Open iOS Settings") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }
                }
                if ready.locationAuth != .notDetermined {
                    Text("Set Location to Always so the spoof keeps running when the phone is locked.").font(.footnote).lineSpacing(2).foregroundStyle(Theme.dim)
                }
            }
            if ready.vpnUp && ready.pairing && ready.ddiFiles {
                HStack(spacing: 8) {
                    Button("Open VPN") { VPNHelper.open() }
                    Button(busy.isEmpty ? "Re-download image" : busy) { downloadImage(fresh: true) }.disabled(!busy.isEmpty)
                }
                .buttonStyle(RowAction())
            }
        }
        .animation(.easeOut(duration: 0.2), value: importError == nil)
        .animation(.easeOut(duration: 0.2), value: downloadError == nil)
        .animation(.easeOut(duration: 0.2), value: ready.locationAuth)
    }

    /// `fresh` deletes the three files first so the download really re-fetches them.
    func downloadImage(fresh: Bool) {
        Task {
            busy = "Downloading…"; downloadError = nil
            if fresh { DDIStore.removeAll() }
            do { try await DDIStore.download { s in busy = s } } catch { downloadError = error.localizedDescription }
            try? await Task.sleep(for: .seconds(1)); busy = ""; ready.refresh()
        }
    }

    var advanced: some View {
        group("Advanced") {
            HStack {
                Text("Device IP").font(.subheadline); Spacer()
                field("10.7.0.1", text: $ipText, kind: .ip)
            }
            // The value reverts on blur, so the error is only meaningful while the field is focused.
            if focus == .ip && !isIPv4(ipText) { Text("Not a valid IPv4 address").font(.caption).foregroundStyle(Theme.danger) }
            HStack {
                Text("Port").font(.subheadline); Spacer()
                field("49152", text: $portText, kind: .port)
            }
            if focus == .port && Int(portText).map({ $0 > 0 && $0 < 65536 }) != true { Text("Port must be 1–65535").font(.caption).foregroundStyle(Theme.danger) }
            Button("Reset to defaults") {
                settings.deviceIP = "10.7.0.1"; settings.devicePort = 49152
                ipText = settings.deviceIP; portText = String(settings.devicePort); focus = nil
            }
            .buttonStyle(RowAction())
            Text("Leave these unless LocalDev VPN shows a different address.").font(.footnote).lineSpacing(2).foregroundStyle(Theme.dim)
        }
    }

    /// A field that looks like one (card2 well, hairline, white ring while focused) so it is not mistaken for a status row.
    func field(_ placeholder: String, text: Binding<String>, kind: Field) -> some View {
        TextField(placeholder, text: text).multilineTextAlignment(.trailing).keyboardType(kind == .ip ? .decimalPad : .numberPad)
            .font(.subheadline.monospacedDigit()).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 7).frame(width: 150)
            .background(Theme.card2)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(focus == kind ? Color.white.opacity(0.5) : Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .focused($focus, equals: kind)
    }

    /// One line (latest entry, count, chevron) that expands to the scrolling log; keeps the nested scroll off the page by default.
    var logGroup: some View {
        group("Log") {
            Button { withAnimation(.easeOut(duration: 0.2)) { showLog.toggle() } } label: {
                HStack(spacing: 8) {
                    Text(log.lines.last ?? "Nothing yet").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(log.lines.count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.dim)
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Theme.dim)
                        .rotationEffect(.degrees(showLog ? 90 : 0))
                }
                .frame(minHeight: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showLog ? "Hide log" : "Show log")
            if showLog {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(log.lines.suffix(80).enumerated()), id: \.offset) { _, l in
                                Text(l).font(.system(size: 11, design: .monospaced)).foregroundStyle(l.contains("failed") || l.contains("lost") ? Theme.danger : Theme.muted)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 200)
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                    .onChange(of: log.lines.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
                Button(copied ? "Copied" : "Copy log") {
                    UIPasteboard.general.string = log.lines.joined(separator: "\n")
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                .buttonStyle(RowAction())
            }
        }
    }

    var about: some View {
        group("About") {
            kvRow("Version", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            Text("Only changes what this iPhone reports. It uses Apple's developer location service through LocalDev VPN; nothing is jailbroken and nothing leaves the phone.").font(.footnote).lineSpacing(2).foregroundStyle(Theme.dim)
        }
    }

    var authText: String {
        switch ready.locationAuth {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "While using"
        case .denied, .restricted: return "Denied"
        default: return "Asked on first Connect"
        }
    }

    // MARK: building blocks

    /// Header-cased title, optional trailing action (Home's "All places ›" pattern), one Card of rows.
    func group<Content: View>(_ title: String, action: (String, () -> Void)? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Theme.header)
                Spacer()
                if let a = action {
                    Button(action: a.1) {
                        HStack(spacing: 3) {
                            Text(a.0)
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                        }
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                    }
                }
            }
            .padding(.horizontal, 30)
            Card { VStack(alignment: .leading, spacing: 10) { content() } }.padding(.horizontal, 16)
        }
    }

    /// Hairline between row pairs inside a group.
    var sep: some View { Divider().overlay(Theme.line) }

    func toggleRow(_ title: String, _ desc: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.subheadline.weight(.semibold)); Text(desc).font(.caption).foregroundStyle(Theme.muted) }
        }
        .tint(Color(white: 0.7))
    }

    /// Title · dot · value on one line; the single fix action only while the row is not green.
    func linkRow<A: View>(_ k: String, _ v: String, ok: Bool, @ViewBuilder fix: () -> A) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(k).font(.subheadline)
                Spacer(minLength: 12)
                StatusDot(color: ok ? Theme.ok : Theme.warn).padding(.top, 6)
                Text(v).font(.subheadline).foregroundStyle(.white).multilineTextAlignment(.trailing).layoutPriority(1)
            }
            if !ok { fix().buttonStyle(Button3D(dark: true, compact: true)) }
        }
    }

    /// Plain key/value (no status dot) for facts that are not a state.
    func kvRow(_ k: String, _ v: String) -> some View {
        HStack { Text(k).font(.subheadline); Spacer(); Text(v).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.muted) }
    }
}

// MARK: - Setup checklist

struct SetupView: View {
    @EnvironmentObject var engine: SpoofEngine
    @EnvironmentObject var ready: Readiness
    @Environment(\.dismiss) private var dismiss
    /// True when presented as the first-launch full-screen cover (later opens are a sheet).
    var firstRun = false
    @State private var importing = false
    @State private var importError: String?
    @State private var busy = ""
    @State private var downloadError: String?
    @AppStorage("devModeConfirmed") private var devMode = false

    /// Step order on the page: Developer Mode, LocalDev VPN, Pairing file, Developer image.
    var done: [Bool] { [devMode, ready.vpnInstalled, ready.pairing, ready.ddiFiles] }
    var doneCount: Int { done.filter { $0 }.count }
    /// The developer image is fetched by Connect itself, so it does not gate "Done".
    var setupDone: Bool { devMode && ready.vpnInstalled && ready.pairing }
    /// The first open step gets the white button; the rest stay dark.
    var nextOpen: Int? { done.firstIndex(of: false) }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    wifiTip
                    devModeStep
                    vpnStep
                    pairingStep
                    ddiStep
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            // Pinned like Home's PrimaryActionBar, so it is never below the fold.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button(setupDone ? "Done — go Connect" : "Close for now") { dismiss() }
                    .buttonStyle(Button3D(dark: !setupDone))
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                    .background(
                        LinearGradient(colors: [Theme.bg.opacity(0), Theme.bg], startPoint: .top, endPoint: .bottom)
                            .padding(.top, -24).ignoresSafeArea().allowsHitTesting(false)
                    )
            }
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() }.foregroundStyle(.white) } }
            .onChange(of: doneCount) { old, new in
                if new > old { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .data, .item], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let u = urls.first {
                    let ok = u.startAccessingSecurityScopedResource()
                    defer { if ok { u.stopAccessingSecurityScopedResource() } }
                    do {
                        try PairingStore.install(from: u)
                        AppLog.shared.add("pairing file imported")
                        importError = nil
                    } catch {
                        AppLog.shared.add("import failed: \(error.localizedDescription)")
                        importError = error.localizedDescription
                    }
                    ready.refresh()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: pieces

    var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image("Logo").resizable().scaledToFit().frame(width: 44, height: 44)
            Text("Set up Mirage Go").font(.system(size: 28, weight: .bold, design: .rounded))
            Text(doneCount == 4 ? "All set. Close this and press Connect." : setupDone ? "Ready. The image downloads itself on the first Connect." : "\(doneCount) of 4 done · once, then it's just Connect")
                .font(.footnote).foregroundStyle(Theme.muted).contentTransition(.numericText())
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { i in Capsule().fill(done[i] ? Theme.ok : Theme.card2).frame(height: 4) }
            }
            .animation(.easeOut(duration: 0.3), value: doneCount)
        }
        .padding(.horizontal, 4).padding(.bottom, 2)
    }

    var wifiTip: some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "wifi").foregroundStyle(Theme.warn)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Do the first Connect on Wi-Fi").font(.subheadline.weight(.semibold))
                    Text("iOS will ask twice: tap Allow for the local network, and choose Always for location.").font(.footnote).lineSpacing(2).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    var devModeStep: some View {
        step(1, "Developer Mode",
             devMode ? "On" : "Settings → Privacy & Security → Developer Mode → On. The phone restarts once. Do this first — nothing below works without it.",
             ok: devMode, primary: nextOpen == 0) {
            Button("I turned it on") { devMode = true }
        }
    }

    /// Setup is about *installed*; Connect turns the tunnel on itself, so this step must not flip with it.
    var vpnStep: some View {
        step(2, "LocalDev VPN",
             !ready.vpnInstalled ? "Free app on the App Store. Install it, open it once, and tap Allow when iOS asks about a VPN."
                : ready.vpnUp ? "Installed and connected." : "Installed. Mirage Go turns it on for you when you press Connect.",
             ok: ready.vpnInstalled, primary: nextOpen == 1) {
            Button("Get LocalDev VPN") { VPNHelper.openStore() }
        }
    }

    var pairingStep: some View {
        step(3, "Pairing file",
             ready.pairing ? "Imported."
                : ready.pairingKind == "none" ? "Made on the PC while the phone is plugged in. It is usually pushed to the phone for you — if this isn't green yet, ask for pairingFile.plist and tap Import."
                : "This is the USB kind and won't work. Ask the PC for a new Remote pairing file and import that one.",
             ok: ready.pairing, primary: nextOpen == 2, error: importError) {
            Button("Import pairing file…") { importing = true }
        }
    }

    var ddiStep: some View {
        step(4, "Developer image (automatic)",
             ready.ddiFiles ? "Downloaded." : "16 MB. Mirage Go fetches it on the first Connect; download now to make that Connect faster.",
             ok: ready.ddiFiles, primary: false, error: downloadError) {
            Button(busy.isEmpty ? "Download now" : busy) {
                Task {
                    busy = "Downloading…"; downloadError = nil
                    do { try await DDIStore.download { s in busy = s } } catch { downloadError = error.localizedDescription }
                    try? await Task.sleep(for: .seconds(1)); busy = ""; ready.refresh()
                }
            }
            .disabled(!busy.isEmpty)
        }
    }

    func step<A: View>(_ n: Int, _ title: String, _ desc: String, ok: Bool, primary: Bool, error: String? = nil, @ViewBuilder action: () -> A) -> some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(ok ? Theme.ok : Theme.card2)
                        .overlay(Circle().stroke(ok ? .clear : Theme.line, lineWidth: 1))
                        .frame(width: 30, height: 30)
                    if ok { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.black) } else { Text("\(n)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white) }
                }
                .animation(.easeOut(duration: 0.25), value: ok)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline)
                    Text(desc).font(.footnote).lineSpacing(2).foregroundStyle(Theme.muted)
                    if let e = error {
                        Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption.weight(.semibold)).foregroundStyle(Theme.danger)
                    }
                    if !ok { action().buttonStyle(Button3D(dark: !primary, compact: true)).padding(.top, 4) }
                }
            }
        }
    }
}
