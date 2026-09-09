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

    func start() {
        running = true
        switch manager.authorizationStatus {
        case .authorizedAlways:
            manager.startUpdatingLocation()
        case .authorizedWhenInUse:
            // Start now (the "Always" upgrade prompt is shown at most once and may never change the status).
            manager.startUpdatingLocation()
            manager.requestAlwaysAuthorization()
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        default: break
        }
    }

    func stop() {
        running = false
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
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
