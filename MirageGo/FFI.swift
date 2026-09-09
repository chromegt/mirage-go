import Foundation
import idevice

// Thin Swift layer over the idevice C FFI (MIT, jkcoxson/idevice). Every handle is an opaque pointer and NOT
// thread safe, so all calls go through `ffiQueue`.

let ffiQueue = DispatchQueue(label: "net.summitclient.mirage-go.ffi", qos: .userInitiated)

enum FFIError: LocalizedError {
    case call(code: Int32, sub: Int32, message: String)
    case badAddress
    case noHandle(String)
    /// pair-verify failed and idevice fell back to pair-setup (PIN "000000"): the phone no longer accepts this file.
    case pairingRejected(String)

    var errorDescription: String? {
        switch self {
        case .call(let code, let sub, let message): return "\(message) (code \(code)/\(sub))"
        case .badAddress: return "Bad device address"
        case .noHandle(let what): return "\(what) was not created"
        case .pairingRejected(let message): return "The phone rejected the pairing file (pair-setup was attempted): \(message)"
        }
    }
    var code: Int32 {
        if case .call(let c, _, _) = self { return c }
        return 0
    }
    var isPairingRejected: Bool {
        if case .pairingRejected = self { return true }
        return false
    }
}

/// Diagnostics for the RPPairing PIN fallback. idevice only asks for a PIN when pair-verify rejected the file
/// (RESEARCH.md 3.2 #8), so "the callback fired" == "the pairing file is stale". The FFI copies the returned
/// string (CStr::from_ptr(...).to_string()) and never frees it, so one static buffer is enough.
enum PairingDiag {
    static var pinRequested = false
    static let pin: UnsafeMutablePointer<CChar> = strdup("000000")!
    static let pinCallback: @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? = { _ in
        PairingDiag.pinRequested = true
        AppLog.shared.add("pair-verify failed; the phone asked for a pairing PIN (pairing file is stale)")
        return UnsafePointer(PairingDiag.pin)
    }
}

@discardableResult
func ffiCheck(_ err: UnsafeMutablePointer<IdeviceFfiError>?) throws -> Bool {
    guard let err else { return true }
    let message = err.pointee.message.map { String(cString: $0) } ?? "unknown error"
    let code = err.pointee.code
    let sub = err.pointee.sub_code
    idevice_error_free(err)
    throw FFIError.call(code: code, sub: sub, message: message)
}

enum FFILogging {
    static func start() {
        let path = AppPaths.documents.appendingPathComponent("idevice.log").path
        // idevice_init_logger takes a mutable char*; strdup gives us one it may keep.
        let cpath = strdup(path)
        _ = idevice_init_logger(Disabled, Info, cpath)
    }
}

/// The RemotePairing tunnel to the phone itself through the loopback VPN: adapter + RSD handshake.
final class DeviceTunnel {
    private(set) var pairing: OpaquePointer?
    private(set) var adapter: OpaquePointer?
    private(set) var handshake: OpaquePointer?

    static func open(pairingPath: String, ip: String, port: UInt16, hostname: String = "MirageGo") throws -> DeviceTunnel {
        let t = DeviceTunnel()
        var pairing: OpaquePointer?
        try ffiCheck(rp_pairing_file_read(pairingPath, &pairing))
        guard let pairing else { throw FFIError.noHandle("pairing file") }
        t.pairing = pairing

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        guard ip.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            t.close()
            throw FFIError.badAddress
        }
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        PairingDiag.pinRequested = false
        let err = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                tunnel_create_rppairing(sa, socklen_t(MemoryLayout<sockaddr_in>.stride), hostname, pairing, PairingDiag.pinCallback, nil, &adapter, &handshake)
            }
        }
        do { try ffiCheck(err) } catch {
            t.close()
            if PairingDiag.pinRequested { throw FFIError.pairingRejected(error.localizedDescription) }
            throw error
        }
        guard let adapter, let handshake else { t.close(); throw FFIError.noHandle("tunnel") }
        t.adapter = adapter
        t.handshake = handshake
        return t
    }

    func serviceAvailable(_ name: String) -> Bool {
        guard let handshake else { return false }
        var available = false
        if let err = rsd_service_available(handshake, name, &available) { idevice_error_free(err); return false }
        return available
    }

    func close() {
        if let handshake { rsd_handshake_free(handshake) }
        if let adapter { adapter_free(adapter) }
        if let pairing { rp_pairing_file_free(pairing) }
        handshake = nil; adapter = nil; pairing = nil
    }

    deinit { close() }
}

