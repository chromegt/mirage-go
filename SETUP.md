# Mirage Go: setup card

What it is: an app on the iPhone that fakes the phone's location for every app (Find My, Life360, Maps) with no PC
nearby. Same trick as Vanish: a loopback VPN lets the app talk to the phone's own developer service.

## One-time (needs the PC + cable)

1. **LocalDev VPN** on the iPhone (App Store, free). Open it once, tap Connect, allow the VPN configuration.
2. **Developer Mode** on the iPhone: Settings → Privacy & Security → Developer Mode → on (already done).
3. **Install Mirage Go** with Sideloadly:
   - Download the newest `MirageGo-ipa` artifact from https://github.com/chromegt/mirage-go/actions (log in, open the
     latest green run, Artifacts at the bottom). Unzip it → `MirageGo.ipa`.
   - Sideloadly: drag the IPA in, Apple ID `cash_dillon@icloud.com`, Start, password, 2-factor code.
   - iPhone: Settings → General → VPN & Device Management → your Apple ID → Trust.
4. **Pairing file** into the app (from the PC, phone plugged in, run in `mirage-go/`):
   ```bash
   python -m pymobiledevice3 apps push --documents net.summitclient.mirage-go pairing/pairingFile.plist pairingFile.plist
   ```
   Mirage Go adopts it on the next launch (Settings tab → "Pairing file: remote pairing").
   The file was made from Mirage's remote pairing on the PC; if the phone ever stops accepting it, re-make it:
   `python -m pymobiledevice3 lockdown remotepairing --pair` then rerun the converter in RESEARCH.md §6 Route B.

## Every day

- Open **LocalDev VPN → Connect** (or let Mirage Go open it), open **Mirage Go → Connect**.
- First Connect of the day after a reboot needs internet (Apple signs the developer image). Wi-Fi is easiest.
- Cellular only: Airplane Mode on → LocalDev VPN Connect → Mirage Go Connect → cellular back on, Airplane Mode stays on.
- Places tab: tap a place; Realistic travel glides there, Teleport jumps. Kill switch = instant real location.
- Keep the app installed and the VPN connected; force-quitting Mirage Go ends the spoof.

## Every 7 days (free Apple ID)

Plug in, open Sideloadly, drag the same IPA, Start. Do not delete the app first (it keeps the pairing file).

## Rebuilding after code changes

Push to `main` → GitHub Actions builds `MirageGo.ipa` in about a minute → download the artifact → Sideloadly.
