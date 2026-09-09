# Mirage Go: architecture and build plan

Synthesized 2026-09-09 from four research passes (idevice crate/FFI, StikDebug/Locus source, loopback-VPN helpers + Vanish, Sideloadly/free-Apple-ID limits) plus local observations on this PC. Every factual claim carries a URL; anything not confirmed by a primary source is marked **(unverified)** or **(inferred)**.

Target: iPhone 16 Pro (iPhone17,1), iOS 18.7.8 (22H352), UDID `00008140-001939063A81801C`. Developer PC: Windows 11, Python 3.14, git, Sideloadly, pymobiledevice3 11.10.3 with a working USB pairing and a personalized DDI already mountable. No Mac.

---

## 1. Feasibility verdict

**Verdict: feasible, and already proven by shipping apps. Nothing in Mirage Go requires a new technique; it is a re-implementation of StikDebug's "Location Simulator" tab (and of the MIT clone Locus) with a different UI.**

### Proven by existing code/apps

| Claim | Evidence |
|---|---|
| A sideloaded app can reach its own phone's developer daemons through a loopback packet-tunnel VPN (LocalDevVPN, formerly StosVPN) that swaps IPv4 src/dst so `10.7.0.1` resolves to the phone itself. | StosVPN `TunnelProv/PacketTunnelProvider.swift` https://raw.githubusercontent.com/SideStore/StosVPN/main/TunnelProv/PacketTunnelProvider.swift ; LocalDevVPN fork https://raw.githubusercontent.com/jkcoxson/LocalDevVPN/main/TunnelProv/PacketTunnelProvider.swift ; explanation https://lantian.pub/en/article/modify-computer/sidestore-without-stosvpn-across-lan.lantian/ |
| Over that loopback, the phone can open a CoreDevice tunnel, do the RSD handshake, connect DVT and drive `com.apple.instruments.server.services.LocationSimulation` on iOS 17.4-18.x. | StikDebug `IdeviceFFIBridge.swift` (`simulate_location`: `rp_pairing_file_read` -> `tunnel_create_rppairing(10.7.0.1:49152)` -> `remote_server_connect_rsd` -> `location_simulation_new` -> `location_simulation_set`) https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/Device/IdeviceFFIBridge.swift ; README compatibility "17.4 - 18.x Fully supported / Stable" https://raw.githubusercontent.com/StikDebug/StikDebug/main/README.md |
| The personalized DDI can be downloaded and mounted **on the phone, by the app itself** (needed before `dtservicehub` exists). | StikDebug `DeveloperDiskImageService.swift` + `image_mounter_mount_personalized_with_callback_rsd` https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/Services/DeveloperDiskImageService.swift https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/Device/IdeviceFFIBridge.swift |
| The simulated location survives backgrounding **for a while** if the app keeps its process alive (silent audio + background location modes) and re-sends the fix every few seconds. Multi-hour lock-screen survival is **(unverified)**: every shipping app documents drops (see 2.4). | StikDebug `MapSelectionView.swift` (4 s resend), `BackgroundAudioManager.swift`, `BackgroundLocationManager.swift` https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/Views/MapSelectionView.swift https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/Services/BackgroundAudioManager.swift https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/Services/BackgroundLocationManager.swift ; drop reports: Vanish v2.2.0 "Vanish tells you when a running spoof stops", v3.2.0 "If the connection drops mid-spoof, Vanish tells you" https://github.com/bhavyakhunt/vanish-releases/releases ; Locus `SpoofSession.swift` `.dropped` state + `postDropNotification` + health timer https://github.com/ChrisMack32/Locus/blob/main/Locus/Engine/SpoofSession.swift |
| A whole app doing exactly this exists under MIT, built with XcodeGen, vendoring idevice, sideloadable with Sideloadly: **ChrisMack32/Locus** (iOS 18.0 target). | https://github.com/ChrisMack32/Locus https://github.com/ChrisMack32/Locus/blob/main/project.yml https://github.com/ChrisMack32/Locus/blob/main/SETUP.md |
| Commercial proof of the same architecture: "Vanish Mobile" (getvanish.app) is installed once from a PC, names LocalDevVPN as its "connection helper" ("a loopback tunnel that lets the app reach your iPhone's own developer services"), accepts an uploaded pairing file ("Upload Pairing File"), and renews its 7-day signature on-device ("Settings, Renewal, 'Keep Vanish Installed'"). The tutorial states **no** iOS version requirement; the 17.4 floor is confirmed only for the RPPairing transport ("Remote pairing needs iOS 17.4 or later", idevice_pair README). getvanish.app is JS-rendered: WebFetch returns only the word "Vanish"; read it through a browser or `https://r.jina.ai/https://getvanish.app/tutorial`. | https://getvanish.app/tutorial https://getvanish.app/iphone-location-spoofer-without-computer https://github.com/bhavyakhunt/vanish-releases/releases/latest https://raw.githubusercontent.com/jkcoxson/idevice_pair/master/README.md |
| An unsigned IPA can be built on a GitHub Actions macOS runner with `CODE_SIGNING_ALLOWED=NO` and then signed by Sideloadly with a free Apple ID. | StikDebug `build_ipa.yml` https://github.com/StikDebug/StikDebug/blob/main/.github/workflows/build_ipa.yml ; Sideloadly FAQ https://sideloadly.io/faq.html |
| The prebuilt on-device library exists: `libidevice_ffi.a` + `idevice.h` + `module.modulemap` (vendored by StikDebug and Locus) and an `idevice-xcframework-v0.1.66.zip` release asset. | https://api.github.com/repos/StikDebug/StikDebug/contents/StikDebug/idevice https://github.com/ChrisMack32/Locus/tree/main/Vendor/idevice https://api.github.com/repos/jkcoxson/idevice/releases |

Note on Vanish: researcher 1 and 4 could only see the desktop USB product on getvanish.app (JS-only pages); researcher 3 fetched the tutorial page and confirmed an on-device "Vanish Mobile" with a LocalDevVPN helper. The tutorial text is the primary source, so treat Vanish Mobile as confirmed to exist; its internals are closed-source.

### Uncertain (details in section 7)

