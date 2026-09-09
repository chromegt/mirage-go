import Foundation
import Combine
import UIKit
import CoreLocation

// MARK: - Paths

enum AppPaths {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var support: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MirageGo", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

// MARK: - Log

final class AppLog: ObservableObject {
    static let shared = AppLog()
    @Published private(set) var lines: [String] = []
    private let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    func add(_ s: String) {
        let line = "\(fmt.string(from: Date())) \(s)"
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > 400 { self.lines.removeFirst(self.lines.count - 400) }
        }
    }
}

// MARK: - Pairing file

enum PairingStore {
    static let fileName = "pairingFile.plist"
    static var url: URL { AppPaths.support.appendingPathComponent(fileName) }

    /// The app's Documents folder is visible in Finder/iTunes/Apple Devices file sharing and reachable over AFC,
    /// so a file dropped there is adopted automatically. A Documents copy is adopted at most once: it is skipped
    /// when it is byte-identical to the installed file, and it is renamed to `*.imported.plist` afterwards, so it
    /// can never overwrite a file the user imported later through the picker.
    ///
    /// Also called from the 1 s Readiness poll while no usable file is installed, so a file pushed while the app is
    /// in the foreground is picked up too. A candidate written in the last 2 s is skipped (an AFC upload may still
    /// be in progress); a candidate that was rejected is remembered by path + modification date so it is not
    /// re-read and re-logged every second.
    private static var rejected: Set<String> = []

    static func adoptFromDocuments() {
        let fm = FileManager.default
        let candidates = ["pairingFile.plist", "pairing.plist", "pairing_file.plist"]
            .map { AppPaths.documents.appendingPathComponent($0) }
            + ((try? fm.contentsOfDirectory(at: AppPaths.documents, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "mobiledevicepairing" || $0.pathExtension == "mobiledevicepair" }
        let installed = try? Data(contentsOf: url)
        for c in candidates where fm.fileExists(atPath: c.path) {
            let modified = (try? fm.attributesOfItem(atPath: c.path)[.modificationDate] as? Date) ?? .distantPast
            if Date().timeIntervalSince(modified) < 2 { continue }   // still being written
            let stamp = "\(c.path)@\(modified.timeIntervalSince1970)"
            if rejected.contains(stamp) { continue }
            if let installed, let candidate = try? Data(contentsOf: c), candidate == installed { continue }
            do {
                try install(from: c)
                AppLog.shared.add("Adopted pairing file from Documents/\(c.lastPathComponent)")
                let aside = c.deletingPathExtension().appendingPathExtension("imported.plist")
                try? fm.removeItem(at: aside)
                try? fm.moveItem(at: c, to: aside)
                return
            } catch {
                rejected.insert(stamp)
                AppLog.shared.add("Documents/\(c.lastPathComponent) not adopted: \(error.localizedDescription)")
            }
        }
    }

    static func install(from src: URL) throws {
        let data = try Data(contentsOf: src)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw NSError(domain: "MirageGo", code: 1, userInfo: [NSLocalizedDescriptionKey: "That file is not a pairing file."])
        }
        // Only a Remote pairing file (public_key/private_key/identifier) works over the loopback tunnel.
        guard plist["public_key"] != nil else {
            let msg = plist["HostID"] != nil
                ? "This file is the USB kind and won't work. Ask for a new Remote pairing file from the PC and import that one."
                : "That file is not a pairing file."
            throw NSError(domain: "MirageGo", code: 3, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static let remoteKind = "remote pairing"

    /// True only for a file the engine can actually use.
    static var present: Bool { kind == remoteKind }

    static var kind: String {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return "none" }
        if plist["public_key"] != nil { return remoteKind }
        if plist["HostID"] != nil { return "lockdown (not supported)" }
        return "unknown"
    }
}

// MARK: - Developer disk image files

enum DDIStore {
    static var dir: URL { AppPaths.documents.appendingPathComponent("DDI", isDirectory: true) }
    static var image: URL { dir.appendingPathComponent("Image.dmg") }
    static var trustCache: URL { dir.appendingPathComponent("Image.dmg.trustcache") }
    static var manifest: URL { dir.appendingPathComponent("BuildManifest.plist") }
    static let base = "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/"

    /// A 0-byte file (interrupted write) counts as absent so `download` fetches it again instead of mounting it.
    static var present: Bool { [image, trustCache, manifest].allSatisfy(nonEmpty) }

    private static func nonEmpty(_ u: URL) -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber else { return false }
        return size.int64Value > 0
    }

    /// Deletes the three files so `download` fetches them again.
    static func removeAll() {
        for f in [image, trustCache, manifest] { try? FileManager.default.removeItem(at: f) }
    }

    /// Main-actor so `progress` may touch SwiftUI state directly; the URLSession await still runs off-main.
    @MainActor
    static func download(progress: @escaping (String) -> Void) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, dest) in [("BuildManifest.plist", manifest), ("Image.dmg.trustcache", trustCache), ("Image.dmg", image)] {
            if nonEmpty(dest) { continue }
            progress("Downloading \(name)…")
            guard let url = URL(string: base + name) else { continue }
            let (tmp, resp) = try await URLSession.shared.download(from: url)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw NSError(domain: "MirageGo", code: 2, userInfo: [NSLocalizedDescriptionKey: "Download of \(name) failed."])
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        }
        progress("Developer image files ready")
    }
}

