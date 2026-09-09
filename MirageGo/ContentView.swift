import SwiftUI

/// Placeholder shell used to prove the GitHub -> IPA -> Sideloadly pipeline. Replaced by the real UI.
struct ContentView: View {
    @State private var connected = false

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.05).ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                Image(systemName: "globe")
                    .font(.system(size: 64, weight: .thin))
                    .foregroundStyle(.white)
                Text("Mirage Go")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                HStack(spacing: 8) {
                    Image(systemName: connected ? "lock.fill" : "lock.open.fill")
                    Text(connected ? "Protected" : "Unprotected")
                }
                .font(.headline)
                .foregroundStyle(connected ? Color(red: 0.13, green: 0.77, blue: 0.51) : Color(red: 1, green: 0.30, blue: 0.37))
                Text("Pipeline test build. The real app is on its way.")
                    .font(.footnote)
                    .foregroundStyle(.gray)
                Spacer()
                Button(action: { connected.toggle() }) {
                    Text(connected ? "Disconnect" : "Connect")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(connected ? Color(white: 0.16) : Color.white)
                        .foregroundStyle(connected ? Color.white : Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
    }
}
