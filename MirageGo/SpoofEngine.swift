import Foundation
import Combine
import CoreLocation
import UIKit

/// The spoof session: opens the loopback tunnel, mounts the developer image when needed, holds the location
/// channel open, re-sends the position every few seconds, and runs realistic travel + jitter.
///
/// Threading rules: every FFI handle call goes through `ffiQueue` (see FFI.swift); handles are closed explicitly on
/// that queue, never by deinit; the channel is always released before the tunnel it borrows.
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
    private var resendTicks = 0
    private var travelTimer: Timer?
    private var jitterTimer: Timer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var stopping = false
    private var connectTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var rebuilding = false
    private let settings = AppSettings.shared

    // send() coalescing: at most one location_simulation_set is ever queued on ffiQueue.
    private var sendInFlight = false
    private var pendingSend: CLLocationCoordinate2D?
    private var sendGen = 0

    init() {
        position = CLLocationCoordinate2D(latitude: AppSettings.shared.lastLat, longitude: AppSettings.shared.lastLon)
        positionName = AppSettings.shared.lastName
        NetworkMonitor.shared.onChange = { [weak self] in
            // Wi-Fi <-> cellular switches can stall the loopback; a push doubles as the health check.
            Task { @MainActor in self?.send() }
        }
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
        resetSendState()
        phase = .connecting
        steps = [Step(id: "vpn", label: "LocalDev VPN", status: "todo"), Step(id: "pair", label: "Pairing file", status: "todo"),
                 Step(id: "tunnel", label: "Tunnel to the phone", status: "todo"), Step(id: "ddi", label: "Developer image", status: "todo"),
                 Step(id: "channel", label: "Location channel", status: "todo")]
        // Keep-alive starts here, in the foreground: the VPN step app-switches away and the audio session cannot be
        // activated from the background, and background location needs startUpdatingLocation() while active.
        beginKeepAlive()
        let target = position
        connectTask = Task { await self.runConnect(target) }
    }

    /// Stops an in-progress Connect (VPN wait, download, mount, ...) and returns to idle.
    func cancelConnect() {
        guard phase == .connecting else { return }
        stopping = true
        connectTask?.cancel(); connectTask = nil
        teardownHandles()
        phase = .idle
        steps = []
        AppLog.shared.add("connect cancelled")
    }

    private func step(_ id: String, _ status: String, _ detail: String = "") {
        if let i = steps.firstIndex(where: { $0.id == id }) { steps[i].status = status; steps[i].detail = detail }
    }

    private func fail(_ message: String, hint: String?) {
        AppLog.shared.add("connect failed: \(message)")
        for i in steps.indices where steps[i].status == "busy" { steps[i].status = "fail" }
        error = message; self.hint = hint
        phase = .idle
        connectTask = nil
        teardownHandles()
    }

    /// True once disconnect()/kill()/cancelConnect() ran while an async step was awaiting.
    private var aborted: Bool { Task.isCancelled || stopping }

    private func runConnect(_ target: CLLocationCoordinate2D) async {
        // 1. VPN
        step("vpn", "busy")
        if !VPNHelper.tunnelUp {
            if VPNHelper.installed {
                VPNHelper.open()
                for _ in 0..<12 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if aborted { return }
                    if VPNHelper.tunnelUp { break }
                }
            }
            guard VPNHelper.tunnelUp else {
                fail("LocalDev VPN is not connected.", hint: VPNHelper.installed ? "Open LocalDev VPN and tap Connect, then come back." : "Install LocalDev VPN from the App Store first.")
                return
            }
        }
        step("vpn", "done")

        // 2. pairing file (only a Remote pairing file works on this path)
        step("pair", "busy")
        let kind = PairingStore.kind
        guard kind == PairingStore.remoteKind else {
            if kind == "none" {
                fail("No pairing file yet.", hint: "Import the pairing file made on the PC (Settings → Pairing file).")
            } else {
                fail("The pairing file is a \(kind) record.", hint: "This is a USB (lockdown) record. In idevice_pair choose Remote pairing, Save to file, and import that one.")
            }
            return
        }
        step("pair", "done", kind)

        // 3. tunnel
        step("tunnel", "busy")
        let ip = settings.deviceIP, port = UInt16(clamping: settings.devicePort), path = PairingStore.url.path
        let firstTunnel: DeviceTunnel
        do {
            firstTunnel = try await ffi { try DeviceTunnel.open(pairingPath: path, ip: ip, port: port) }
        } catch {
            if aborted { return }
            fail("Tunnel failed: \(error.localizedDescription)", hint: tunnelHint(for: error))
            return
        }
        if aborted { await ffiRun { firstTunnel.close() }; return }
        step("tunnel", "done", "\(ip):\(port)")
        AppLog.shared.add("tunnel up via \(ip):\(port)")

        // 4. developer image
        step("ddi", "busy")
        var t = firstTunnel
        let hasService = await ffiRun { firstTunnel.serviceAvailable(DDIMounter.dtService) }
        if aborted { await ffiRun { firstTunnel.close() }; return }
        if !hasService {
            var mounted = false
            do { mounted = try await ffi { try DDIMounter.isMounted(firstTunnel) } } catch { AppLog.shared.add("mounted check: \(error.localizedDescription)") }
            if aborted { await ffiRun { firstTunnel.close() }; return }
            if !mounted {
                if !DDIStore.present {
                    step("ddi", "busy", "downloading")
                    do { try await DDIStore.download { [weak self] s in self?.step("ddi", "busy", s) } }
                    catch {
                        if aborted { await ffiRun { firstTunnel.close() }; return }
                        fail("Could not download the developer image: \(error.localizedDescription)", hint: "Connect to Wi-Fi with internet and try again.")
                        await ffiRun { firstTunnel.close() }; return
                    }
                    if aborted { await ffiRun { firstTunnel.close() }; return }
                }
                step("ddi", "busy", "mounting (needs internet)")
                DDIMounter.progress = { [weak self] f in self?.step("ddi", "busy", "mounting \(Int(f * 100))%") }
                do {
                    try await ffi { try DDIMounter.mount(firstTunnel, image: DDIStore.image, trustCache: DDIStore.trustCache, manifest: DDIStore.manifest) }
                    AppLog.shared.add("developer image mounted")
                } catch {
                    if aborted { await ffiRun { firstTunnel.close() }; return }
                    fail("Developer image could not be mounted: \(error.localizedDescription)", hint: "Check Developer Mode is on (Settings → Privacy & Security). The phone needs internet for this step (Apple signs the image). Or plug the phone into the PC once; Mirage mounts it there.")
                    await ffiRun { firstTunnel.close() }; return
                }
                if aborted { await ffiRun { firstTunnel.close() }; return }
            }
            // The RSD service list is captured at handshake time: reopen the tunnel so dtservicehub shows up.
            // remoted can take a moment to republish the service, so retry the reopen a few times.
            await ffiRun { firstTunnel.close() }
            var reopened: DeviceTunnel?
            var lastError = "unknown"
            for attempt in 1...3 {
                do {
                    let nt = try await ffi { try DeviceTunnel.open(pairingPath: path, ip: ip, port: port) }
                    if aborted { await ffiRun { nt.close() }; return }
                    let ok = await ffiRun { nt.serviceAvailable(DDIMounter.dtService) }
                    if aborted { await ffiRun { nt.close() }; return }
                    if ok { reopened = nt; break }
                    lastError = "service not published yet"
                    await ffiRun { nt.close() }
                } catch {
                    if aborted { return }
                    lastError = error.localizedDescription
                }
                step("ddi", "busy", "waiting for the service (\(attempt)/3)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if aborted { return }
            }
            guard let nt = reopened else {
                fail("The developer image is still not available (\(lastError)).", hint: "Reboot the phone, open LocalDev VPN, and try again on Wi-Fi with internet.")
                return
            }
            t = nt
        }
        ddiStatus = "mounted"
        step("ddi", "done")

        // 5. channel
        step("channel", "busy")
        let tunnelForChannel = t
        let ch: LocationChannel
        do {
            ch = try await ffi { let c = try LocationChannel(tunnel: tunnelForChannel); try c.set(lat: target.latitude, lon: target.longitude); return c }
        } catch {
            if aborted { await ffiRun { tunnelForChannel.close() }; return }
            fail("Location service failed: \(error.localizedDescription)", hint: "Try Connect again. If it keeps failing, reboot the phone.")
            await ffiRun { tunnelForChannel.close() }; return
        }
        if aborted { await ffiRun { ch.close(); tunnelForChannel.close() }; return }
        step("channel", "done")
        // Any leftover handles (there should be none) are closed on ffiQueue before the new ones are stored.
        closeHandles(channel, tunnel)
        channel = ch
        tunnel = tunnelForChannel
        connectTask = nil
        phase = .active
        lastSetAt = Date()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AppLog.shared.add("spoofing \(Geo.fmt(target))")
        armResend()
        if settings.jitter { armJitter() }
    }

    private func tunnelHint(for error: Error) -> String {
        let e = error as? FFIError
        if e?.code == -9 { return "The pairing file could not be read. Re-make it on the PC (idevice_pair → Remote pairing → Save to file) and import it again." }
        if e?.isPairingRejected == true { return "The phone no longer accepts this pairing file. Plug the phone into the PC once, make a new Remote pairing file, and import it." }
        if !VPNHelper.tunnelUp { return "LocalDev VPN dropped. Open it, tap Connect, then try again." }
        return "Check Developer Mode is on (Settings → Privacy & Security). If iOS asked to allow local network access, tap Allow and press Connect again. Otherwise re-make the pairing file on the PC (plug in once) and import it again; make sure Wi-Fi is on, or Airplane Mode is on when you are on cellular."
    }

    func disconnect() {
        stopping = true
        connectTask?.cancel(); connectTask = nil
        rebuildTask?.cancel(); rebuildTask = nil
        rebuilding = false
        stopTravel()
        stopTimers()
        resetSendState()
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

    /// Emergency stop: also clears any error. Does nothing when there is nothing to stop.
    func kill() {
        switch phase {
        case .connecting: cancelConnect()
        case .active: disconnect()
        case .idle: break
        }
        error = nil; hint = nil
    }

    private func teardownHandles() {
        rebuildTask?.cancel(); rebuildTask = nil
        rebuilding = false
        resetSendState()
        let ch = channel, t = tunnel
        channel = nil; tunnel = nil
        closeHandles(ch, t)
        endKeepAlive()
    }

    /// Frees handles on ffiQueue, channel first (its stream borrows the tunnel's adapter).
    private func closeHandles(_ ch: LocationChannel?, _ t: DeviceTunnel?) {
        guard ch != nil || t != nil else { return }
        ffiQueue.async { ch?.close(); t?.close() }
    }

    private func stopTimers() {
        resendTimer?.invalidate(); resendTimer = nil
        jitterTimer?.invalidate(); jitterTimer = nil
    }

    // MARK: keep-alive + resend

    private func beginKeepAlive() {
        SilentAudioKeeper.shared.start()
        LocationKeeper.shared.start()
        if bgTask == .invalid {
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "MirageGoSpoof") { [weak self] in
                guard let self, self.bgTask != .invalid else { return }
                UIApplication.shared.endBackgroundTask(self.bgTask); self.bgTask = .invalid
            }
        }
    }

    private func endKeepAlive() {
        SilentAudioKeeper.shared.stop()
        LocationKeeper.shared.stop()
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
    }

    /// One 1 s timer: pushes every tick while travelling, every 4 s otherwise, and watches the VPN interface.
    private func armResend() {
        resendTimer?.invalidate()
        resendTicks = 0
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.resendTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        resendTimer = t
    }

    private func resendTick() {
        guard isActive else { return }
        resendTicks += 1
        if !VPNHelper.tunnelUp {
            // Do not wait for the blocked set() to time out: the interface is gone, rebuild right away.
            linkLost("LocalDev VPN interface is gone")
            return
        }
        if travel != nil || resendTicks % 4 == 0 { send() }
    }

    private func resetSendState() {
        sendGen += 1
        sendInFlight = false
        pendingSend = nil
    }

    /// Push the current position to the phone (also the health check: an error here means the link died).
    /// Coalesced: while one set() is on ffiQueue, later calls only remember the newest coordinate.
    func send(_ override: CLLocationCoordinate2D? = nil) {
        guard isActive, let ch = channel else { return }
        let p = override ?? position
        if sendInFlight { pendingSend = p; return }
        sendInFlight = true
        let gen = sendGen
        ffiQueue.async { [weak self] in
            var failure: String?
            do { try ch.set(lat: p.latitude, lon: p.longitude) } catch { failure = error.localizedDescription }
            Task { @MainActor in self?.sendFinished(gen: gen, sent: p, failure: failure) }
        }
    }

    private func sendFinished(gen: Int, sent: CLLocationCoordinate2D, failure: String?) {
        guard gen == sendGen else { return }
        sendInFlight = false
        if let failure { pendingSend = nil; linkLost(failure); return }
        lastSetAt = Date()
        if let next = pendingSend {
            pendingSend = nil
            if next.latitude != sent.latitude || next.longitude != sent.longitude { send(next) }
        }
    }

    private func linkLost(_ why: String) {
        guard isActive, !rebuilding, !stopping else { return }
        rebuilding = true
        AppLog.shared.add("link lost (\(why)); rebuilding")
        let target = position
        resendTimer?.invalidate(); resendTimer = nil
        resetSendState()
        let ch = channel, t = tunnel
        channel = nil; tunnel = nil
        rebuildTask = Task {
            await ffiRun { ch?.close(); t?.close() }
            var ok = false
            for attempt in 1...3 {
                if self.aborted { self.rebuilding = false; return }
                if VPNHelper.tunnelUp, PairingStore.present {
                    var nt: DeviceTunnel?
                    do {
                        let opened = try await ffi { try DeviceTunnel.open(pairingPath: PairingStore.url.path, ip: self.settings.deviceIP, port: UInt16(clamping: self.settings.devicePort)) }
                        nt = opened
                        if self.aborted { await ffiRun { opened.close() }; self.rebuilding = false; return }
                        let nc = try await ffi { let c = try LocationChannel(tunnel: opened); try c.set(lat: target.latitude, lon: target.longitude); return c }
                        if self.aborted { await ffiRun { nc.close(); opened.close() }; self.rebuilding = false; return }
                        self.closeHandles(self.channel, self.tunnel)
                        self.channel = nc
                        self.tunnel = opened
                        ok = true
                        AppLog.shared.add("rebuilt on attempt \(attempt)")
                        break
                    } catch {
                        AppLog.shared.add("rebuild \(attempt): \(error.localizedDescription)")
                        if let nt { await ffiRun { nt.close() } }
                        if self.aborted { self.rebuilding = false; return }
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            self.rebuilding = false
            self.rebuildTask = nil
            if self.aborted { return }
            if ok {
                self.armResend()
            } else {
                self.stopTimers(); self.stopTravel(); self.endKeepAlive()
                self.phase = .idle
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

    /// Only moves the marker; the 1 s resend tick pushes it to the phone.
    private func tickTravel() {
        guard let tr = travel else { return }
        let elapsed = Date().timeIntervalSince(tr.start)
        let frac = min(1, (elapsed * tr.speed) / max(tr.dist, 0.001))
        let p = frac >= 1 ? tr.to : Geo.destination(tr.from, bearing: Geo.bearing(tr.from, tr.to), meters: tr.dist * frac)
        position = p
        travelProgress = frac
        if frac >= 1 {
            positionName = tr.name
            stopTravel()
            send()
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

/// Run a non-throwing closure on the FFI queue and await its result.
func ffiRun<T>(_ body: @escaping () -> T) async -> T {
    await withCheckedContinuation { cont in
        ffiQueue.async { cont.resume(returning: body()) }
    }
}