// MARK: - LocalDev VPN

enum VPNHelper {
    static let storeURL = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!

    static func openStore() { UIApplication.shared.open(storeURL) }

    static var installed: Bool {
        guard let u = URL(string: "localdevvpn://") else { return false }
        return UIApplication.shared.canOpenURL(u)
    }

    static func open() {
        guard let u = URL(string: "localdevvpn://enable?scheme=miragego") else { return }
        UIApplication.shared.open(u)
    }

    /// The loopback VPN gives the phone a 10.7.x.x interface while it is up.
    static var tunnelUp: Bool {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return false }
        defer { freeifaddrs(first) }
        var p = first
        while let i = p {
            if let sa = i.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var a = sockaddr_in()
                memcpy(&a, sa, MemoryLayout<sockaddr_in>.size)
                if String(cString: inet_ntoa(a.sin_addr)).hasPrefix("10.7.") { return true }
            }
            p = i.pointee.ifa_next
        }
        return false
    }
}

// MARK: - Network

import Network

/// Watches the phone's network path so the engine can re-push after Wi-Fi/cellular switches and the UI can show
/// the Airplane-Mode tip when the phone is cellular-only.
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    @Published private(set) var cellularOnly = false
    @Published private(set) var hasWifi = false
    var onChange: (() -> Void)?
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                self.hasWifi = path.usesInterfaceType(.wifi)
                self.cellularOnly = path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)
                self.onChange?()
            }
        }
        monitor.start(queue: DispatchQueue(label: "net.summitclient.mirage-go.net"))
    }
}

// MARK: - Geo maths

enum Geo {
    static let earth = 6371000.0
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = p2 - p1, dl = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earth * asin(min(1, sqrt(h)))
    }
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180, dl = (b.longitude - a.longitude) * .pi / 180
        return atan2(sin(dl) * cos(p2), cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl))
    }
    static func destination(_ a: CLLocationCoordinate2D, bearing: Double, meters: Double) -> CLLocationCoordinate2D {
        let p1 = a.latitude * .pi / 180, l1 = a.longitude * .pi / 180, d = meters / earth
        let p2 = asin(sin(p1) * cos(d) + cos(p1) * sin(d) * cos(bearing))
        var l2 = l1 + atan2(sin(bearing) * sin(d) * cos(p1), cos(d) - sin(p1) * sin(p2))
        l2 = (l2 + .pi).truncatingRemainder(dividingBy: 2 * .pi) - .pi
        return CLLocationCoordinate2D(latitude: p2 * 180 / .pi, longitude: l2 * 180 / .pi)
    }
    static func fmt(_ c: CLLocationCoordinate2D) -> String { String(format: "%.5f, %.5f", c.latitude, c.longitude) }
    /// Session clock: m:ss under an hour, h:mm:ss after.
    static func fmtClock(_ s: Double) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
    static func fmtDist(_ m: Double) -> String { m >= 1000 ? String(format: "%.2f km", m / 1000) : "\(Int(m.rounded())) m" }
    static func fmtDur(_ s: Double) -> String {
        if s >= 3600 { return "\(Int(s / 3600))h \(Int(s.truncatingRemainder(dividingBy: 3600) / 60))m" }
        if s >= 60 { return "\(Int(s / 60))m \(Int(s.truncatingRemainder(dividingBy: 60)))s" }
        return "\(Int(s.rounded()))s"
    }
}

// MARK: - Places

struct Place: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var lat: Double
    var lon: Double
    var icon: String
    var fav: Bool = false
    var custom: Bool = false
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

