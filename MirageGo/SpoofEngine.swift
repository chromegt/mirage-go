import Foundation
import CoreLocation
import UIKit

/// The spoof session: opens the loopback tunnel, mounts the developer image when needed, holds the location
/// channel open, re-sends the position every few seconds, and runs realistic travel + jitter.
@MainActor
final class SpoofEngine: ObservableObject {
    enum Phase: Equatable { case idle, connecting, active }
    struct Step: Identifiable, Equatable { let id: String; let label: String; var status: String; var detail: String = "" }
    struct Travel: Equatable { var to: CLLocationCoordinate2D; var name: String; var dist: Double; var speed: Double; var start: Date; var from: CLLocationCoordinate2D
        static func == (a: Travel, b: Travel) -> Bool { a.start == b.start }
    }

    @Published var phase: Phase = .idle
    @Published var steps: [Step] = []
    @Published var position: CLLocationCoordinate2D
    @Published var positionName: String
    @Published var travel: Travel?
    @Published var travelProgress: Double = 0
    @Published var error: String?
    @Published var hint: String?
    @Published var ddiStatus = "unknown"
    @Published var lastSetAt: Date?

    private var tunnel: DeviceTunnel?
    private var channel: LocationChannel?
    private var resendTimer: Timer?
    private var travelTimer: Timer?
    private var jitterTimer: Timer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var stopping = false
    private let settings = AppSettings.shared

    init() {
        position = CLLocationCoordinate2D(latitude: AppSettings.shared.lastLat, longitude: AppSettings.shared.lastLon)
        positionName = AppSettings.shared.lastName
    }

    var isActive: Bool { phase == .active }

    // MARK: picking

    func pick(_ c: CLLocationCoordinate2D, name: String) {
        settings.lastLat = c.latitude; settings.lastLon = c.longitude; settings.lastName = name
        if isActive && settings.travel && Geo.distance(position, c) > 3 {
            startTravel(to: c, name: name)
        } else {
            stopTravel()
            position = c; positionName = name
            if isActive { send() }
        }
    }

    // MARK: connect / disconnect

    func connect() {
        guard phase == .idle else { return }
        stopping = false
        error = nil; hint = nil
        phase = .connecting
        steps = [Step(id: "vpn", label: "LocalDev VPN", status: "todo"), Step(id: "pair", label: "Pairing file", status: "todo"),
                 Step(id: "tunnel", label: "Tunnel to the phone", status: "todo"), Step(id: "ddi", label: "Developer image", status: "todo"),
                 Step(id: "channel", label: "Location channel", status: "todo")]
        let target = position
        Task { await self.runConnect(target) }
    }

    private func step(_ id: String, _ status: String, _ detail: String = "") {
        if let i = steps.firstIndex(where: { $0.id == id }) { steps[i].status = status; steps[i].detail = detail }
    }

    private func fail(_ message: String, hint: String?) {
        AppLog.shared.add("connect failed: \(message)")
        for i in steps.indices where steps[i].status == "busy" { steps[i].status = "fail" }
        error = message; self.hint = hint
        phase = .idle
        teardownHandles()
    }

