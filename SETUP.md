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
4. **Pairing file** into the app. Easiest: phone on the cable, PC Mirage → Wi-Fi panel → **Send pairing file to
   Mirage Go**. Or from a terminal in `mirage-go/`:
   ```bash
   python -m pymobiledevice3 apps push --documents net.summitclient.mirage-go pairing/pairingFile.plist pairingFile.plist
   ```
   Mirage Go picks it up by itself within a couple of seconds, even while it is open (Settings tab → "Pairing file:
   remote pairing"). If the phone ever stops accepting it, re-make it on the PC:
   `python -m pymobiledevice3 lockdown remotepairing --pair` then rerun the converter in RESEARCH.md §6 Route B.
5. **Pause the PC spoof** while testing Mirage Go (Kill switch in PC Mirage, or unplug). Two spoofers on one phone
   fight over the same service.

## The first Connect (do it on Wi-Fi, with internet)

Press **Connect** on the Home screen. In order the phone will:

1. Ask for **Location** → choose **Allow While Using**, then **Always** when offered (this keeps the spoof alive when
   the phone is locked). The app waits for this answer before doing anything else.
2. Switch to **LocalDev VPN** if it is not connected yet; tap Connect there. It jumps back to Mirage Go by itself.
3. Ask for **Local Network** → **Allow**.
4. Ask for **Notifications** → Allow (only used to tell you if the spoof dropped).
5. Download the developer image (16 MB) and get it signed by Apple (needs internet), then mount it. 30 to 90 s the
   first time; the steps card shows progress. After that a Connect takes a few seconds.

The pill on the map turns green **SPOOFING** with a session clock, and the map flies down from the globe to the place.
If something fails, the red card says what to do; Settings → Log → Copy log has the details.

## Every day

- Open **Mirage Go → Connect** (it opens LocalDev VPN for you when needed).
- The first Connect after a reboot needs internet again (Apple re-signs the developer image). Wi-Fi is easiest.
- Cellular only: Airplane Mode on → LocalDev VPN Connect → Mirage Go Connect → cellular back on, Airplane Mode stays on.
- Home: tap a Quick place, or tap the map to drop a pin → Go here (it names the spot when online). "All places" has
  search, typed coordinates and favourites. Realistic travel glides there, Teleport jumps. The red **Disconnect**
  button is the kill switch: instant real location.
- If the link drops (VPN hiccup while locked) the pill turns amber **RECONNECTING** and the app keeps trying for
  15 minutes on its own. If LocalDev VPN itself went off, just open Mirage Go: it re-opens the VPN and resumes.
- Keep the app installed and the VPN connected; force-quitting Mirage Go ends the spoof.

## Every 7 days (free Apple ID)

Plug in, open Sideloadly, drag the same IPA, Start. Do not delete the app first (it keeps the pairing file).

## Rebuilding after code changes

Push to `main` → GitHub Actions builds `MirageGo.ipa` in about a minute → download the artifact → Sideloadly.