final class PlaceStore: ObservableObject {
    static let shared = PlaceStore()
    @Published var places: [Place] {
        didSet { save() }
    }
    static let presets: [Place] = [
        Place(id: "p-hawaii", name: "Hawaii", lat: 19.59380, lon: -155.42837, icon: "🌋"),
        Place(id: "p-carlsbad", name: "Carlsbad Village", lat: 33.1600, lon: -117.3500, icon: "🌴"),
        Place(id: "p-la", name: "Downtown Los Angeles", lat: 34.0522, lon: -118.2437, icon: "🏙️"),
        Place(id: "p-disney", name: "Disneyland", lat: 33.8121, lon: -117.9190, icon: "🎢"),
        Place(id: "p-sf", name: "Golden Gate Bridge", lat: 37.8199, lon: -122.4783, icon: "🌉"),
        Place(id: "p-nyc", name: "Times Square, NYC", lat: 40.7580, lon: -73.9855, icon: "🗽"),
        Place(id: "p-vegas", name: "Las Vegas Strip", lat: 36.1147, lon: -115.1728, icon: "🎰"),
        Place(id: "p-paris", name: "Eiffel Tower, Paris", lat: 48.8584, lon: 2.2945, icon: "🗼"),
        Place(id: "p-tokyo", name: "Shibuya, Tokyo", lat: 35.6595, lon: 139.7005, icon: "🏮"),
    ]

    private init() {
        if let data = UserDefaults.standard.data(forKey: "places"), let saved = try? JSONDecoder().decode([Place].self, from: data) {
            places = saved
        } else {
            places = Self.presets
        }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(places) { UserDefaults.standard.set(data, forKey: "places") }
    }
    func toggleFav(_ p: Place) {
        if let i = places.firstIndex(where: { $0.id == p.id }) { places[i].fav.toggle() }
    }
    func add(name: String, at c: CLLocationCoordinate2D, icon: String) {
        places.insert(Place(id: "c-\(Int(Date().timeIntervalSince1970))", name: name, lat: c.latitude, lon: c.longitude, icon: icon, fav: true, custom: true), at: 0)
    }
    func delete(_ p: Place) { places.removeAll { $0.id == p.id } }
}

// MARK: - Settings

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    @Published var travel: Bool { didSet { UserDefaults.standard.set(travel, forKey: "travel") } }
    @Published var travelSpeed: String { didSet { UserDefaults.standard.set(travelSpeed, forKey: "travelSpeed") } }
    @Published var jitter: Bool { didSet { UserDefaults.standard.set(jitter, forKey: "jitter") } }
    @Published var jitterMeters: Double { didSet { UserDefaults.standard.set(jitterMeters, forKey: "jitterMeters") } }
    @Published var deviceIP: String { didSet { UserDefaults.standard.set(deviceIP, forKey: "deviceIP") } }
    @Published var devicePort: Int { didSet { UserDefaults.standard.set(devicePort, forKey: "devicePort") } }
    @Published var lastLat: Double { didSet { UserDefaults.standard.set(lastLat, forKey: "lastLat") } }
    @Published var lastLon: Double { didSet { UserDefaults.standard.set(lastLon, forKey: "lastLon") } }
    @Published var lastName: String { didSet { UserDefaults.standard.set(lastName, forKey: "lastName") } }

    static let speeds: [(id: String, label: String, mps: Double)] = [("walk", "Walk", 1.4), ("jog", "Jog", 3.0), ("bike", "Bike", 5.5), ("drive", "Drive", 13.4)]
    var speedMps: Double { Self.speeds.first { $0.id == travelSpeed }?.mps ?? 13.4 }

    private init() {
        let d = UserDefaults.standard
        travel = d.object(forKey: "travel") as? Bool ?? true
        travelSpeed = d.string(forKey: "travelSpeed") ?? "drive"
        jitter = d.bool(forKey: "jitter")
        jitterMeters = d.object(forKey: "jitterMeters") as? Double ?? 4
        deviceIP = d.string(forKey: "deviceIP") ?? "10.7.0.1"
        devicePort = d.object(forKey: "devicePort") as? Int ?? 49152
        lastLat = d.object(forKey: "lastLat") as? Double ?? 19.59380
        lastLon = d.object(forKey: "lastLon") as? Double ?? -155.42837
        lastName = d.string(forKey: "lastName") ?? "Hawaii"
    }
}
