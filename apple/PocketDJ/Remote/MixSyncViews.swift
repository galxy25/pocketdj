import SwiftUI

// ============================================================================
// MARK: - Multiplayer Mix UI pieces (MixView + RemoteView mount these)
// ============================================================================

/// The slim banner atop the Mix tab while mixing together: who's in, which deck is yours, and
/// why the Auto-DJ is off.
struct MixTogetherBanner: View {
    let sync: MixSync
    @Environment(MixEngine.self) private var engine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            info
            if !sync.systemHeld.isEmpty { rejoinRow }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1))
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "person.2.wave.2.fill").foregroundStyle(Theme.accent)
                Text("Mixing together").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.fg)
                Spacer(minLength: 6)
                Text(yourDeck).font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("mix-together-your-deck")
            }
            Text(sync.participantNames.joined(separator: " · "))
                .font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
            if let why = engine.autoDJBlockedReason {
                Text(why).font(.caption2).foregroundStyle(Theme.fgDim)
            }
            if let msg = sync.statusMessage {
                Label(msg, systemImage: "info.circle").font(.caption2).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mix-together-banner")
    }

    /// The system paused decks HERE (a call, Siri, unplugged headphones) while the mix plays on:
    /// one tap brings every one of them back — another DJ's deck has a read-only ▶.
    private var rejoinRow: some View {
        HStack(spacing: 8) {
            Label("Paused on this device", systemImage: "pause.circle")
                .font(.caption).foregroundStyle(.orange)
            Spacer(minLength: 6)
            Button("Rejoin") { sync.rejoin() }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent).controlSize(.small)
                .tint(Theme.accent)
                .accessibilityIdentifier("mix-together-rejoin")
        }
    }

    private var yourDeck: String {
        let mine = sync.myDecks
        return mine.isEmpty ? "No deck — claim one" : "Your deck: " + mine.map(\.rawValue).joined(separator: " + ")
    }
}

/// A deck header's owner chip + Claim / Release, and the "not available on this device" note.
struct MixDeckOwnerBadge: View {
    let sync: MixSync
    let deck: MixEngine.Deck

    var body: some View {
        if sync.isActive {
            HStack(spacing: 6) {
                if let label = sync.ownerLabel(deck) {
                    RemoteBadge(text: label, tint: sync.canControl(deck) ? Theme.accent : Theme.fgDim)
                        .accessibilityIdentifier("deck-\(deck.rawValue)-owner")
                }
                if sync.owner(of: deck) == nil {
                    Button("Claim") { sync.claim(deck) }
                        .font(.caption2.weight(.semibold)).buttonStyle(.bordered).controlSize(.mini)
                        .accessibilityIdentifier("deck-\(deck.rawValue)-claim")
                } else if sync.canControl(deck) {
                    Button("Release") { sync.release(deck) }
                        .font(.caption2).buttonStyle(.borderless).controlSize(.mini)
                        .accessibilityIdentifier("deck-\(deck.rawValue)-release")
                }
            }
        }
    }
}

/// "Not available on this device" under a deck whose session song can't be mixed here.
struct MixDeckUnavailableNote: View {
    let sync: MixSync
    let deck: MixEngine.Deck

    var body: some View {
        if sync.isActive {
            if let title = sync.unavailable[deck] {
                Label("“\(title)” isn’t available on this device — this deck stays silent here.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .accessibilityIdentifier("deck-\(deck.rawValue)-unavailable")
            } else {
                let others = sync.unavailableDevices(deck)
                if !others.isEmpty {
                    Label("Silent on \(others.joined(separator: ", "))", systemImage: "speaker.slash")
                        .font(.caption2).foregroundStyle(Theme.fgDim)
                }
            }
        }
    }
}

extension View {
    /// A deck control another participant owns: visible, greyed, not interactive.
    func mixReadOnly(_ readOnly: Bool) -> some View {
        disabled(readOnly).opacity(readOnly ? 0.55 : 1)
    }
}