1. Which pairing file the user's phone will accept from the PC: the **RPPairing** (Ed25519) record is what current StikDebug/Locus use, and the PC's `pymobiledevice3 lockdown remotepairing --pair` record needs an added `identifier` key before idevice will read it. The derivation of that identifier is now **source-confirmed on both sides** (section 6, Route B); only the runtime pair-verify on the device is untested. The confirmed route is `idevice_pair` "Remote pairing" over USB.
2. Whether the older lockdown-pairing path (`10.7.0.1:62078` -> CoreDeviceProxy) still works over the loopback on iOS 18.7.8. Original StikJIT used it on 17.4-18.7.9 (https://stikjit.github.io/); current StikDebug only ships the RPPairing path.
3. Why the loopback only works on Wi-Fi or in Airplane Mode (rule documented, cause not).
4. Whether `_remotepairing._tcp` always binds to 49152 (Locus PR #2 says it can drift; on this phone `pymobiledevice3 remote browse` showed 49152).
5. First DDI mount needs internet (TSS at gs.apple.com) and must be repeated after every reboot.
6. Free Apple ID: 7-day expiry, 3-app cap; Sideloadly refresh needs the PC. SideStore + LocalDevVPN can refresh on-device but costs one of the 3 slots.

---

## 2. Architecture

### 2.1 Components on the phone

| Component | Source | Role |
|---|---|---|
| **LocalDevVPN** (App Store id 6755608044, Coxson Engineering LLC, free, iOS 14+, v1.3.0) | https://apps.apple.com/us/app/localdevvpn/id6755608044 ; source https://github.com/jkcoxson/LocalDevVPN | Packet-tunnel extension. Interface `10.7.1.1/32`, peer `10.7.0.1/32`, included route = peer /32 only, `excludedRoutes = [.default()]`; every IPv4 packet has src/dst swapped and is written back, so a TCP connect to `10.7.0.1:PORT` lands on the phone's own listener. Constants: https://raw.githubusercontent.com/jkcoxson/LocalDevVPN/main/LocalDevVPN/Constants.swift . Must come from the App Store: the NetworkExtension capability is blank for the free Apple Developer tier https://developer.apple.com/help/account/reference/supported-capabilities-ios/ and StosVPN (id 6744003051) is gone from all storefronts https://applecensorship.com/app-store-monitor/app/6744003051 . |
| **Mirage Go** (sideloaded, this repo) | - | SwiftUI app linking `libidevice_ffi.a`. Owns the pairing file, DDI files, tunnel, DVT session, keep-alive, map UI. |
| Phone daemons | iOS | `remotepairingd` on TCP 49152 (`_remotepairing._tcp`), `lockdownd` on 62078, `mobile_image_mounter`, `dtservicehub` (only once the DDI is mounted). |

### 2.2 Data flow (primary path = RPPairing, what StikDebug 3.1.10 / Locus use today)

```
PC (once, USB) --------------------------------------------------------------.
  idevice_pair "Remote pairing"  OR  pymobiledevice3 lockdown remotepairing --pair
  -> pairingFile.plist { public_key(32B Ed25519), private_key(32B), identifier(str), alt_irk? }
                                                                              |
Phone                                                                         v
  Files app / AFC ---> Mirage Go Documents/pairingFile.plist  (copied to App Support, chmod 600)
  LocalDevVPN connected  (10.7.0.1 -> self)
  Mirage Go:
    rp_pairing_file_read("...pairingFile.plist")                     [ffi/src/rp_pairing_file.rs]
    tunnel_create_rppairing(10.7.0.1:49152, "MirageGo", rpfile, nil, nil, &adapter, &handshake)
        = TCP -> RPPairing pair-verify (X25519/Ed25519, JSON)
          -> create_tcp_listener -> TLS-PSK CDTunnel (IPv6)
          -> userspace TCP adapter -> adapter_connect(server_rsd_port) -> RSD handshake
    lockdownd_connect_rsd + lockdownd_get_value("UniqueChipID")     (for the DDI mount)
    image_mounter_connect_rsd -> image_mounter_copy_devices (mounted?) 
        -> image_mounter_mount_personalized_with_callback_rsd(Image.dmg, .trustcache, BuildManifest.plist)
           (first time: idevice POSTs to http://gs.apple.com/TSS/controller?action=2 -> needs internet)
    remote_server_connect_rsd(adapter, handshake)  -> com.apple.instruments.dtservicehub
    location_simulation_new(remote_server)         -> channel com.apple.instruments.server.services.LocationSimulation
    location_simulation_set(h, lat, lon)           -> selector simulateLocationWithLatitude:longitude:
    ... repeat set() every 4 s while running ...
    location_simulation_clear(h)                   -> stopLocationSimulation
```

Sources: `tunnel_create_rppairing` doc and internals https://raw.githubusercontent.com/jkcoxson/idevice/master/ffi/src/tunnel_provider.rs ; RPPairing file fields https://raw.githubusercontent.com/jkcoxson/idevice/master/idevice/src/remote_pairing/rp_pairing_file.rs ; DVT channel/selectors https://raw.githubusercontent.com/jkcoxson/idevice/master/idevice/src/services/dvt/location_simulation.rs ; TSS fetch inside the mounter https://github.com/jkcoxson/idevice/blob/master/idevice/src/services/mobile_image_mounter.rs https://github.com/jkcoxson/idevice/blob/master/idevice/src/tss.rs ; StikDebug flow https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/Device/JITEnableContext.swift .

### 2.3 Fallback path (lockdown pairing file -> CoreDeviceProxy), kept behind a switch

The user's PC already has the classic lockdown record (`C:\Users\cenos\.pymobiledevice3\00008140-001939063A81801C.plist`, keys HostID/SystemBUID/HostCertificate/HostPrivateKey/RootCertificate/RootPrivateKey/DeviceCertificate/EscrowBag). This path is written out verbatim in `ffi/examples/location_simulation.c`:

```
idevice_pairing_file_read -> idevice_tcp_provider_new(10.7.0.1:62078, pf, "MirageGo")
 -> core_device_proxy_connect(provider) -> core_device_proxy_get_server_rsd_port
 -> core_device_proxy_create_tcp_adapter -> adapter_connect(rsd_port) -> rsd_handshake_new
 -> remote_server_connect_rsd -> location_simulation_new/set/clear
```
https://raw.githubusercontent.com/jkcoxson/idevice/master/ffi/examples/location_simulation.c . One-shot helper: `tunnel_create_usb(provider, &adapter, &handshake)` ("Creates a tunnel over USB via CoreDeviceProxy. No need to stop remoted.") https://raw.githubusercontent.com/jkcoxson/idevice/master/ffi/src/tunnel_provider.rs . On this path a **heartbeat** (`heartbeat_connect` + `heartbeat_get_marco`/`heartbeat_send_polo` loop) is mandatory: "iOS automatically closes service connections if there is no heartbeat client connected and responding" https://docs.rs/idevice/latest/idevice/services/heartbeat/index.html . Original StikJIT ran exactly this on iOS 17.4-18.7.9 https://raw.githubusercontent.com/SleeperOfSaturn/stikdebug/main/StikJIT/idevice/jit.c https://stikjit.github.io/ . Whether it still works on 18.7.8 over LocalDevVPN today is **(unverified)**; heartbeat/pairing failures were reported on iOS 26.4 Public Beta 1 ("Cannot connect to heartbeat after updating ... apple changed something with the pairing file" - reporter's guess, no maintainer statement about the cause) https://github.com/StephenDev0/StikDebug/issues/320 ; StikDebug now ships only the RPPairing path. Researchers disagree on whether a heartbeat is needed on the RPPairing path: StikDebug's location simulator does not open one (only its JIT session does), so follow StikDebug and skip it there.

### 2.4 Backgrounding strategy (copy StikDebug)

- The DTX connection must stay open: "a connection must be maintained to keep location simulated" https://raw.githubusercontent.com/jkcoxson/idevice/master/idevice/src/services/dvt/location_simulation.rs . iOS suspends a backgrounded app, which kills the socket.
- `Info.plist` `UIBackgroundModes` = `audio`, `location` (StikDebug also has `fetch`; Locus has `audio`, `location`, `processing`) https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/Info.plist https://github.com/ChrisMack32/Locus/blob/main/Locus/Resources/Info.plist . These are plist keys, not entitlements, so a free-ID Sideloadly build can use them: Apple DTS (Quinn) "`UIBackgroundModes` is an `Info.plist` property, not an entitlement" https://developer.apple.com/forums/thread/791736 , and both StikDebug and Locus ship them in free-ID sideloads. (Apple's capabilities table lists "Background modes" as a capability that the free tier lacks https://developer.apple.com/help/account/reference/supported-capabilities-ios/ ; that governs the Xcode capability/profile, not the plist key.)
- Silent audio: `AVAudioSession` category `.playback` with `.mixWithOthers`, `AVAudioEngine` + `AVAudioPlayerNode` looping a zero-filled `AVAudioPCMBuffer`, 2 s timer to reclaim the session https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/Services/BackgroundAudioManager.swift .
- Background location: `CLLocationManager` with `allowsBackgroundLocationUpdates = true`, `pausesLocationUpdatesAutomatically = false`, `desiredAccuracy = kCLLocationAccuracyThreeKilometers`, `distanceFilter = CLLocationDistanceMax`, `requestAlwaysAuthorization()` https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/Services/BackgroundLocationManager.swift . Needs `NSLocationAlwaysAndWhenInUseUsageDescription` + `NSLocationWhenInUseUsageDescription` (StikDebug injects them via `INFOPLIST_KEY_*` build settings) https://github.com/StikDebug/StikDebug/blob/main/StikDebug.xcodeproj/project.pbxproj .
- `UIApplication.shared.beginBackgroundTask(withName:)` around the session https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/Services/DebugKeepAliveLease.swift (StikDebug `MapSelectionView.swift` line ~1371 does the same). This buys only ~30 s https://developer.apple.com/forums/thread/125162 ; do **not** rely on it - the audio + location modes are what actually keep the process alive.
- Re-send `location_simulation_set` every 4 s (StikDebug) / 8 s + 12 s health timer (Locus) / 5 s (idevice CLI) on one serial queue; the FFI handles are "NOT thread safe" and a stream must be used on the adapter's thread https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/idevice/idevice.h https://github.com/ChrisMack32/Locus/blob/main/Locus/Engine/SpoofSession.swift .
- On scene `.active` after `.background`, verify the session (a `set()` call) and rebuild the tunnel on error. Note: StikDebug's foreground reconnect (`shouldAttemptTunnelReconnect` -> `startTunnelInBackground`) is for the **JIT/debug tunnel**, not for the `LocationSimulationState` handles used by `simulate_location`; `MapSelectionView.swift` has no `scenePhase` handling for the location session at all https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/App/StikDebugApp.swift https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/Views/MapSelectionView.swift . So Mirage Go needs its **own health loop** (Locus-style: resend every 4-8 s, verify every 12 s, rebuild the tunnel on error, post a "spoof dropped" local notification) https://github.com/ChrisMack32/Locus/blob/main/Locus/Engine/SpoofSession.swift , plus an `NWPathMonitor`/`getifaddrs` check that the `10.7.x` interface is still up (re-open `localdevvpn://enable` if not). Vanish v3.1.0 added a Live Activity so the session state is visible on the Lock Screen https://github.com/bhavyakhunt/vanish-releases/releases - worth copying.
- Whether the tunnel survives the phone sleeping/locking for hours is **(unverified)** and is a test item (section 7 #7), not a property: Vanish's tutorial says "The helper runs as a VPN configuration, so iOS can switch it off" https://getvanish.app/tutorial ; lantian.pub reports StosVPN "often disconnects automatically and cannot stay in the background for a long time" https://lantian.pub/en/article/modify-computer/sidestore-without-stosvpn-across-lan.lantian/ ; idevice reports `HeartbeatSleepyTime` when the device sleeps.

### 2.5 DDI (re)mount strategy

- Files (one image for all iOS 17+): `BuildManifest.plist` (801,505 B), `Image.dmg` (15,733,248 B), `Image.dmg.trustcache` (1,895 B) from `https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/` https://github.com/doronz88/DeveloperDiskImage https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/Services/DeveloperDiskImageService.swift . The same three files already sit on this PC in `C:\Users\cenos\.pymobiledevice3\Xcode_iOS_DDI_Personalized\` (byte-identical sizes; trustcache md5 matches doronz88) and can be bundled in the app or copied over AFC as a fallback to downloading - **but the local trustcache is named `Image.trustcache`, not `Image.dmg.trustcache`** (verified 2026-09-09: `BuildManifest.plist` 801,505 / `Image.dmg` 15,733,248 / `Image.trustcache` 1,895). Rename it when bundling, or the "trustcache exists" re-mount trigger below never fires. Prefer the in-app download from doronz88 as the primary path.
- Store in `Documents/DDI/`; download only if missing; offer "Redownload DDI".
- Mounted check: `image_mounter_copy_devices(client, &devices, &count)` > 0 - StikDebug `IdeviceFFIBridge.swift` `getMountedDeviceCount()` (lines 265-292; `MountingProgress.swift` only calls `isMounted()`) https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/Device/IdeviceFFIBridge.swift . C signature: `image_mounter_copy_devices(struct ImageMounterHandle *client, plist_t **devices, size_t *devices_len)` (vendored `idevice.h` line 3838) - the out-param is a **plist_t array**, freed with `plist_free` per element + `idevice_data_free` on the array.
- Mount call: `lockdownd_connect_rsd` -> `lockdownd_get_value(lc, "UniqueChipID", nil, &plist)` -> `image_mounter_connect_rsd` -> `image_mounter_mount_personalized_with_callback_rsd(im, adapter, handshake, image, len, trustcache, len, manifest, len, nil, ecid, cb, ctx)` https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/Device/IdeviceFFIBridge.swift https://raw.githubusercontent.com/jkcoxson/idevice/master/ffi/src/mobile_image_mounter.rs .
- Internet rule: `mount_personalized_with_callback` first tries `query_personalization_manifest`; on failure it fetches the manifest from Apple's TSS (`http://gs.apple.com/TSS/controller?action=2`) https://github.com/jkcoxson/idevice/blob/master/idevice/src/services/mobile_image_mounter.rs https://github.com/jkcoxson/idevice/blob/master/idevice/src/tss.rs . So the first mount (and any mount after the device-side cache is lost) needs internet on the phone; SideStore's guidance is "Open StikDebug with Wi-Fi and the VPN connected ... then force close it and reopen it" and the mount "must be done first, every time you restart your device" https://docs.sidestore.io/docs/advanced/jit .
- Re-mount trigger: on every app launch and after every successful tunnel, if not mounted and the trustcache exists (StikDebug `TunnelManager` calls `MountingProgress.shared.pubMount()` after tunnel creation, line 79, and does **not** open a new tunnel afterwards) https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/Services/TunnelManager.swift . After a mount, create a **fresh** tunnel before `remote_server_connect_rsd`: this is what StikDebug effectively does - `simulate_location` opens its own dedicated tunnel (static `LocationSimulationState` adapter/handshake/remoteServer/locationSimulation handles, reused on later `set()` calls, freed in `clear_simulated_location`) https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/Device/IdeviceFFIBridge.swift . Rationale **(inferred from code, not a docs quote)**: `RsdHandshake::new` fills `services` once from `recv_root()` and has no refresh method https://raw.githubusercontent.com/jkcoxson/idevice/master/idevice/src/services/rsd.rs (the docs.rs page https://docs.rs/idevice/latest/idevice/services/rsd/struct.RsdHandshake.html has no doc comment saying "captured at handshake time"). Confirm with `rsd_service_available(handshake, "com.apple.instruments.dtservicehub", &b)`. Without the DDI you get `No such service: com.apple.instruments.dtservicehub` https://github.com/doronz88/pymobiledevice3/issues/1083 .
- Developer Mode must be on (Settings > Privacy & Security > Developer Mode, requires restart) https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device https://stikdebug.org/ .

### 2.6 Airplane-mode / cellular rule

Documented rule, cause undocumented by all maintainers:
- "Start by opening LocalDevVPN on Wi-Fi or Airplane Mode. Now, if using cellular data, start the VPN, enable Airplane Mode, then switch back to cellular." https://docs.sidestore.io/docs/advanced/jit
- "A Wi-Fi connection (not just any internet connection: mobile network is not suitable)" https://docs.sidestore.io/docs/installation/prerequisites
- StikDebug: "Heartbeat errors -> Ensure that the VPN is on and that you are connected to Wi-Fi" https://raw.githubusercontent.com/StikDebug/StikDebug/main/README.md ; Locus: "Start a teleport on Wi-Fi first; the session can keep working on cellular afterward." https://github.com/ChrisMack32/Locus
- **Leaving Wi-Fi after starting is (unverified)**: Locus issue #1 (open, no maintainer reply, iOS 27 beta 4) reports "Location reverts back when switching from wifi to mobile data" and cannot be re-spoofed until back on Wi-Fi https://github.com/ChrisMack32/Locus/issues/1 ; Vanish needed "Mobile data support without Airplane Mode requirement" (v2.2.0) and a guided cellular card (v3.1.0/v3.2.0) https://github.com/bhavyakhunt/vanish-releases/releases . Nothing confirms the transition on iOS 18.7.8, so it is test item section 7 #6(c). In the app, watch `NWPathMonitor` for path changes and re-send/rebuild the session immediately; keep the Airplane-Mode recipe as the documented fallback.
- Practical Mirage Go rule to show in the UI: (1) first run of the day on Wi-Fi with internet (DDI/TSS); (2) connect LocalDevVPN while on Wi-Fi or with Airplane Mode on; (3) start the spoof; (4) leaving Wi-Fi afterwards *may* work (see above). If you are cellular-only: Airplane Mode on -> connect VPN -> start spoof -> re-enable cellular with Airplane Mode still on. Add a `getifaddrs` check for a `10.7.` interface before connecting (Locus `LocalDevVPN.swift`) https://github.com/ChrisMack32/Locus/blob/main/Locus/Support/LocalDevVPN.swift .

---

## 3. Library choice and exact API calls

### 3.1 Choice: jkcoxson/idevice C FFI, prebuilt, statically linked

- Crate `idevice` 0.1.65 on crates.io (2026-07-11), GitHub release **v0.1.66** (2026-08-25), MIT https://crates.io/api/v1/crates/idevice https://api.github.com/repos/jkcoxson/idevice/releases .
- No Swift package wrapper exists (no `IDeviceSwift`/`idevice-swift` repo) https://api.github.com/search/repositories?q=IDeviceSwift+OR+idevice-swift+OR+idevice_swift&sort=updated . `swift/Package.swift` in the repo is a path-based `binaryTarget(name: "IDevice", path: "IDevice.xcframework")` manifest, module map `module IDevice { header "idevice.h" export * }` https://raw.githubusercontent.com/jkcoxson/idevice/master/swift/Package.swift https://raw.githubusercontent.com/jkcoxson/idevice/master/swift/include/module.modulemap .
- Building the Rust lib "requires a Mac" (`cargo build --release --target aarch64-apple-ios --features obfuscate` + `xcodebuild -create-xcframework`) https://raw.githubusercontent.com/jkcoxson/idevice/master/justfile , so use a prebuilt:

| Option | Coordinates | Notes |
|---|---|---|
| A (recommended, verified layout) | Vendor three files exactly as StikDebug does: `StikDebug/idevice/idevice.h` (277,754 B on `main` as of 2026-09-09 - it changes between commits), `libidevice_ffi.a` (97,089,368 B arm64 static, plain git blob - StikDebug has no root `.gitattributes`, so it is not an LFS pointer; starts with `!<arch>`), `module.modulemap` (60 B: `module idevice [system] { header "idevice.h" export * }` - keep the `[system]` attribute, it silences warnings from the cbindgen/plist header) https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/idevice/module.modulemap https://github.com/StikDebug/StikDebug/tree/main/StikDebug/idevice ; Locus keeps the same trio in `Vendor/idevice` (MIT) but its `.a` is a **different build** (95,405,912 B), so the two vendored trios are not interchangeable https://github.com/ChrisMack32/Locus/tree/main/Vendor/idevice | 92.6 MiB is under GitHub's 100 MiB hard limit but over the 50 MiB warning; either commit with Git LFS or have CI `curl` it (raw download verified working, HTTP 200 + correct Content-Length on 2026-09-09). Pin `IDEVICE_REF` to a StikDebug **commit SHA**, not `main`, so the header/.a pair stays the one you tested. StikDebug's copy is the one proven on 17.4-18.x. |
| B | `https://github.com/jkcoxson/idevice/releases/download/v0.1.66/idevice-xcframework-v0.1.66.zip` (211.82 MB per the first research pass; asset names/sizes could not be re-read on 2026-09-09 - unauthenticated GitHub API rate limit) https://github.com/jkcoxson/idevice/releases | Should contain `IDevice.xcframework` (justfile zips only that); whether `Package.swift`/`plist.xcframework` are inside is **(unverified)**. Add as `binaryTarget` or drop the xcframework into the project. |
| C | StikJIT.xcframework https://github.com/StikDebug/StikJIT | JIT-only API surface; does not expose location simulation. Not suitable. |

Also link `-lc++ -lz` (Locus `project.yml`) https://github.com/ChrisMack32/Locus/blob/main/project.yml . Header generated by cbindgen; `plist.h` is appended to `idevice.h` https://raw.githubusercontent.com/jkcoxson/idevice/master/ffi/build.rs .

### 3.2 API calls in order (all names from `ffi/src/*.rs` unless marked)

Handles are opaque C pointers; StikDebug declares `typealias RpPairingFileHandle = OpaquePointer` etc. https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/Device/mountDDI.swift .

1. `idevice_init_logger(IdeviceLogLevel console, IdeviceLogLevel file, char* file_path)` (levels Disabled=0..Trace=5) https://raw.githubusercontent.com/jkcoxson/idevice/master/ffi/src/logging.rs
2. `rp_pairing_file_read(const char* path, RpPairingFileHandle** out)` https://raw.githubusercontent.com/jkcoxson/idevice/master/ffi/src/rp_pairing_file.rs
3. `tunnel_create_rppairing(const idevice_sockaddr* addr, idevice_socklen_t addr_len, const char* hostname, RpPairingFileHandle* pairing_file, const char*(*pin_callback)(void*), void* pin_context, AdapterHandle** out_adapter, RsdHandshakeHandle** out_handshake)` https://raw.githubusercontent.com/jkcoxson/idevice/master/ffi/src/tunnel_provider.rs
4. DDI: `lockdownd_connect_rsd(adapter, handshake, &lc)`, `lockdownd_get_value(lc, "UniqueChipID", NULL, &plist)`, `image_mounter_connect_rsd(adapter, handshake, &im)`, `image_mounter_copy_devices(im, &devices, &count)`, `image_mounter_mount_personalized_with_callback_rsd(...)` https://raw.githubusercontent.com/jkcoxson/idevice/master/ffi/src/lockdown.rs https://raw.githubusercontent.com/jkcoxson/idevice/master/ffi/src/mobile_image_mounter.rs
5. `remote_server_connect_rsd(AdapterHandle*, RsdHandshakeHandle*, RemoteServerHandle**)` https://raw.githubusercontent.com/jkcoxson/idevice/master/ffi/src/dvt/remote_server.rs
6. `location_simulation_new(RemoteServerHandle*, LocationSimulationHandle**)`, `location_simulation_set(handle, double lat, double lon)`, `location_simulation_clear(handle)`, `location_simulation_free(handle)` https://raw.githubusercontent.com/jkcoxson/idevice/master/ffi/src/dvt/location_simulation.rs
7. Teardown in reverse: `location_simulation_free`, `remote_server_free`, `rsd_handshake_free`, `adapter_free`, `rp_pairing_file_free`.
8. Errors: `IdeviceFfiError { int32 code; int32 sub_code; char* message }`, free with `idevice_error_free` https://raw.githubusercontent.com/jkcoxson/idevice/master/ffi/src/errors.rs . StikDebug maps code -9 = invalid pairing file, -18 = bad IP, 48 = port in use, 54 = connection reset https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/Services/TunnelManager.swift . **Caveat on -9**: it fires when the file fails to *parse* (`rp_pairing_file_read`). A well-formed file whose `identifier` the device does not recognise fails pair-verify, and idevice's `RemotePairingClient::connect` then silently falls back to a full pair-**setup** using the PIN callback (`if self.validate_pairing(pairing_file).await.is_err() { self.pair(pairing_file, pin_callback).await?; }`) https://raw.githubusercontent.com/jkcoxson/idevice/master/idevice/src/remote_pairing/mod.rs ; with `pin_callback = nil` the FFI's `get_pin` returns the hard-coded `"000000"` https://raw.githubusercontent.com/jkcoxson/idevice/master/ffi/src/tunnel_provider.rs (line 426-436). So a rejected pairing shows up as a pair-setup/PIN error or timeout **after** a successful read, not as -9. In the bridge, pass a real `pin_callback` (or at least log the full `IdeviceFfiError.message`) and treat any error after `rp_pairing_file_read` succeeded as "device rejected pairing". Side effect worth one experiment: that fallback means the app could in principle self-pair if iOS shows a pairing PIN on the same phone **(untested)**.
9. Also present in the vendored header (line 3407-3437): `lockdown_location_simulation_new/set/clear/free` over an `IdeviceHandle` socket - a lockdown-service variant of location simulation that does not go through RSD/DVT. Not used by StikDebug's location tab; whether it works over the loopback on iOS 18 is **(unverified)**, but it is a cheap second path to try.

Fallback path names (section 2.3): `idevice_pairing_file_read`, `idevice_tcp_provider_new(const idevice_sockaddr*, IdevicePairingFile*, const char* label, IdeviceProviderHandle**)`, `tunnel_create_usb(provider, &adapter, &handshake)`, `heartbeat_connect_rsd` / `heartbeat_get_marco(client, uint64 interval, uint64* new_interval)` / `heartbeat_send_polo` https://raw.githubusercontent.com/jkcoxson/idevice/master/ffi/src/provider.rs https://raw.githubusercontent.com/jkcoxson/idevice/master/ffi/src/heartbeat.rs . Optional self-pairing helper `tunnel_pair_usb(lockdown_provider, hostname, pin_callback, pin_context, RpPairingFileHandle**)` could create an RPPairing file from the lockdown record over the loopback - **(unverified, nobody has tested it on-device)**.

### 3.3 Swift sketches

`MirageGo/IdeviceBridge.swift` (mirrors StikDebug `IdeviceFFIBridge.swift`):

```swift
import Foundation
import idevice   // module name from module.modulemap; StikDebug uses `import idevice`

typealias RpPairingFileHandle = OpaquePointer
typealias AdapterHandle = OpaquePointer
typealias RsdHandshakeHandle = OpaquePointer
typealias RemoteServerHandle = OpaquePointer
typealias LocationSimulationHandle = OpaquePointer

enum BridgeError: Error { case ffi(code: Int32, message: String), badIP, pairingRead }

func check(_ err: UnsafeMutablePointer<IdeviceFfiError>?) throws {
    guard let err else { return }
    let msg = err.pointee.message.map { String(cString: $0) } ?? "unknown"
    let code = err.pointee.code
    idevice_error_free(err)
    throw BridgeError.ffi(code: code, message: msg)
}

/// All FFI handles live on this one serial queue (idevice.h: handles are NOT thread safe).
let ffiQueue = DispatchQueue(label: "net.summitclient.mirage-go.ffi")

final class Tunnel {
    var pairing: RpPairingFileHandle?
    var adapter: AdapterHandle?
    var handshake: RsdHandshakeHandle?

    /// StikDebug JITEnableContext.createTunnel(hostname:) equivalent.
    static func open(pairingPath: String, ip: String = "10.7.0.1", port: UInt16 = 49152,
                     hostname: String = "MirageGo") throws -> Tunnel {
        let t = Tunnel()
        try check(rp_pairing_file_read(pairingPath, &t.pairing))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { throw BridgeError.badIP }
        try withUnsafePointer(to: &addr) { p in
            try p.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { sa in
                // pin_callback nil => idevice uses "000000" if pair-verify fails and it falls back to pair-setup
                // (section 3.2 #8). Pass a real callback in production so a rejected pairing is diagnosable.
                try check(tunnel_create_rppairing(sa, idevice_socklen_t(MemoryLayout<sockaddr_in>.stride),
                                                  hostname, t.pairing, nil, nil, &t.adapter, &t.handshake))
            }
        }
        return t
    }

    func close() {
        if let h = handshake { rsd_handshake_free(h) }
        if let a = adapter { adapter_free(a) }
        if let p = pairing { rp_pairing_file_free(p) }
        handshake = nil; adapter = nil; pairing = nil
    }
}

final class LocationSession {
    private let tunnel: Tunnel
    private var server: RemoteServerHandle?
    private var sim: LocationSimulationHandle?

    init(tunnel: Tunnel) throws {
        self.tunnel = tunnel
        try check(remote_server_connect_rsd(tunnel.adapter, tunnel.handshake, &server))   // needs DDI mounted
        try check(location_simulation_new(server, &sim))
    }
    func set(lat: Double, lon: Double) throws { try check(location_simulation_set(sim, lat, lon)) }
    func clear() throws { try check(location_simulation_clear(sim)) }
    deinit {
        if let s = sim { location_simulation_free(s) }
        if let r = server { remote_server_free(r) }
    }
}
```

`MirageGo/DDIMounter.swift` (StikDebug `mountPersonalDDI` equivalent; parameter order verified 2026-09-09 against the vendored `idevice.h` line 4154: `client, provider(adapter), handshake, image, image_len, trust_cache, trust_cache_len, build_manifest, build_manifest_len, info_plist, unique_chip_id, callback(progress,total,ctx), context` - re-grep before compiling because the header changes between StikDebug commits):

```swift
/// Copy of StikDebug IdeviceFFIBridge.swift getMountedDeviceCount() (lines 265-292).
func isDDIMounted(_ t: Tunnel) throws -> Bool {
    var im: OpaquePointer?
    try check(image_mounter_connect_rsd(t.adapter, t.handshake, &im))
    defer { image_mounter_free(im) }                       // verified: idevice.h line 3821
    var devices: UnsafeMutablePointer<plist_t?>? = nil     // C: plist_t **devices, size_t *devices_len
    var count: Int = 0
    try check(image_mounter_copy_devices(im, &devices, &count))
    if let devices {
        for i in 0..<count { plist_free(devices[i]) }
        idevice_data_free(UnsafeMutableRawPointer(devices).assumingMemoryBound(to: UInt8.self),
                          UInt(count * MemoryLayout<plist_t?>.stride))
    }
    return count > 0
}

func mountDDI(_ t: Tunnel, dir: URL, progress: @escaping (Double) -> Void) throws {
    let image = try Data(contentsOf: dir.appendingPathComponent("Image.dmg"))
    let tc    = try Data(contentsOf: dir.appendingPathComponent("Image.dmg.trustcache"))
    let bm    = try Data(contentsOf: dir.appendingPathComponent("BuildManifest.plist"))
    var lc: OpaquePointer?; var plist: OpaquePointer?
    try check(lockdownd_connect_rsd(t.adapter, t.handshake, &lc))
    try check(lockdownd_get_value(lc, "UniqueChipID", nil, &plist))
    let ecid: UInt64 = plist_get_uint_val_swift(plist)     // use plist_* accessors bundled in libidevice_ffi.a (plist_ffi 0.1.6)
    var im: OpaquePointer?
    try check(image_mounter_connect_rsd(t.adapter, t.handshake, &im))
    try image.withUnsafeBytes { i in try tc.withUnsafeBytes { c in try bm.withUnsafeBytes { m in
        try check(image_mounter_mount_personalized_with_callback_rsd(
            im, t.adapter, t.handshake,
            i.baseAddress, image.count, c.baseAddress, tc.count, m.baseAddress, bm.count,
            nil, ecid,
            { done, total, ctx in /* forward to progress */ }, nil))
    }}}
}
```

`MirageGo/SpoofEngine.swift` (resend loop + keep-alive, StikDebug `MapSelectionView.startResendLoop` / Locus `SpoofSession`):

```swift
@MainActor final class SpoofEngine: ObservableObject {
    @Published var running = false
    private var timer: Timer?
    private var bgTask = UIBackgroundTaskIdentifier.invalid
    private var tunnel: Tunnel?; private var session: LocationSession?

    func start(lat: Double, lon: Double, pairingPath: String) {
        BackgroundAudioManager.shared.start()          // silent looping buffer, .playback + .mixWithOthers
        BackgroundLocationManager.shared.start()       // allowsBackgroundLocationUpdates, 3 km accuracy
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "MirageGoSpoof") { [weak self] in self?.stop() }
        ffiQueue.async {
            do {
                let t = try Tunnel.open(pairingPath: pairingPath)
                let s = try LocationSession(tunnel: t)
                try s.set(lat: lat, lon: lon)
                DispatchQueue.main.async { self.tunnel = t; self.session = s; self.running = true; self.armTimer(lat, lon) }
            } catch { /* surface error; -9 -> "pairing file unreadable"; any error AFTER rp_pairing_file_read succeeded
                         -> "device rejected pairing (re-pair on PC)"; 54/timeouts -> "is LocalDevVPN connected?" */ }
        }
    }
    private func armTimer(_ lat: Double, _ lon: Double) {
        // Health loop (Locus SpoofSession pattern): resend every 4 s; on any error rebuild Tunnel+LocationSession,
        // check VPNLauncher.tunnelUp (re-open localdevvpn://enable if false), and post a "spoof dropped"
        // UNUserNotification if the rebuild fails. beginBackgroundTask only buys ~30 s - this loop is what keeps it alive.
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            ffiQueue.async { try? self?.session?.set(lat: lat, lon: lon) }   // on error: rebuild tunnel
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        ffiQueue.async { try? self.session?.clear(); self.session = nil; self.tunnel?.close(); self.tunnel = nil }
        BackgroundAudioManager.shared.stop(); BackgroundLocationManager.shared.stop()
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
        running = false
    }
}
```

`MirageGo/VPNLauncher.swift` (LocalDevVPN URL scheme; `localdevvpn://enable?scheme=<callback>` starts the tunnel then opens `<callback>://` after 1 s) https://raw.githubusercontent.com/jkcoxson/LocalDevVPN/main/LocalDevVPN/LocalDevVPNApp.swift :

```swift
import UIKit
enum VPNLauncher {
    static var installed: Bool { UIApplication.shared.canOpenURL(URL(string: "localdevvpn://")!) } // needs LSApplicationQueriesSchemes
    static func connect() { UIApplication.shared.open(URL(string: "localdevvpn://enable?scheme=miragego")!) }
    /// Locus-style check: any interface with a 10.7.x address means the tunnel is up.
    static var tunnelUp: Bool {
        var ifa: UnsafeMutablePointer<ifaddrs>?; guard getifaddrs(&ifa) == 0 else { return false }
        defer { freeifaddrs(ifa) }
        var p = ifa; var found = false
        while let i = p {
            if i.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var a = sockaddr_in(); memcpy(&a, i.pointee.ifa_addr, MemoryLayout<sockaddr_in>.size)
                if String(cString: inet_ntoa(a.sin_addr)).hasPrefix("10.7.") { found = true }
            }
            p = i.pointee.ifa_next
        }
        return found
    }
}
```

Pairing-file import: SwiftUI `.fileImporter(allowedContentTypes: [.propertyList, UTType(filenameExtension: "mobiledevicepairing")!, ...])`, copy to `Application Support/Pairing/pairingFile.plist` with `chmod 0600`; also auto-adopt `Documents/pairingFile.plist` on launch so `idevice_pair`/iloader/Files can drop it there over AFC (`UIFileSharingEnabled`) https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/Support/PairingFileStore.swift . Sideloaded apps need the document-picker `asCopy: true` workaround StikDebug swizzles in `AppBootstrapper.applyDocumentPickerCopyWorkaround()` https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/App/AppBootstrapper.swift .

---

## 4. Repo layout (no Mac): XcodeGen + GitHub Actions

Existing scaffold in `C:/Users/cenos/OneDrive/Desktop/ClaudeCode/mirage-go/` (project.yml, `.github/workflows/build.yml`, `MirageGo/MirageGoApp.swift`, `ContentView.swift`) is a good skeleton but is missing the idevice link, background modes, usage strings, URL schemes and the 17.4 floor. Replace with the following.

```
mirage-go/
  project.yml
  .github/workflows/build.yml
  Vendor/idevice/idevice.h            # from StikDebug/idevice or Locus/Vendor/idevice
  Vendor/idevice/module.modulemap     # copy verbatim from StikDebug: module idevice [system] { header "idevice.h" export * }
  Vendor/idevice/libidevice_ffi.a     # 97 MB: Git LFS, or fetched by CI (see workflow)
  MirageGo/
    Info.plist                        # generated by XcodeGen from project.yml (GENERATE_INFOPLIST_FILE=NO)
    MirageGo.entitlements
    MirageGoApp.swift                 # scene phase -> reconnect; handles miragego:// callback
    ContentView.swift                 # map + Start/Stop + status
    IdeviceBridge.swift  DDIMounter.swift  SpoofEngine.swift  VPNLauncher.swift
    PairingFileStore.swift  DDIDownloader.swift
    BackgroundAudioManager.swift  BackgroundLocationManager.swift
    Assets.xcassets/
  RESEARCH.md  README.md  .gitignore
```

### 4.1 project.yml

```yaml
name: MirageGo
options:
  bundleIdPrefix: net.summitclient
  deploymentTarget:
    iOS: "17.4"            # tunnel_create_rppairing / CoreDeviceProxy need 17.4+ (StikDebug/Locus floor)
  createIntermediateGroups: true
  xcodeVersion: "16.0"
settings:
  base:
    SWIFT_VERSION: "5.0"   # MUST be a language mode (4.0/4.2/5.0/6.0), quoted; "5.10" is a compiler release and xcodebuild aborts:
                           # "SWIFT_VERSION '...' is unsupported, supported versions are: 4.0, 4.2, 5.0, 6.0." (https://developer.apple.com/forums/thread/774709)
                           # StikDebug pbxproj: SWIFT_VERSION = 5.0 ; Locus project.yml: SWIFT_VERSION: "5.0"
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
    CODE_SIGN_IDENTITY: ""
    CODE_SIGNING_REQUIRED: "NO"
    CODE_SIGNING_ALLOWED: "NO"
    DEVELOPMENT_TEAM: ""
    ENABLE_BITCODE: "NO"
targets:
  MirageGo:
    type: application
    platform: iOS
    sources:
      - path: MirageGo
    entitlements:
      path: MirageGo/MirageGo.entitlements
      properties: {}          # Sideloadly replaces entitlements with its free-profile set anyway
    info:
      path: MirageGo/Info.plist
      properties:
        CFBundleDisplayName: Mirage Go
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        UILaunchScreen: {}
        UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]
        UIUserInterfaceStyle: Dark
        ITSAppUsesNonExemptEncryption: false
        UIBackgroundModes: [audio, location]
        NSLocationWhenInUseUsageDescription: Mirage Go uses location to stay running in the background and keep your simulated location active.
        NSLocationAlwaysAndWhenInUseUsageDescription: Mirage Go uses location to stay running in the background and keep your simulated location active.
        NSLocalNetworkUsageDescription: Mirage Go talks to your iPhone's own developer service through LocalDevVPN.
        NSBonjourServices: [_remotepairing._tcp, _remotepairing-pairable-host._tcp, _remoted._tcp]
        # No NSAppTransportSecurity needed: idevice's TSS fetch (http://gs.apple.com/TSS/controller?action=2, plain HTTP)
        # uses its own Rust HTTP/1.1 client over a raw tokio TcpStream, not NSURLSession/CFNetwork, so ATS is never
        # consulted (idevice/src/http.rs, tss.rs). Add NSAllowsArbitraryLoads only if the app itself hits a plain-HTTP URL
        # via URLSession. A failing TSS fetch means "no internet on the phone", not an ATS block.
        LSApplicationQueriesSchemes: [localdevvpn]
        CFBundleURLTypes:
          - CFBundleURLName: net.summitclient.mirage-go
            CFBundleURLSchemes: [miragego]
        UIFileSharingEnabled: true
        LSSupportsOpeningDocumentsInPlace: true
        UISupportsDocumentBrowser: true
        CFBundleDocumentTypes:
          - CFBundleTypeName: Pairing file
            LSHandlerRank: Alternate
            LSItemContentTypes: [com.apple.property-list, public.data]
            CFBundleTypeExtensions: [plist, mobiledevicepairing, mobiledevicepair]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: net.summitclient.mirage-go
        TARGETED_DEVICE_FAMILY: "1"
        GENERATE_INFOPLIST_FILE: "NO"
        SWIFT_INCLUDE_PATHS: $(PROJECT_DIR)/Vendor/idevice
        HEADER_SEARCH_PATHS: $(PROJECT_DIR)/Vendor/idevice
        LIBRARY_SEARCH_PATHS: $(PROJECT_DIR)/Vendor/idevice
        OTHER_LDFLAGS: -lidevice_ffi -lc++ -lz
        # SWIFT_OBJC_INTEROP_MODE: objc is the default; omitted.
```

XcodeGen notes (verified): `entitlements.properties` defaults to `[:]` (`Sources/ProjectSpec/Plist.swift`: `properties = jsonDictionary.json(atKeyPath: "properties") ?? [:]`), so `properties: {}` yields an empty entitlements plist + `CODE_SIGN_ENTITLEMENTS`, which `CODE_SIGNING_ALLOWED=NO` then ignores and Sideloadly replaces https://raw.githubusercontent.com/yonaskolb/XcodeGen/master/Sources/ProjectSpec/Plist.swift ; string `deploymentTarget` and `xcodeVersion` are the documented forms https://raw.githubusercontent.com/yonaskolb/XcodeGen/master/Docs/ProjectSpec.md . ATS keys: see the comment above (idevice `http.rs`: "this module speaks HTTP/1.1 directly", `tokio::net::TcpStream::connect`) https://raw.githubusercontent.com/jkcoxson/idevice/master/idevice/src/http.rs https://raw.githubusercontent.com/jkcoxson/idevice/master/idevice/src/tss.rs .

Key sources: Locus `project.yml` (`SWIFT_VERSION: "5.0"`, `-lidevice_ffi -lc++ -lz`, the three search paths, iOS 18.0) https://github.com/ChrisMack32/Locus/blob/main/project.yml ; StikDebug pbxproj (`SWIFT_INCLUDE_PATHS = $(PROJECT_DIR)/StikDebug/idevice`, `IPHONEOS_DEPLOYMENT_TARGET = 17.4`, `INFOPLIST_KEY_NSLocation*`, `LSSupportsOpeningDocumentsInPlace`, `ITSAppUsesNonExemptEncryption = NO`) https://github.com/StikDebug/StikDebug/blob/main/StikDebug.xcodeproj/project.pbxproj ; StikDebug Info.plist (`UIBackgroundModes`, `UIFileSharingEnabled`) https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/Info.plist ; Locus Info.plist (`NSBonjourServices`, `LSApplicationQueriesSchemes: localdevvpn`, `CFBundleDocumentTypes`) https://github.com/ChrisMack32/Locus/blob/main/Locus/Resources/Info.plist .

Entitlements: none are required. StikDebug ships `app-sandbox`, an app group and `files.user-selected.read-only` https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/StikDebug.entitlements ; Locus ships `network.client/server` + `get-task-allow` https://github.com/ChrisMack32/Locus/blob/main/Locus/Resources/Locus.entitlements . `get-task-allow` is only for debugger/JIT attach and is added automatically to development profiles https://developer.apple.com/forums/thread/118415 ; Sideloadly custom entitlements are paid-program + Patreon only https://sideloadly.io/changelog.html . Keep `MirageGo.entitlements` an empty dict.

### 4.2 `.github/workflows/build.yml` (outputs unsigned `MirageGo.ipa`)

```yaml
name: Build IPA

on:
  push:
    branches: [main]
  workflow_dispatch:

env:
  # Pin to the StikDebug COMMIT SHA you tested, not `main`: idevice.h/.a change between commits
  # (idevice.h was 277,754 B on main on 2026-09-09; the .a 97,089,368 B). Replace the SHA before first run.
  IDEVICE_REF: main
  IDEVICE_A_SIZE: "97089368"

jobs:
  build:
    # macos-26 = GA, default Xcode 26.6, same as StikDebug's `macos-latest` (the only combination proven to
    # link StikDebug's libidevice_ffi.a). macos-15 (default Xcode 16.4, 26.0.1-26.3 also installed) would need
    # `sudo xcode-select -s /Applications/Xcode_26.3.app` or maxim-lobanov/setup-xcode; linking under Xcode 16.4's
    # ld is unexercised. macos-14 is already deprecated; runner-images keeps at most 2 GA macOS images.
    runs-on: macos-26
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v6      # node24 (v4 = node20, removed from hosted runners 2026-09-23)
        with:
          lfs: true            # harmless if Vendor/idevice is not in LFS

      - uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: '26.6'   # StikDebug build_ipa.yml pins the same

      - name: Toolchain info
        run: xcodebuild -version

      - name: Fetch prebuilt idevice FFI (if not committed)
        run: |
          set -e
          mkdir -p Vendor/idevice
          if [ ! -s Vendor/idevice/libidevice_ffi.a ]; then
            BASE="https://raw.githubusercontent.com/StikDebug/StikDebug/${IDEVICE_REF}/StikDebug/idevice"
            curl -fL --retry 3 "$BASE/idevice.h"          -o Vendor/idevice/idevice.h
            curl -fL --retry 3 "$BASE/module.modulemap"   -o Vendor/idevice/module.modulemap
            curl -fL --retry 3 "$BASE/libidevice_ffi.a"   -o Vendor/idevice/libidevice_ffi.a
          fi
          ls -la Vendor/idevice
          test "$(stat -f%z Vendor/idevice/libidevice_ffi.a)" -eq "$IDEVICE_A_SIZE"
          head -c 8 Vendor/idevice/libidevice_ffi.a | grep -q '!<arch>'      # real archive, not an LFS pointer
          cat Vendor/idevice/module.modulemap
          grep -q '\[system\]' Vendor/idevice/module.modulemap
          lipo -info Vendor/idevice/libidevice_ffi.a
          # every FFI symbol the Swift sources use must exist in the header CI actually fetched
          for s in rp_pairing_file_read rp_pairing_file_free tunnel_create_rppairing adapter_free rsd_handshake_free \
                   rsd_service_available lockdownd_connect_rsd lockdownd_get_value image_mounter_connect_rsd \
                   image_mounter_copy_devices image_mounter_mount_personalized_with_callback_rsd image_mounter_free \
                   remote_server_connect_rsd remote_server_free location_simulation_new location_simulation_set \
                   location_simulation_clear location_simulation_free idevice_error_free idevice_data_free plist_free; do
            grep -q "\b$s(" Vendor/idevice/idevice.h || { echo "missing FFI symbol: $s"; exit 1; }
          done

      - name: Install XcodeGen
        run: brew install xcodegen

      - name: Generate Xcode project
        run: xcodegen generate

      # Mirror StikDebug exactly for the first green run: `clean archive`, Debug, -Onone.
      # Switch to -configuration Release only after a Debug IPA is proven to launch (neither reference
      # project builds Release in CI).
      - name: Archive (unsigned, device)
        run: |
          set -o pipefail
          xcodebuild clean archive -project MirageGo.xcodeproj -scheme MirageGo -configuration Debug \
            -archivePath build/MirageGo.xcarchive \
            -sdk iphoneos -destination 'generic/platform=iOS' \
            ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
            CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
            SWIFT_OPTIMIZATION_LEVEL="-Onone" IPHONEOS_DEPLOYMENT_TARGET=17.4 | tail -n 80

      - name: Package IPA
        run: |
          APP=build/MirageGo.xcarchive/Products/Applications/MirageGo.app
          test -d "$APP"
          rm -rf Payload && mkdir Payload && cp -R "$APP" Payload/
          zip -qr MirageGo.ipa Payload
          ls -la MirageGo.ipa

      - uses: actions/upload-artifact@v7      # node24 (v4 AND v5 are node20; v6 is also node24)
        with:
          name: MirageGo-ipa
          path: MirageGo.ipa
          if-no-files-found: error
```

Recipe basis: StikDebug `build_ipa.yml` (verified 2026-09-09): `runs-on: macos-latest`, `actions/checkout@v6`, `maxim-lobanov/setup-xcode@v1` with `xcode-version: '26.6'`, then `xcodebuild clean archive -project StikDebug.xcodeproj -scheme "StikDebug" -configuration Debug -archivePath build/StikDebug.xcarchive -sdk iphoneos -destination 'generic/platform=iOS' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO SWIFT_OPTIMIZATION_LEVEL="-Onone" IPHONEOS_DEPLOYMENT_TARGET=17.4`, then `cp -R build/StikDebug.xcarchive/Products/Applications/StikDebug.app .; mkdir -p Payload; cp -R StikDebug.app Payload/; zip -r StikDebug.ipa Payload`, uploaded with `actions/upload-artifact@v7` https://raw.githubusercontent.com/StikDebug/StikDebug/main/.github/workflows/build_ipa.yml . It is an **archive, Debug, -Onone** build, not `build`/Release, and the vendored `libidevice_ffi.a` is therefore only proven to link under Xcode 26.6 (StikDebug README: "Xcode 16+ (Xcode 26+ preferred for iOS 26+ support)" https://raw.githubusercontent.com/StikDebug/StikDebug/main/README.md ). Runner facts: macos-26 default Xcode 26.6 https://raw.githubusercontent.com/actions/runner-images/main/images/macos/macos-26-Readme.md ; macos-15 default 16.4 with 16.0-16.3 and 26.0.1-26.3 also installed https://raw.githubusercontent.com/actions/runner-images/main/images/macos/macos-15-arm64-Readme.md ; macOS 26 and 15 GA, 14 deprecated, "at maximum 2 GA images" https://github.com/actions/runner-images/blob/main/README.md . Action runtimes (raw `action.yml` checked 2026-09-09): checkout v4 `node20`, v5/v6 `node24`; upload-artifact v4/v5 `node20`, v6/v7 `node24`; GitHub removes Node 20 from hosted runners on 2026-09-23 https://github.blog/changelog/2025-09-19-deprecation-of-node-20-on-github-actions-runners/ . The raw-URL download of the 97 MB `.a` **works** (HEAD 2026-09-09: HTTP 200, Content-Length 97089368, `application/octet-stream`, body begins `!<arch>`; StikDebug has no root `.gitattributes`, so it is a plain blob, not an LFS pointer); fallback is option B or committing via Git LFS. The `.gitignore` already excludes `*.ipa`, `*.xcodeproj/`, `build/`, `pairing/`.

Alternative Windows-native builder: nab138/CrossCode (Swift 6.2 + Darwin SDK on Windows, sideloads via isideload) is alpha and its support for prebuilt static libs / binary targets is **(unverified)** https://raw.githubusercontent.com/nab138/CrossCode/main/README.md . GitHub Actions is the safer route.

---

## 5. Sideloadly on Windows, step by step

Sideloadly v0.60.0 is the current changelog entry https://sideloadly.io/changelog.html (the changelog carries no dates and no iOS-version statement; the "Aug 2025 / works through iOS 26.2" figures came from an X post that could not be fetched - **(unverified)**). The FAQ states "Sideloadly should support iOS 7 up to iOS 26+ (and future iOS versions)" https://sideloadly.io/faq.html . The Sideloadly-Download GitHub README is stale (still says v0.50.0 / "up to iOS 16 and future iOS versions") https://github.com/SideloadlyiOS/Sideloadly-Download/blob/main/README.md .

1. **Prerequisites (fixed requirement, not an experiment)**: uninstall the Microsoft Store iTunes/iCloud, install the **web** (x64) iTunes and iCloud from Apple, reboot, open iTunes once and tap Trust; then install Sideloadly 64-bit. The FAQ's fix for two device-connection errors is verbatim "uninstall the Microsoft Store version of iTunes and install the normal/web version" https://sideloadly.io/faq.html , and "no devices detected" threads resolve the same way https://iosgods.com/topic/192446-sideloadly-no-devices-detected-even-when-my-iphone-is-connected-to-pc/ . Apple still serves the web installer: `https://www.apple.com/itunes/download/win64` 301s to `secure-appldnld.apple.com/itunes12/047-76416-20260302-.../iTunes64Setup.exe` (2026-03-02 build; verified by HEAD 2026-09-09). The Apple Devices app (needed by the Mirage location-spoofer project) is not documented as a substitute; keep it only if Sideloadly still sees the phone, remove it if not.
2. Download `MirageGo.ipa` from the GitHub Actions artifact (unzip `MirageGo-ipa.zip`).
3. Plug the iPhone in by USB, tap **Trust This Computer**; open Sideloadly and pick the device.
4. Drag `MirageGo.ipa` in. Apple ID: use one that has been signed into an iDevice before ("A brand new Apple ID will not work") https://github.com/qnblackcat/uYouPlus/wiki/Sideloadly-(macOS-&-Windows) .
5. Advanced Options: Anisette = Remote (default) or Local; leave "Remove Extensions (PlugIns)" unchecked (the app has none). Do **not** change the bundle ID between installs, or you lose the app's data (pairing file, DDI cache).
6. Click **Start**; enter the Apple ID password, then the 2FA code when prompted (v0.60 handles 2FA without iTunes on Windows) https://sideloadly.io/changelog.html . App-specific passwords do not work with free IDs https://sideloadly.io/faq.html .
7. On the phone: Settings > General > VPN & Device Management > tap your Apple ID > **Trust** https://sideloadly.io/faq.html .
8. Settings > Privacy & Security > **Developer Mode** > on > Restart > Enable https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device .
9. Limits (FAQ verbatim): "A normal & free Apple Developer account only allows the app to function for 7 days", "limited to 3 sideloaded apps", "You may create up to 10 App IDs every 7 days" https://sideloadly.io/faq.html . LocalDevVPN is an App Store app and does not count.
10. **7-day re-sign**: every <= 7 days, plug in and re-sideload the same IPA with the same Apple ID over the existing install ("DO NOT delete the current app or you will lose all app's data") https://github.com/qnblackcat/uYouPlus/wiki/Sideloadly-(macOS-&-Windows) . Optional Wi-Fi auto-refresh: enable "Sync with this iDevice over Wi-Fi" in iTunes, tick auto-refresh in Sideloadly; the Sideloadly daemon on the PC does the refresh when it sees the phone on the LAN - it still needs the PC https://sideloadly.io/faq.html https://github.com/SideloadlyiOS/Sideloadly-Download/blob/main/README.md .
11. Truly PC-less refresh option: install **SideStore** (via iloader on Windows), give it a lockdown pairing file, and let it re-sign Mirage Go through LocalDevVPN weekly; costs one of the 3 slots (SideStore + Mirage Go = 2) https://docs.sidestore.io/docs/installation/install https://github.com/nab138/iloader https://docs.sidestore.io/docs/faq .
12. Common failures: "Guru Meditation" -> switch Anisette, reinstall web iTunes/iCloud, run as admin, disable AV/VPN https://wpreset.com/how-to-fix-install-failed-guru-meditation-in-sideloadly/ ; "ApplicationVerificationFailed" -> check date/time, trust profile https://iosgods.com/topic/188749-sideloadly-applicationverificationfailed/ ; device not detected -> reinstall web iTunes + iCloud, reboot https://github.com/SideloadlyiOS/Sideloadly-Download/blob/main/README.md .

---

## 6. User-facing setup (phone)

1. **Install LocalDevVPN** from the App Store (id 6755608044) https://apps.apple.com/us/app/localdevvpn/id6755608044 . Open it, tap Connect, accept "Allow VPN Configurations" with passcode/Face ID (one-time) https://docs.sidestore.io/docs/installation/prerequisites . Optionally enable "auto connect on launch" https://raw.githubusercontent.com/jkcoxson/LocalDevVPN/main/LocalDevVPN/ContentView.swift .
2. **Developer Mode** on (step 8 above).
3. **Make the pairing file on the PC** (USB, once; redo after an iOS update or reset, "This also occurs at random times" https://raw.githubusercontent.com/StikDebug/StikDebug-Guide/main/pairing_file.md ). Two routes:
   - **Route A (confirmed by StikDebug's own guide)**: `idevice_pair--windows-x86_64.exe` v1.1.0 (needs iTunes) https://api.github.com/repos/jkcoxson/idevice_pair/releases?per_page=3 https://raw.githubusercontent.com/jkcoxson/idevice_pair/master/README.md : choose **Remote pairing** (iOS 17.4+), Create, then "Save to file..." -> `pairingFile.plist`, or click an app to write it into its Documents over AFC (Mirage Go is not in its known-apps list, so use Save to file). Pairing is promptless with fixed PIN 000000 through the CoreDeviceProxy tunnel service https://raw.githubusercontent.com/jkcoxson/idevice_pair/master/src/backend/pairing.rs . iloader (nab138) also places "rppairing+lockdown pairing files automatically" for known apps https://raw.githubusercontent.com/nab138/iloader/main/README.md .
   - **Route B (already on this PC; derivation confirmed, device acceptance untested)**: `python -m pymobiledevice3 lockdown remotepairing --pair` writes `C:\Users\cenos\.pymobiledevice3\remote_00008140-001939063A81801C.plist` with exactly the keys `public_key`, `private_key`, `remote_unlock_host_key` (this file exists, 2026-09-09 07:14; keys re-checked with plistlib) https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/cli/lockdown.py . Source-confirmed mechanics: `RemotePairingProtocol.save_pair_record` (tunnel_service.py line 774-781) writes only those three keys; `self.identifier = generate_host_id()` (line 576) unless the record has a `host_identifier` key (line 1039-1041); that identifier is sent in the pair-setup `IDENTIFIER` TLV (line 930) and in pair-verify (line 1053) https://raw.githubusercontent.com/doronz88/pymobiledevice3/master/pymobiledevice3/remote/tunnel_service.py ; `generate_host_id()` = `str(uuid.uuid3(uuid.NAMESPACE_DNS, platform.node())).upper()` https://raw.githubusercontent.com/doronz88/pymobiledevice3/master/pymobiledevice3/pair_records.py . On the idevice side `RpPairingFile` requires `public_key`/`private_key`/`identifier` (`alt_irk` optional, missing only logs a warning) https://raw.githubusercontent.com/jkcoxson/idevice/master/idevice/src/remote_pairing/rp_pairing_file.rs , and pair-verify signs the same buffer (`x_public_key + identifier + device_public_key`, `remote_pairing/mod.rs` line 621-648) before sending the Identifier + Signature TLVs https://raw.githubusercontent.com/jkcoxson/idevice/master/idevice/src/remote_pairing/mod.rs . On this PC `platform.node()` = `DESKTOP-KQ41C8Q` and the derived identifier is `5E71DA58-06E1-329F-95A2-28CFB5CCAB36` (computed 2026-09-09). **Caveat**: the hostname must be the one in effect when `--pair` ran; if the PC was renamed since, re-pair. Conversion:
     ```
     python -c "import plistlib,uuid;d=plistlib.load(open(r'C:/Users/cenos/.pymobiledevice3/remote_00008140-001939063A81801C.plist','rb'));plistlib.dump({'public_key':d['public_key'],'private_key':d['private_key'],'identifier':str(uuid.uuid3(uuid.NAMESPACE_DNS,'DESKTOP-KQ41C8Q')).upper()},open('pairingFile.plist','wb'))"
     ```
     The converter is correct as written; the only untested step is the device's pair-verify at runtime (one experiment). If it fails, use Route A. Remember the -9 caveat (section 3.2 #8): a rejected identifier surfaces as a pair-setup/PIN error or timeout, not as -9.
   - Fallback path file: the lockdown record `C:\Users\cenos\.pymobiledevice3\00008140-001939063A81801C.plist` (or `C:\ProgramData\Apple\Lockdown\<UDID>.plist`) for section 2.3 https://osxdaily.com/2016/01/21/ios-lockdown-folder-location-reset-lockdown-mac-windows/ .
4. **Transfer** `pairingFile.plist` to the phone: iTunes/Apple Devices File Sharing into Mirage Go (the app has `UIFileSharingEnabled`), or AirDrop-less options such as `pymobiledevice3 apps afc`/iCloud Drive, then in Mirage Go tap "Import pairing file" (Files picker) or just launch (auto-adopts `Documents/pairingFile.plist`).
5. **First run** (on **Wi-Fi with internet**, LocalDevVPN connected): Mirage Go downloads the three DDI files (~16 MB) from doronz88/DeveloperDiskImage, opens the tunnel, mounts the DDI (TSS call to Apple), then enables the Start button. Grant Local Network and Location "Always" prompts. If the mount fails once, force-close and reopen (SideStore's documented workaround) https://docs.sidestore.io/docs/advanced/jit .
6. **Every reboot**: reopen LocalDevVPN (Connect) and Mirage Go on Wi-Fi so the DDI gets re-mounted https://docs.sidestore.io/docs/advanced/jit .
7. **Cellular / Airplane rule** (section 2.6): connect the VPN on Wi-Fi or in Airplane Mode; start the spoof. Leaving Wi-Fi afterwards is **(unverified)** - Locus issue #1 reports the location snapping back on the Wi-Fi -> cellular switch https://github.com/ChrisMack32/Locus/issues/1 ; test it (section 7 #6). Cellular-only: Airplane Mode on -> VPN Connect -> Start -> turn cellular back on (Airplane Mode stays on) https://docs.sidestore.io/docs/advanced/jit .
8. **Stop** returns the real location (`stopLocationSimulation`); killing the app also ends the spoof because the DTX connection dies.

---

## 7. Risks and open questions (with a test on the user's phone)

| # | Risk / question | Evidence state | How to test on this phone |
|---|---|---|---|
| 1 | The pymobiledevice3 remote record + added `identifier` may be rejected at pair-verify. | Mechanically consistent on both sides (section 6 Route B, source-confirmed); needs one runtime test. Hostname-at-pairing-time caveat. | Run the conversion, then on the PC (USB unplugged, phone on same Wi-Fi 172.20.10.x) try `idevice_pair` "Validate" on the file; or try it in Mirage Go with a real `pin_callback` and full `IdeviceFfiError.message` logging. **Do not look for -9**: -9 means the file failed to parse; a rejected identifier fails pair-verify and idevice falls back to pair-setup with PIN "000000", so the symptom is a pair-setup/PIN error or timeout after a successful read (https://raw.githubusercontent.com/jkcoxson/idevice/master/idevice/src/remote_pairing/mod.rs , https://raw.githubusercontent.com/jkcoxson/idevice/master/ffi/src/tunnel_provider.rs). If it fails, generate with `idevice_pair` Remote pairing and compare the two plists' key names. |
| 2 | RPPairing over the loopback (`10.7.0.1:49152`) on iOS 18.7.8 specifically. | StikDebug says 17.4-18.x stable; no 18.7.8 report. | **De-risk before writing any code**: sideload **StikDebug-3.1.10.ipa** (2026-08-27, current release; 3.1.9 of 2026-08-01 only "Renamed `rp_pairing_file.plist` back to `pairingFile.plist`", so expect the file name `pairingFile.plist`) https://github.com/StikDebug/StikDebug/releases with Sideloadly, install LocalDevVPN, place the pairing file via `idevice_pair` (StikDebug is a known app), open the Location Simulator tab. If StikDebug spoofs on this phone, every layer Mirage Go needs is proven on this exact device. Delete StikDebug afterward to free a slot. |
| 3 | Older lockdown/CoreDeviceProxy path may or may not work on 18.7.8 over loopback. | Worked in original StikJIT up to 18.7.9; dropped by current apps after 26.4 broke it. | Build Mirage Go with a hidden "legacy transport" toggle using the lockdown record at `10.7.0.1:62078`; log `IdeviceFfiError` codes. Keep it only as a fallback. |
| 4 | Port 49152 drift. | Locus PR #2 asserts drift but presents no device evidence https://github.com/ChrisMack32/Locus/pull/2 ; this phone advertised 49152 in `pymobiledevice3 remote browse`; StikDebug hard-codes 49152 in `JITEnableContext.swift` (`in_port_t(49152).bigEndian`) and `TunnelManager.swift` (`"\(targetIPAddress):49152"`); StikDebug PR #355 (merged) changed the location path from `htons(LOCKDOWN_PORT)` to `htons(49152)` - i.e. 49152 is what works and 62078 must **not** be used on the RPPairing path https://github.com/StikDebug/StikDebug/pull/355/files . | Default to 49152; use `NWBrowser(for: .bonjour(type: "_remotepairing._tcp", domain: nil))` only as a fallback lookup (needs `NSBonjourServices` + `NSLocalNetworkUsageDescription`). |
| 5 | First DDI mount needs internet (TSS) and must be redone after each reboot; possible `MissingManifestError`-style failures. | idevice mounter source; pymobiledevice3 issue #1238 (iOS 18.0.1, iPhone 16 Pro Max) https://github.com/doronz88/pymobiledevice3/issues/1238 . | Prove the image on the PC first: `python -m pymobiledevice3 mounter auto-mount` then `python -m pymobiledevice3 developer dvt simulate-location set -- 37.33 -122.03` over USB; if that works, the same Image.dmg/trustcache/manifest bundled or downloaded by Mirage Go will personalize on-device. Then reboot the phone and confirm Mirage Go re-mounts (`image_mounter_copy_devices` count 0 -> 1). |
| 6 | Wi-Fi / Airplane rule root cause unknown; may bite when the phone is cellular-only. **Leaving Wi-Fi after starting is unverified** (Locus issue #1: reverts on Wi-Fi -> cellular, iOS 27 b4, open, no reply; Vanish shipped cellular fixes in v2.2.0/v3.2.0). | Rule documented by SideStore/StikDebug/Locus; cause not. https://github.com/ChrisMack32/Locus/issues/1 https://github.com/bhavyakhunt/vanish-releases/releases | Test matrix: (a) Wi-Fi on: connect VPN, spoof; (b) Airplane on: connect VPN, spoof; (c) **start on Wi-Fi, then turn Wi-Fi off and watch whether Maps snaps back** (re-send/rebuild on `NWPathMonitor` change); (d) cellular only from cold. Record which fail with reset/timeout errors. |
| 7 | Background survival (lock screen, other apps, hours). | StikDebug/Locus patterns; no public source shows a DVT session surviving hours on the lock screen; every shipping app has drop notifications (section 2.4). | Start spoof, lock the phone 10 min, open Find My/Maps on another device or check Maps on the phone; then 1 h; then overnight. Verify the health loop still fires (log timestamps in app) and that the drop notification arrives when it does not. |
| 8 | Sideloadly device detection on Windows. | **Resolved as a prerequisite**: web iTunes + iCloud are mandatory per the FAQ; Store iTunes / Apple-Devices-only setups are the usual cause of "no devices detected" https://sideloadly.io/faq.html https://iosgods.com/topic/192446-sideloadly-no-devices-detected-even-when-my-iphone-is-connected-to-pc/ . | Install web iTunes (`https://www.apple.com/itunes/download/win64`) + web iCloud first (section 5 step 1); only then try Sideloadly. |
| 9 | Free-ID limits: 7-day expiry, 3 apps, 10 App IDs/week. | Sideloadly FAQ. | Count installed sideloaded apps before installing; plan re-sign day. Optional: SideStore for on-device refresh. |
| 10 | Whether `hostname` passed to `tunnel_create_rppairing` must match the pairing-time host label. | **Confirmed not required**: StikDebug passes `"StikDebugLocation"` (`IdeviceFFIBridge.swift` line ~794) with a file made by idevice_pair/iloader, and idevice's pair-verify sends only the identifier + Ed25519 signature, never a hostname (`remote_pairing/mod.rs` line 621-648) https://raw.githubusercontent.com/StikDebug/StikDebug/main/StikDebug/Device/IdeviceFFIBridge.swift https://raw.githubusercontent.com/jkcoxson/idevice/master/idevice/src/remote_pairing/mod.rs . | None needed. |
| 11 | Exact contents of `idevice-xcframework-v0.1.66.zip`; raw download of the 97 MB `libidevice_ffi.a` in CI. | Raw download **resolved** (HTTP 200, Content-Length 97089368, real `!<arch>` blob, 2026-09-09). Zip contents still unverified (GitHub API rate-limited). | CI keeps the size assert / `lipo -info` / per-symbol `grep` steps; if the download ever fails, commit the trio via Git LFS. |
| 12 | Apps with their own anti-spoof (Pokemon GO etc.) may reject DVT-simulated GPS. | Locus README warning https://github.com/ChrisMack32/Locus . | Out of scope; Find My / Life360 / Maps are the targets and are what StikDebug/Vanish users report working. |
| 13 | Handles are not thread-safe; the adapter and streams must be used from one thread. | idevice.h warning. | Run every FFI call on `ffiQueue`; never touch handles from SwiftUI. |
| 14 | RSD inventory is filled once at handshake, so a tunnel opened before the DDI mount will not see `dtservicehub`. | Inferred from `RsdHandshake::new` / `recv_root` in `idevice/src/services/rsd.rs` (no refresh method); not a docs quote. StikDebug's location path opens its own tunnel after the mount. | After a mount, close and reopen the tunnel before `remote_server_connect_rsd`; confirm `rsd_service_available(handshake, "com.apple.instruments.dtservicehub", &b)` returns true. |
| 15 | Pairing record expiry after iOS update/reset or "at random times". | StikDebug guide. | Keep `idevice_pair` on the PC; the app should surface -9 (unreadable file) **and** post-read pair failures (rejected record) with a "re-import pairing file" hint. |

### Not confirmable from public sources
- Vanish Mobile's transport (RPPairing vs lockdown path) and its background strategy. The tutorial's "There is no separate download, and nothing to find in the App Store" sentence refers to **Vanish Mobile itself** (installed from the desktop app), not to LocalDevVPN, which the same page calls "a loopback tunnel"; it also says "Vanish Mobile asks to add a VPN configuration", i.e. the helper is presented as part of Vanish's own install flow. How that squares with NetworkExtension being unavailable to free-tier/sideloaded apps is not explained; Mirage Go keeps the App Store LocalDevVPN route proven by StikDebug/SideStore https://getvanish.app/tutorial (JS page; read via a browser or r.jina.ai).
- Why iOS 18.4 beta 1 (22E5200) is excluded by StikJIT/SideStore https://github.com/StikJIT/StikJIT https://docs.sidestore.io/docs/advanced/jit .
- ~~Whether `image_mounter_free` is the exact name~~ - resolved: `void image_mounter_free(struct ImageMounterHandle *handle)` at vendored `idevice.h` line 3821.
- Whether the RPPairing record survives an iPhone reboot on iOS 18: not stated either way for USB RPPairing. idevice_pair's "The remote pairing is only kept in memory, so pair again after a restart" sits only under the Wi-Fi onboarding section ("Requires iOS 27 or later"); the USB "Remote pairing needs iOS 17.4 or later" section has no such caveat, and StikDebug/SideStore users keep files for months (they "expire" only on update/reset or "at random times") https://raw.githubusercontent.com/jkcoxson/idevice_pair/master/README.md https://raw.githubusercontent.com/StikDebug/StikDebug-Guide/main/pairing_file.md . Expected to persist; test once after a reboot.
- Sideloadly's release date for v0.60.0 and the "works through iOS 26.2" statement (X post, not retrievable).

---

## Recommended order of work

1. Install web iTunes + iCloud (section 5 step 1), then de-risk with StikDebug **3.1.10** + LocalDevVPN + `idevice_pair` on the real phone (risk #2). Keep the pairing file it produces.
2. Replace `project.yml`/workflow with section 4 (`SWIFT_VERSION: "5.0"`, macos-26 + Xcode 26.6, checkout@v6 / upload-artifact@v7, Debug `clean archive`), vendor the idevice trio pinned to a StikDebug commit SHA, push, get a green unsigned IPA.
3. Implement `IdeviceBridge` + `SpoofEngine` with a single hard-coded coordinate; sideload; verify Maps moves.
4. Add DDI download/mount, keep-alive, map UI, VPN deep link, error mapping, Settings (device IP/port override, legacy transport toggle).
5. Test matrix from section 7 (#5, #6, #7), then the 7-day re-sign routine or SideStore.
