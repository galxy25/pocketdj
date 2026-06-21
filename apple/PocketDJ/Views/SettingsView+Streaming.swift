import SwiftUI

/// The "Streaming accounts" Settings section — one account row per provider
/// (Spotify, …), shown BESIDE the URL catalog "Data sources". Adding a streaming
/// source is an account link: tap Log in → hand off to the provider's OAuth →
/// connect our app to that account. Kept in its own file so it composes cleanly
/// with the parallel native-playback / YouTube efforts.
extension SettingsView {
    var streamingSection: some View {
        Section {
            ForEach(streaming.providers, id: \(any StreamingProvider).kind) { provider in
                StreamingAccountRow(provider: provider)
            }
        } header: {
            Text("Streaming accounts")
        } footer: {
            Text("Link a streaming service to play directly from your subscription, beside your own catalog sources. Spotify requires the Spotify app installed and a Premium account for on-demand playback.")
        }
    }
}

/// A single provider's account row: status line + Log in / Log out button. The
/// row reads provider state reactively (providers are `@Observable`).
private struct StreamingAccountRow: View {
    let provider: any StreamingProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(provider.kind.displayName, systemImage: provider.kind.symbol)
                Spacer()
                trailing
            }
            if let detail = statusDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("streaming-row-\(provider.kind.rawValue)")
    }

    @ViewBuilder private var trailing: some View {
        switch provider.state {
        case .unavailable:
            Text("Not available")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .authorizing:
            ProgressView()
        case .loggedOut, .failed:
            Button("Log in") { provider.login() }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("streaming-login-\(provider.kind.rawValue)")
        case .linked, .connected:
            Button("Log out", role: .destructive) { provider.logout() }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("streaming-logout-\(provider.kind.rawValue)")
        }
    }

    private var statusDetail: String? {
        switch provider.state {
        case .unavailable(let reason): return reason
        case .loggedOut: return "Not linked."
        case .authorizing: return "Opening \(provider.kind.displayName)…"
        case .linked(let acct): return acct.map { "Linked: \($0)" } ?? "Linked."
        case .connected(let acct): return acct.map { "Connected: \($0)" } ?? "Connected — ready to play."
        case .failed(let message): return message
        }
    }
}
