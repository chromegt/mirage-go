import SwiftUI

@main
struct MirageGoApp: App {
    @StateObject private var engine = SpoofEngine()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        FFILogging.start()
        PairingStore.adoptFromDocuments()
        Notify.request()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .environmentObject(AppSettings.shared)
                .environmentObject(PlaceStore.shared)
                .environmentObject(Readiness.shared)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    // A plist arrives via "Open in"; miragego:// is LocalDev VPN's callback after it connects (not a file).
                    if url.isFileURL {
                        let ok = url.startAccessingSecurityScopedResource()
                        defer { if ok { url.stopAccessingSecurityScopedResource() } }
                        do { try PairingStore.install(from: url); AppLog.shared.add("pairing file imported") }
                        catch { AppLog.shared.add("import failed: \(error.localizedDescription)") }
                    }
                    Readiness.shared.refresh()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                PairingStore.adoptFromDocuments()
                Readiness.shared.refresh()
                engine.onForeground()
            }
        }
    }
}
