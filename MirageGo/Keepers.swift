import AVFoundation
import CoreLocation
import UserNotifications

/// Keeps the process alive in the background by playing silence (audio background mode). The location channel
/// is a live socket; if iOS suspends the app the spoof ends.
final class SilentAudioKeeper {
    static let shared = SilentAudioKeeper()
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var running = false
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
        player.stop(); engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startEngine() {
        do {
            engine.stop(); player.stop()
            engine = AVAudioEngine(); player = AVAudioPlayerNode()
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)
            engine.attach(player)
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            let frames = AVAudioFrameCount(format.sampleRate)
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
                buffer.frameLength = frames
                player.scheduleBuffer(buffer, at: nil, options: .loops)
            }
            try engine.start()
            player.play()
        } catch {
            AppLog.shared.add("audio keeper: \(error.localizedDescription)")
        }
    }

    private func recover() {
        guard running, !engine.isRunning || !player.isPlaying else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try? engine.start() }
        player.play()
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

    func start() {
        running = true
        switch manager.authorizationStatus {
        case .authorizedAlways: manager.startUpdatingLocation()
        case .authorizedWhenInUse, .notDetermined: manager.requestAlwaysAuthorization()
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
