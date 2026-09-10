import Foundation
import Combine
import UIKit

// MARK: - Fleet check-in + admin API

/// Talks to the fleet server: every phone checks in once a minute (and on foreground / phase changes) so the admin
/// list shows who is spoofing where, and the reply says whether this copy is still switched on.
///
/// Fail-open by design: a phone that cannot reach the server keeps whatever `enabled` value it last heard (default
/// on), so an offline phone still works. Only an explicit `enabled:false` from the server switches a copy off. The
/// last verdict is persisted, so a copy that was switched off stays off across a relaunch even with no signal.
@MainActor
final class Fleet: ObservableObject {
    static let shared = Fleet()
    static let base = URL(string: "https://mirage-admin-production.up.railway.app")!
    static let offMessage = "This copy of Mirage Go was switched off by the admin."
    static let offHint = "Ask the admin to switch it back on."

    @Published private(set) var enabled = true
    @Published private(set) var message = ""
    @Published private(set) var lastCheckIn: Date?
    @Published private(set) var reachable = true

    /// Stable per-install id (uppercase UUID), created once.
    let deviceID: String

    private weak var engine: SpoofEngine?
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private var started = false
    private var inFlight = false
    /// A check-in asked for while one is in flight runs right after it instead of being dropped.
    private var pending = false
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 8
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private init() {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "fleetID"), !id.isEmpty {
            deviceID = id
        } else {
            let id = UUID().uuidString.uppercased()
            d.set(id, forKey: "fleetID")
            deviceID = id
        }
        // Last server verdict, so fail-open only applies to a copy that was last known to be on.
        enabled = d.object(forKey: "fleetEnabled") as? Bool ?? true
        message = d.string(forKey: "fleetMessage") ?? ""
    }

    // MARK: lifecycle

    /// Called once from the root view: immediate check-in, a 60 s repeat, and one (debounced) per engine phase change.
    func start(engine: SpoofEngine) {
        self.engine = engine
        guard !started else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkIn() }
        }
        engine.$phase
            .removeDuplicates()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.checkIn() }
            }
            .store(in: &bag)
        Task { await checkIn() }
    }

    /// Foreground hook (scenePhase .active).
    func onForeground() {
        Task { await checkIn() }
    }

    // MARK: check-in

    private struct HelloReply: Decodable {
        let ok: Bool?
        let enabled: Bool?
        let message: String?
    }

    func checkIn() async {
        if inFlight { pending = true; return }
        inFlight = true

        let state: String
        switch engine?.phase {
        case .some(.active): state = "spoofing"
        case .some(.connecting): state = "connecting"
        default: state = "idle"
        }
        // `name` is empty until the user picks a nickname; the server keeps its own (admin-set) name for an empty one.
        let body: [String: Any] = [
            "id": deviceID,
            "name": AppSettings.shared.nickname,
            "kind": "phone",
            "model": Self.modelString,
            "os": "iOS " + UIDevice.current.systemVersion,
            "build": Self.buildString,
            "state": state,
            "place": engine?.positionName ?? "",
            "lat": engine?.position.latitude ?? 0,
            "lon": engine?.position.longitude ?? 0,
        ]
        do {
            var req = URLRequest(url: Self.base.appendingPathComponent("api/hello"))
            req.httpMethod = "POST"
            req.timeoutInterval = 8
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw FleetError.server((resp as? HTTPURLResponse)?.statusCode ?? 0)
            }
            let r = try JSONDecoder().decode(HelloReply.self, from: data)
            reachable = true
            lastCheckIn = Date()
            message = r.message ?? ""
            let was = enabled
            enabled = r.enabled ?? true
            UserDefaults.standard.set(enabled, forKey: "fleetEnabled")
            UserDefaults.standard.set(message, forKey: "fleetMessage")
            if was != enabled { AppLog.shared.add(enabled ? "admin switched this copy on" : "admin switched this copy off") }
            if !enabled { enforceOff() }
            // Switched back on: clear the "ask the admin" card we put up (only ours, keyed on the hint text).
            if !was && enabled, let e = engine, e.hint == Self.offHint { e.error = nil; e.hint = nil }
        } catch {
            // Offline / server down: keep the previous `enabled` (fail-open), only mark unreachable.
            if reachable { AppLog.shared.add("fleet check-in failed: \(error.localizedDescription)") }
            reachable = false
        }
        inFlight = false
        if pending { pending = false; await checkIn() }
    }

    /// A live session must stop the moment the admin switches this copy off.
    private func enforceOff() {
        guard let engine, engine.phase != .idle else { return }
        engine.kill()
        engine.error = message.isEmpty ? Self.offMessage : message
        engine.hint = Self.offHint
        AppLog.shared.add("session stopped: switched off by the admin")
    }

    /// Message to show when a Connect is refused (server text, or the fallback).
    var offText: String { message.isEmpty ? Self.offMessage : message }

    // MARK: device facts

    /// "iPhone iPhone17,1": the marketing class plus the machine identifier from utsname.
    static var modelString: String {
        var s = utsname()
        uname(&s)
        let machine = Mirror(reflecting: s.machine).children.reduce(into: "") { acc, e in
            if let v = e.value as? Int8, v != 0 { acc.append(Character(UnicodeScalar(UInt8(bitPattern: v)))) }
        }
        return UIDevice.current.model + " " + machine
    }

    static var buildString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return short + "(" + build + ")"
    }

    // MARK: admin API

    func devices(pw: String) async throws -> [FleetDevice] {
        struct Reply: Decodable { let ok: Bool?; let devices: [FleetDevice]? }
        let data = try await adminRequest("api/admin/devices", method: "GET", body: nil, pw: pw)
        return try JSONDecoder().decode(Reply.self, from: data).devices ?? []
    }

    func toggle(id: String, enabled: Bool, pw: String) async throws {
        _ = try await adminRequest("api/admin/toggle", method: "POST", body: ["id": id, "enabled": enabled], pw: pw)
    }

    func rename(id: String, name: String, pw: String) async throws {
        _ = try await adminRequest("api/admin/rename", method: "POST", body: ["id": id, "name": name], pw: pw)
    }

    func forget(id: String, pw: String) async throws {
        _ = try await adminRequest("api/admin/forget", method: "POST", body: ["id": id], pw: pw)
    }

    private func adminRequest(_ path: String, method: String, body: [String: Any]?, pw: String) async throws -> Data {
        var req = URLRequest(url: Self.base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 8
        req.setValue(pw, forHTTPHeaderField: "X-Admin")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw FleetError.wrongPassword }
        guard (200..<300).contains(code) else { throw FleetError.server(code) }
        return data
    }
}

enum FleetError: LocalizedError {
    case wrongPassword
    case server(Int)
    var errorDescription: String? {
        switch self {
        case .wrongPassword: return "Wrong password"
        case .server(let c): return c == 0 ? "No reply from the server" : "Server error \(c)"
        }
    }
}

/// One row of the admin list. Everything but `id` is optional so an older/newer server record never fails to decode.
struct FleetDevice: Identifiable, Decodable {
    let id: String
    var name: String?
    var kind: String?
    var model: String?
    var os: String?
    var build: String?
    var state: String?
    var place: String?
    var lat: Double?
    var lon: Double?
    /// Milliseconds since 1970.
    var lastSeen: Double?
    var firstSeen: Double?
    var online: Bool?
    var enabled: Bool?
    var note: String?

    var isOnline: Bool { online ?? false }
    var isEnabled: Bool { enabled ?? true }
    var displayName: String { let n = name ?? ""; return n.isEmpty ? "Unnamed" : n }
    var isPhone: Bool { (kind ?? "phone") != "desktop" }
}
