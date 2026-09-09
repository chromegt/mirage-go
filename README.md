# Mirage Go

Computer-free iPhone location simulator: the sideloaded app connects to the phone's own developer services
through a loopback VPN (StosVPN) using a pairing file made once on a PC, then drives Apple's
LocationSimulation service, exactly like Mirage does from the PC.

Build: GitHub Actions (macOS runner) produces an unsigned `.ipa` artifact. Install with Sideloadly on Windows.

Status: in development. See RESEARCH.md for the architecture and plan.