/// The DVT LocationSimulation channel. The simulated location lives only while this stays open.
final class LocationChannel {
    private var server: OpaquePointer?
    private var sim: OpaquePointer?

    init(tunnel: DeviceTunnel) throws {
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else { throw FFIError.noHandle("tunnel") }
        var server: OpaquePointer?
        try ffiCheck(remote_server_connect_rsd(adapter, handshake, &server))
        guard let server else { throw FFIError.noHandle("remote server") }
        self.server = server
        var sim: OpaquePointer?
        do { try ffiCheck(location_simulation_new(server, &sim)) } catch { remote_server_free(server); self.server = nil; throw error }
        guard let sim else { remote_server_free(server); self.server = nil; throw FFIError.noHandle("location simulation") }
        self.sim = sim
    }

    func set(lat: Double, lon: Double) throws {
        guard let sim else { throw FFIError.noHandle("location simulation") }
        try ffiCheck(location_simulation_set(sim, lat, lon))
    }

    func clear() {
        guard let sim else { return }
        if let err = location_simulation_clear(sim) { idevice_error_free(err) }
    }

    func close() {
        if let sim { location_simulation_free(sim) }
        if let server { remote_server_free(server) }
        sim = nil; server = nil
    }

    deinit { close() }
}

/// Developer disk image checks and personalized mounting through the tunnel.
enum DDIMounter {
    static let dtService = "com.apple.instruments.dtservicehub"

    static func isMounted(_ tunnel: DeviceTunnel) throws -> Bool {
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else { throw FFIError.noHandle("tunnel") }
        var client: OpaquePointer?
        try ffiCheck(image_mounter_connect_rsd(adapter, handshake, &client))
        guard let client else { throw FFIError.noHandle("image mounter") }
        defer { image_mounter_free(client) }
        var devices: UnsafeMutablePointer<plist_t?>?
        var count = 0
        try ffiCheck(image_mounter_copy_devices(client, &devices, &count))
        if let devices {
            for i in 0..<count { plist_free(devices[i]) }
            idevice_data_free(UnsafeMutableRawPointer(devices).assumingMemoryBound(to: UInt8.self), UInt(count * MemoryLayout<plist_t?>.stride))
        }
        return count > 0
    }

    static var progress: (Double) -> Void = { _ in }

    static func mount(_ tunnel: DeviceTunnel, image: URL, trustCache: URL, manifest: URL) throws {
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else { throw FFIError.noHandle("tunnel") }
        let imageData = try Data(contentsOf: image, options: .mappedIfSafe)
        let tcData = try Data(contentsOf: trustCache)
        let bmData = try Data(contentsOf: manifest)

        // Scoped so the lockdown stream is freed (also on a throw) before the mount starts.
        let ecid: UInt64 = try {
            var lockdown: OpaquePointer?
            try ffiCheck(lockdownd_connect_rsd(adapter, handshake, &lockdown))
            guard let lockdown else { throw FFIError.noHandle("lockdownd") }
            defer { lockdownd_client_free(lockdown) }
            var node: plist_t?
            try ffiCheck(lockdownd_get_value(lockdown, "UniqueChipID", nil, &node))
            var value: UInt64 = 0
            if let node {
                plist_get_uint_val(node, &value)
                plist_free(node)
            }
            return value
        }()
        guard ecid != 0 else { throw FFIError.noHandle("UniqueChipID") }

        var client: OpaquePointer?
        try ffiCheck(image_mounter_connect_rsd(adapter, handshake, &client))
        guard let client else { throw FFIError.noHandle("image mounter") }
        defer { image_mounter_free(client) }

        let err: UnsafeMutablePointer<IdeviceFfiError>? = imageData.withUnsafeBytes { ib in
            tcData.withUnsafeBytes { tb in
                bmData.withUnsafeBytes { mb in
                    image_mounter_mount_personalized_with_callback_rsd(
                        client, adapter, handshake,
                        ib.bindMemory(to: UInt8.self).baseAddress, imageData.count,
                        tb.bindMemory(to: UInt8.self).baseAddress, tcData.count,
                        mb.bindMemory(to: UInt8.self).baseAddress, bmData.count,
                        nil, ecid,
                        { done, total, _ in
                            let frac = total > 0 ? Double(done) / Double(total) : 0
                            DispatchQueue.main.async { DDIMounter.progress(frac) }
                        },
                        nil)
                }
            }
        }
        try ffiCheck(err)
    }
}
