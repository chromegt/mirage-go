import AVFoundation
import CoreLocation
import UserNotifications

/// Keeps the process alive in the background by playing silence (audio background mode). The location channel
/// is a live socket; if iOS suspends the app the spoof ends.
///
/// Must be started while the app is in the foreground: iOS refuses to activate an audio session from the
/// background unless the app is already playing.
final class SilentAudioKeeper {
    static let shared = SilentAudioKeeper()
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var running = false
    /// True only once the player is attached and connected to the current engine; play()/start() on an
    /// unconfigured graph raise ObjC exceptions ("player started when in a disconnected state").
    private var configured = false
    private var healthTimer: Timer?

    private init() {
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(servicesReset), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    func start() {
        guard !running else { return }
        running = true
        startEngine()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.recover() }
        RunLoop.main.add(t, forMode: .common)
        healthTimer = t
    }

    func stop() {
        running = false
        healthTimer?.invalidate(); healthTimer = nil
        if configured { player.stop() }
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startEngine() {
        configured = false
        if engine.isRunning { engine.stop() }
        engine = AVAudioEngine(); player = AVAudioPlayerNode()
        let session = AVAudioSession.sharedInstance()
        do {
            // Build the graph first so it is always valid, whatever the session does.
            try session.setCategory(.playback, options: .mixWithOthers)
            engine.attach(player)
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            let frames = AVAudioFrameCount(max(format.sampleRate, 8000))
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
                buffer.frameLength = frames
                player.scheduleBuffer(buffer, at: nil, options: .loops)
            }
            configured = true
            try session.setActive(true)
            try engine.start()
            if engine.isRunning { player.play() }
        } catch {
            AppLog.shared.add("audio keeper: \(error.localizedDescription)")
        }
    }

    private func recover() {
        guard running else { return }
        guard configured else { startEngine(); return }
        guard !engine.isRunning || !player.isPlaying else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning { try engine.start() }
            if engine.isRunning, !player.isPlaying { player.play() }
        } catch {
            // Session still held by another app (or we are backgrounded); the next tick retries.
        }
    }

    @objc private func interrupted(_ n: Notification) {
        guard running, let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
        recover()
    }

    @objc private func servicesReset() {
        guard running else { return }
        startEngine()
    }
}

/// Background location updates are the second thing that keeps a backgrounded app running.
/// Start it in the foreground: When-In-Use permission is enough for background updates as long as
/// startUpdatingLocation() was called while the app was active.
final class LocationKeeper: NSObject, CLLocationManagerDelegate {
    static let shared = LocationKeeper()
    private let manager = CLLocationManager()
    private var running = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
    }

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    /// Continuations parked by `requestAndWait()`; resumed from the delegate or by the timeout, whichever is first.
    private var authWaiters: [CheckedContinuation<Void, Never>] = []

    /// Starts updates when permission is already decided. It no longer asks for permission itself: a permission
    /// alert is dismissed the moment the app resigns active, and Connect app-switches to LocalDev VPN right after
    /// this runs. `requestAndWait()` handles the first-run prompt before that switch; the When-In-Use -> Always
    /// upgrade is offered from Settings (foreground, nothing pending).
    func start() {
        running = true
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .notDetermined:
            // Fallback only (Connect normally awaited requestAndWait() already); a second request is a no-op.
            manager.requestAlwaysAuthorization()
        default: break
        }
    }

    /// First run: shows the location prompt and suspends until the user answers (or `timeout` passes, e.g. when the
    /// alert was dismissed by an app switch). Returns immediately when the status is already determined.
    /// Call from the main actor while the app is in the foreground.
    @MainActor
    func requestAndWait(timeout: TimeInterval = 30) async {
        guard manager.authorizationStatus == .notDetermined else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            authWaiters.append(cont)
            manager.requestAlwaysAuthorization()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.resumeAuthWaiters() }
        }
    }

    /// The one-shot "Always" upgrade prompt (only shown by iOS once per install). Meant for the Settings row, in the
    /// foreground, so no app switch can dismiss it.
    func requestAlwaysUpgrade() {
        guard manager.authorizationStatus == .authorizedWhenInUse else { return }
        manager.requestAlwaysAuthorization()
    }

    private func resumeAuthWaiters() {
        let waiters = authWaiters
        authWaiters = []
        for w in waiters { w.resume() }
    }

    func stop() {
        running = false
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus != .notDetermined { resumeAuthWaiters() }
        guard running else { return }
        if m.authorizationStatus == .authorizedAlways || m.authorizationStatus == .authorizedWhenInUse { m.startUpdatingLocation() }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

enum Notify {
    static func request() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    static func post(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
