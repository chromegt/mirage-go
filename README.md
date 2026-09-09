# Mirage Go

Computer-free iPhone location simulator. A sideloaded SwiftUI app that talks to the phone's **own** developer
service through a loopback VPN (LocalDev VPN), using a pairing file made once on a PC, and drives Apple's
`LocationSimulation` service, the same mechanism Mirage uses from the PC over USB, and the same trick Vanish,
StikDebug and Locus use.

- No jailbreak. Nothing leaves the phone.
- Places, Realistic travel (glide at walk/jog/bike/drive speed), GPS jitter, Kill switch.
- Guided setup checklist, background keep-alive, auto-rebuild when the link hiccups, drop notification.

Built without a Mac: GitHub Actions (macOS runner, XcodeGen, unsigned archive) produces `MirageGo.ipa`; install it
with Sideloadly on Windows. See **SETUP.md** for the user steps and **RESEARCH.md** for the architecture, sources
and open questions.

## Layout

```
project.yml                  XcodeGen spec (iOS 17.4+, background modes, URL scheme, doc types)
.github/workflows/build.yml  macOS runner: fetch prebuilt idevice FFI, xcodegen, archive, upload MirageGo.ipa
Vendor/idevice/              idevice.h + module.modulemap (libidevice_ffi.a is fetched in CI, pinned commit)
MirageGo/
  FFI.swift                  DeviceTunnel / LocationChannel / DDIMounter over the C FFI (all on ffiQueue)
  SpoofEngine.swift          connect steps, keep-alive + rebuild, realistic travel, jitter
  Keepers.swift              silent audio + background location so iOS keeps the socket alive
  Support.swift              pairing file store, DDI download, LocalDev VPN helper, places, settings, network monitor
  ContentView.swift          Home / Places / Settings / Setup, monochrome design
  Assets.xcassets            app icon, logo, launch colour
pairing/                     (gitignored) pairingFile.plist for this phone
```

## License

MIT. `Vendor/idevice` is jkcoxson/idevice (MIT).