    private func runConnect(_ target: CLLocationCoordinate2D) async {
        // 1. VPN
        step("vpn", "busy")
        if !VPNHelper.tunnelUp {
            if VPNHelper.installed {
                VPNHelper.open()
                for _ in 0..<12 { try? await Task.sleep(nanoseconds: 500_000_000); if VPNHelper.tunnelUp { break } }
            }
            guard VPNHelper.tunnelUp else {
                fail("LocalDev VPN is not connected.", hint: VPNHelper.installed ? "Open LocalDev VPN and tap Connect, then come back." : "Install LocalDev VPN from the App Store first.")
                return
            }
        }
        step("vpn", "done")

        // 2. pairing file
        step("pair", "busy")
        guard PairingStore.present else {
            fail("No pairing file yet.", hint: "Import the pairing file made on the PC (Settings → Pairing file).")
            return
        }
        step("pair", "done", PairingStore.kind)

        // 3. tunnel
        step("tunnel", "busy")
        let ip = settings.deviceIP, port = UInt16(clamping: settings.devicePort), path = PairingStore.url.path
        var t: DeviceTunnel
        do {
            t = try await ffi { try DeviceTunnel.open(pairingPath: path, ip: ip, port: port) }
        } catch {
            let e = error as? FFIError
            let h: String
            if e?.code == -9 { h = "The pairing file could not be read. Import it again." }
            else if !VPNHelper.tunnelUp { h = "LocalDev VPN dropped. Open it, tap Connect, then try again." }
            else { h = "The phone did not accept the pairing file. Re-make it on the PC (plug in once) and import it again. Also make sure Wi-Fi is on, or Airplane Mode is on when you are on cellular." }
            fail("Tunnel failed: \(error.localizedDescription)", hint: h)
            return
        }
        step("tunnel", "done", "\(ip):\(port)")
        AppLog.shared.add("tunnel up via \(ip):\(port)")

        // 4. developer image
        step("ddi", "busy")
        if !t.serviceAvailable(DDIMounter.dtService) {
            var mounted = false
            do { mounted = try await ffi { try DDIMounter.isMounted(t) } } catch { AppLog.shared.add("mounted check: \(error.localizedDescription)") }
            if !mounted {
                if !DDIStore.present {
                    step("ddi", "busy", "downloading")
                    do { try await DDIStore.download { [weak self] s in Task { @MainActor in self?.step("ddi", "busy", s) } } }
                    catch { fail("Could not download the developer image: \(error.localizedDescription)", hint: "Connect to Wi-Fi with internet and try again."); t.close(); return }
                }
                step("ddi", "busy", "mounting (needs internet)")
                DDIMounter.progress = { [weak self] f in self?.step("ddi", "busy", "mounting \(Int(f * 100))%") }
                do {
                    try await ffi { try DDIMounter.mount(t, image: DDIStore.image, trustCache: DDIStore.trustCache, manifest: DDIStore.manifest) }
                    AppLog.shared.add("developer image mounted")
                } catch {
                    fail("Developer image could not be mounted: \(error.localizedDescription)", hint: "The phone needs internet for this step (Apple signs the image). Or plug the phone into the PC once; Mirage mounts it there."); t.close(); return
                }
            }
            // The RSD service list is captured at handshake time: reopen the tunnel so dtservicehub shows up.
            t.close()
            do { t = try await ffi { try DeviceTunnel.open(pairingPath: path, ip: ip, port: port) } }
            catch { fail("Tunnel failed after mounting: \(error.localizedDescription)", hint: "Try Connect again."); return }
            if !t.serviceAvailable(DDIMounter.dtService) {
                fail("The developer image is still not available.", hint: "Reboot the phone, open LocalDev VPN, and try again on Wi-Fi with internet."); t.close(); return
            }
        }
        ddiStatus = "mounted"
        step("ddi", "done")

        // 5. channel
        step("channel", "busy")
        let ch: LocationChannel
        do {
            ch = try await ffi { let c = try LocationChannel(tunnel: t); try c.set(lat: target.latitude, lon: target.longitude); return c }
        } catch {
            fail("Location service failed: \(error.localizedDescription)", hint: "Try Connect again. If it keeps failing, reboot the phone."); t.close(); return
        }
        step("channel", "done")
        tunnel = t; channel = ch
        phase = .active
        lastSetAt = Date()
        AppLog.shared.add("spoofing \(Geo.fmt(target))")
        beginKeepAlive()
        armResend()
        if settings.jitter { armJitter() }
    }

    func disconnect() {
        stopping = true
        stopTravel()
        resendTimer?.invalidate(); resendTimer = nil
        jitterTimer?.invalidate(); jitterTimer = nil
        let ch = channel, t = tunnel
        channel = nil; tunnel = nil
        ffiQueue.async {
            ch?.clear(); ch?.close(); t?.close()
        }
        endKeepAlive()
        phase = .idle
        steps = []
        AppLog.shared.add("real location restored")
    }

    func kill() {
        disconnect()
        error = nil; hint = nil
    }

    private func teardownHandles() {
        let ch = channel, t = tunnel
        channel = nil; tunnel = nil
        ffiQueue.async { ch?.close(); t?.close() }
        endKeepAlive()
    }

    // MARK: keep-alive + resend

    private func beginKeepAlive() {
        SilentAudioKeeper.shared.start()
        LocationKeeper.shared.start()
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "MirageGoSpoof") { [weak self] in
            guard let self, self.bgTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.bgTask); self.bgTask = .invalid
        }
    }

    private func endKeepAlive() {
        SilentAudioKeeper.shared.stop()
        LocationKeeper.shared.stop()
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
    }

    private func armResend() {
        resendTimer?.invalidate()
        let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.send() }
        }
        RunLoop.main.add(t, forMode: .common)
        resendTimer = t
    }

    /// Push the current position to the phone (also the health check: an error here means the link died).
    func send(_ override: CLLocationCoordinate2D? = nil) {
        guard isActive, let ch = channel else { return }
        let p = override ?? position
        ffiQueue.async { [weak self] in
            do {
                try ch.set(lat: p.latitude, lon: p.longitude)
                Task { @MainActor in self?.lastSetAt = Date() }
            } catch {
                Task { @MainActor in self?.linkLost(error.localizedDescription) }
            }
        }
    }

    private var rebuilding = false
    private func linkLost(_ why: String) {
        guard isActive, !rebuilding, !stopping else { return }
        rebuilding = true
        AppLog.shared.add("link lost (\(why)); rebuilding")
        let target = position
        resendTimer?.invalidate(); resendTimer = nil
        let ch = channel, t = tunnel
        channel = nil; tunnel = nil
        Task {
            await ffi { ch?.close(); t?.close() }
            var ok = false
            for attempt in 1...3 {
                if VPNHelper.tunnelUp, PairingStore.present {
                    do {
                        let nt = try await ffi { try DeviceTunnel.open(pairingPath: PairingStore.url.path, ip: self.settings.deviceIP, port: UInt16(clamping: self.settings.devicePort)) }
                        let nc = try await ffi { let c = try LocationChannel(tunnel: nt); try c.set(lat: target.latitude, lon: target.longitude); return c }
                        self.tunnel = nt; self.channel = nc; ok = true
                        AppLog.shared.add("rebuilt on attempt \(attempt)")
                        break
                    } catch { AppLog.shared.add("rebuild \(attempt): \(error.localizedDescription)") }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            self.rebuilding = false
            if ok { self.armResend() }
            else {
                self.phase = .idle; self.endKeepAlive(); self.stopTravel()
                self.error = "Spoof dropped: \(why)"; self.hint = "Check LocalDev VPN is connected (Wi-Fi on, or Airplane Mode on cellular) and press Connect."
                Notify.post("Mirage Go stopped", "The spoof dropped. Open Mirage Go to reconnect.")
            }
        }
    }

    func onForeground() {
        guard isActive else { return }
        send()
    }

    // MARK: travel

    func startTravel(to c: CLLocationCoordinate2D, name: String) {
        stopTravel()
        let from = position, dist = Geo.distance(from, c), speed = settings.speedMps
        travel = Travel(to: c, name: name, dist: dist, speed: speed, start: Date(), from: from)
        travelProgress = 0
        AppLog.shared.add("travelling \(Geo.fmtDist(dist)) at \(speed) m/s")
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tickTravel() } }
        RunLoop.main.add(t, forMode: .common)
        travelTimer = t
    }

    private func tickTravel() {
        guard let tr = travel else { return }
        let elapsed = Date().timeIntervalSince(tr.start)
        let frac = min(1, (elapsed * tr.speed) / max(tr.dist, 0.001))
        let p = frac >= 1 ? tr.to : Geo.destination(tr.from, bearing: Geo.bearing(tr.from, tr.to), meters: tr.dist * frac)
        position = p
        travelProgress = frac
        send()
        if frac >= 1 {
            positionName = tr.name
            stopTravel()
            AppLog.shared.add("arrived")
        }
    }

    func teleportNow() {
        guard let tr = travel else { return }
        stopTravel()
        position = tr.to; positionName = tr.name
        send()
    }

    func stopTravel() {
        travelTimer?.invalidate(); travelTimer = nil
        travel = nil
        travelProgress = 0
    }

    var travelETA: Double {
        guard let tr = travel else { return 0 }
        return max(0, tr.dist * (1 - travelProgress)) / max(tr.speed, 0.1)
    }

    // MARK: jitter

    func setJitter(_ on: Bool) {
        settings.jitter = on
        if on, isActive { armJitter() } else { jitterTimer?.invalidate(); jitterTimer = nil }
    }

    private func armJitter() {
        jitterTimer?.invalidate()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive, self.travel == nil else { return }
                let m = Double.random(in: 0...self.settings.jitterMeters), b = Double.random(in: 0...(2 * .pi))
                self.send(Geo.destination(self.position, bearing: b, meters: m))
            }
        }
        RunLoop.main.add(t, forMode: .common)
        jitterTimer = t
    }
}

/// Run a throwing closure on the FFI queue and await its result.
func ffi<T>(_ body: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { cont in
        ffiQueue.async {
            do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) }
        }
    }
}

func ffi(_ body: @escaping () -> Void) async {
    await withCheckedContinuation { cont in
        ffiQueue.async { body(); cont.resume() }
    }
}
