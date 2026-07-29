import SwiftUI

/// The ZERO-TO-HERO first-run flow's UI — three staged choices presented as a modal
/// gate over RootView (fullScreenCover on iOS/visionOS, a non-dismissable sheet on
/// macOS). `OnboardingStore` owns stage + completion; this file owns the cards.
///
/// Stage 1 — profile: on-device vs link-with-iCloud. The iCloud path PROBES the cloud
/// first (existing profile → "Welcome back" + pull-forced restore; nothing → name
/// entry; unreachable → continue safely with sync enabled but nothing written). The
/// LWW-clobber hazards here are the R1–R5 review notes — every path either restores
/// BEFORE any store writes, or writes nothing identity-shaped at all.
/// Stage 2 — Apple Music sign-in (the Settings ▸ Streaming login action, invited).
/// Stage 3 — global sources with user-visible names: Vinyl / Digital / Streaming.
struct OnboardingView: View {
    @Environment(OnboardingStore.self) private var onboarding
    @Environment(SettingsStore.self) private var settings
    @Environment(CloudSyncService.self) private var cloudSync
    @Environment(ProfileStore.self) private var profile
    @Environment(StreamingStore.self) private var streaming

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                Group {
                    switch onboarding.stage {
                    case .profile:    OnboardingProfileStage()
                    case .appleMusic: OnboardingAppleMusicStage()
                    case .sources:    OnboardingSourcesStage()
                    }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .interactiveDismissDisabled()
        .accessibilityIdentifier("onboarding-root")
    }

    private var header: some View {
        VStack(spacing: 10) {
            Text("PocketDJ")
                .font(.largeTitle.weight(.bold))
            Text(stageTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.accent)
            HStack(spacing: 8) {
                ForEach(OnboardingStore.Stage.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s.rawValue <= onboarding.stage.rawValue ? Theme.accent : Theme.border)
                        .frame(width: 8, height: 8)
                }
            }
            .accessibilityIdentifier("onboarding-progress")
        }
        .padding(.top, 40)
        .padding(.bottom, 20)
    }

    private var stageTitle: String {
        switch onboarding.stage {
        case .profile:    return "Your profile"
        case .appleMusic: return "Stream with Apple Music"
        case .sources:    return "Import your music"
        }
    }
}

// MARK: - Shared bits

/// The standard bottom row: optional Back + a primary Continue. Continue's label and
/// enablement come from the stage; Back is hidden on the first stage.
private struct OnboardingNavRow: View {
    @Environment(OnboardingStore.self) private var onboarding
    var continueLabel: String = "Continue"
    var continueEnabled: Bool = true
    var onContinue: () -> Void

    var body: some View {
        HStack {
            if onboarding.stage != .profile {
                Button("Back") { onboarding.back() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("onboarding-back")
            }
            Spacer()
            Button(continueLabel) { onContinue() }
                .buttonStyle(.borderedProminent)
                .disabled(!continueEnabled)
                .accessibilityIdentifier("onboarding-continue")
        }
        .padding(.top, 8)
    }
}

private struct OnboardingCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
    }
}

// MARK: - Stage 1: profile

private struct OnboardingProfileStage: View {
    @Environment(OnboardingStore.self) private var onboarding
    @Environment(SettingsStore.self) private var settings
    @Environment(CloudSyncService.self) private var cloudSync
    @Environment(ProfileStore.self) private var profile

    /// The stage's internal machine — the choice, then the iCloud probe's outcome.
    private enum Phase: Equatable {
        case choosing
        case probing
        case cloudFresh                 // account up, no profile → name + continue
        case cloudFound(name: String)   // welcome back → restore / start fresh
        case restoring
        case restoreFailed
        case cloudUnreachable           // .unknown / .noAccount → explain + continue
        case onDevice                   // sync off → name + continue
    }
    @State private var phase: Phase = .choosing
    @State private var name = ""
    @State private var confirmStartFresh = false

    var body: some View {
        VStack(spacing: 14) {
            switch phase {
            case .choosing:
                OnboardingCard {
                    Label("Link with iCloud", systemImage: "icloud")
                        .font(.headline)
                    Text("Your profile, playlists, and sessions follow your Apple ID — reinstalls and new devices pick up right where you left off.")
                        .font(.callout).foregroundStyle(Theme.fgDim)
                    Button("Link with iCloud") { Task { await probe() } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("onboarding-choice-icloud")
                }
                OnboardingCard {
                    Label("Just this device", systemImage: "iphone")
                        .font(.headline)
                    Text("Keep everything on this device only. You can link iCloud later in Settings ▸ Profile.")
                        .font(.callout).foregroundStyle(Theme.fgDim)
                    Button("Use on this device") {
                        settings.cloudSyncEnabled = false
                        settings.persist()
                        phase = .onDevice
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("onboarding-choice-device")
                }

            case .probing:
                OnboardingCard {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Checking iCloud…").foregroundStyle(Theme.fgDim)
                    }
                }

            case .cloudFound(let cloudName):
                OnboardingCard {
                    Label(cloudName.isEmpty ? "Welcome back" : "Welcome back, \(cloudName)",
                          systemImage: "person.crop.circle.badge.checkmark")
                        .font(.headline)
                    Text("A PocketDJ profile already lives in your iCloud. Restore it to bring back your playlists, pockets, and sessions.")
                        .font(.callout).foregroundStyle(Theme.fgDim)
                    Button("Restore my stuff") { Task { await restore() } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("onboarding-restore")
                    Button("Start fresh instead", role: .destructive) { confirmStartFresh = true }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("onboarding-startfresh")
                }
                .confirmationDialog(
                    "Starting fresh will replace the iCloud profile for ALL your devices the next time this device syncs. Your other devices' local data stays until they pull.",
                    isPresented: $confirmStartFresh, titleVisibility: .visible) {
                    Button("Start fresh", role: .destructive) { phase = .cloudFresh }
                    Button("Cancel", role: .cancel) {}
                }

            case .restoring:
                OnboardingCard {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Restoring from iCloud…").foregroundStyle(Theme.fgDim)
                    }
                    Text("Bringing back your profile, collections, and sessions.")
                        .font(.caption).foregroundStyle(Theme.fgDim)
                }

            case .restoreFailed:
                OnboardingCard {
                    Label("Restore didn't finish", systemImage: "exclamationmark.icloud")
                        .font(.headline)
                    Text("iCloud couldn't be reached. Try again — an incomplete restore never counts as done.")
                        .font(.callout).foregroundStyle(Theme.fgDim)
                    Button("Try again") { Task { await restore() } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("onboarding-restore")
                    Button("Back") { phase = .choosing }
                        .buttonStyle(.borderless)
                }

            case .cloudFresh, .onDevice:
                OnboardingCard {
                    Label("Your PocketDJ name", systemImage: "music.mic")
                        .font(.headline)
                    Text("Shown on your performance items and the Jukebox Hero DJ line. Optional — set or change it anytime in Settings ▸ Profile.")
                        .font(.callout).foregroundStyle(Theme.fgDim)
                    TextField("DJ name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("onboarding-name")
                }
                OnboardingNavRow {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { profile.setName(trimmed) }
                    onboarding.advance()
                }

            case .cloudUnreachable:
                OnboardingCard {
                    Label("iCloud isn't reachable right now", systemImage: "icloud.slash")
                        .font(.headline)
                    Text("Continuing without it — sync stays on and will catch up when iCloud is available. Manage this in Settings ▸ Profile.")
                        .font(.callout).foregroundStyle(Theme.fgDim)
                }
                OnboardingNavRow { onboarding.advance() }
            }
        }
    }

    private func probe() async {
        phase = .probing
        switch await cloudSync.probeCloudProfile() {
        case .existing(let n):     phase = .cloudFound(name: n)
        case .fresh:               phase = .cloudFresh
        case .noAccount, .unknown, .disabled:
            // .unknown must NOT offer name entry / start-fresh: a slow network is not
            // "no profile", and a typed name would LWW-clobber the real cloud identity.
            phase = .cloudUnreachable
        }
    }

    private func restore() async {
        phase = .restoring
        // Pull-FORCED, no deadline (R3): only a COMPLETED restore advances; the profile
        // store re-decoded from the pulled file, so the name shows up everywhere.
        if await cloudSync.restoreForOnboarding() != nil {
            name = profile.name
            onboarding.advance()
        } else {
            phase = .restoreFailed
        }
    }
}

// MARK: - Stage 2: Apple Music

private struct OnboardingAppleMusicStage: View {
    @Environment(OnboardingStore.self) private var onboarding
    @Environment(StreamingStore.self) private var streaming

    var body: some View {
        VStack(spacing: 14) {
            OnboardingCard {
                Label("Sign in with Apple Music", systemImage: "music.note")
                    .font(.headline)
                // #TOUPDATE: "nothing is ever captured from it" — rip-server.mjs:798 routes every
                // non-analog song to Apple Music capture unconditionally ("Digital songs always
                // capture from Apple Music"), and :549 captures an analog song on an exact library
                // match. Both paths must fail closed on Apple-Music-sourced ids before this is true.
                // The deleted second sentence ("Without it, songs still play through the rip
                // server") described serving a shared corpus to subscription-less testers as the
                // designed fallback — it does not come back.
                Text("Play full songs straight from your Apple Music subscription. Apple Music is playback only — nothing is ever captured, recorded, or downloaded from it.")
                    .font(.callout).foregroundStyle(Theme.fgDim)
                if let provider = streaming.appleMusicProvider {
                    statusRow(provider)
                } else {
                    Text("Apple Music isn't available on this device.")
                        .font(.caption).foregroundStyle(Theme.fgDim)
                }
                Text("Change this anytime in Settings ▸ Apple Music.")
                    .font(.caption).foregroundStyle(Theme.fgDim)
            }
            OnboardingNavRow(continueLabel: signedIn ? "Continue" : "Not now") {
                onboarding.advance()
            }
        }
    }

    private var signedIn: Bool {
        guard let p = streaming.appleMusicProvider else { return false }
        switch p.state {
        case .linked, .connected: return true
        default: return false
        }
    }

    @ViewBuilder private func statusRow(_ provider: any StreamingProvider) -> some View {
        switch provider.state {
        case .authorizing:
            HStack(spacing: 10) { ProgressView(); Text("Opening Apple Music…").foregroundStyle(Theme.fgDim) }
        case .linked(let acct), .connected(let acct):
            Label(acct.map { "Signed in: \($0)" } ?? "Signed in — ready to stream.",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.accent)
        case .unavailable(let reason):
            Text(reason).font(.caption).foregroundStyle(Theme.fgDim)
        case .loggedOut, .failed:
            VStack(alignment: .leading, spacing: 8) {
                if case .failed(let message) = provider.state {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                Button("Sign in") { provider.login() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("onboarding-am-signin")
            }
        }
    }
}

// MARK: - Stage 3: sources

private struct OnboardingSourcesStage: View {
    @Environment(OnboardingStore.self) private var onboarding
    @Environment(SettingsStore.self) private var settings

    @State private var vinyl = true
    @State private var digital = true
    @State private var streaming = true

    var body: some View {
        VStack(spacing: 14) {
            // #TOUPDATE: "the records you've imported" — the Vinyl source must stop subscribing to
            // the PocketDJ-published catalog index that is seeded into every new install
            // (Config.indexURL, wired at SettingsStore.applyOnboardingSources:295). Until each
            // install starts empty and fills only from that user's own imports, this card calls
            // someone else's records the user's.
            sourceCard(icon: "opticaldisc", title: "Vinyl", on: $vinyl,
                       detail: "Your vinyl, digitized — the records you've imported, analyzed for tempo, key, and mood.",
                       a11y: "onboarding-source-vinyl")
            // #TOUPDATE: "Your digital files" / "your own copy" — today "My Digital" subscribes to
            // the published digital-index.json (Config.digitalIndexURL) and its rows resolve to a
            // FLAT, public-read rips/<songId>.mp3 namespace shared across every install. Needs a
            // per-user index, a per-user key prefix, and an authenticated request on the server
            // before any install has a copy that is its own.
            sourceCard(icon: "externaldrive", title: "Digital", on: $digital,
                       detail: "Your digital files — your own copy, prepared ahead of time, so it plays and downloads with no extra step.",
                       a11y: "onboarding-source-digital")
            // #TOUPDATE: "Your Apple Music library" / "nothing is captured from it" — the shipped
            // apple-music-index.json is one published library indexed from a single Library.xml,
            // not the installing user's; and rip-server.mjs:798 still routes every non-analog song
            // to Apple Music capture unconditionally (analog on an exact library match, :549).
            // The index must become per-user AND both capture paths must fail closed on
            // Apple-Music-sourced ids before this card is honest.
            sourceCard(icon: "antenna.radiowaves.left.and.right", title: "Streaming", on: $streaming,
                       detail: "Your Apple Music library — metadata only, about a 33 MB download. These songs play through Apple Music; nothing is captured from it.",
                       a11y: "onboarding-source-streaming")
            if !(vinyl || digital || streaming) {
                Text("Pick at least one source — the browser needs a catalog to show.")
                    .font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("onboarding-zero-sources")
            }
            OnboardingNavRow(continueLabel: "Start DJing",
                             continueEnabled: vinyl || digital || streaming) {
                settings.applyOnboardingSources(vinyl: vinyl, digital: digital, streaming: streaming)
                onboarding.complete()
            }
        }
    }

    private func sourceCard(icon: String, title: String, on: Binding<Bool>,
                            detail: String, a11y: String) -> some View {
        OnboardingCard {
            Toggle(isOn: on) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(title, systemImage: icon).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(Theme.fgDim)
                }
            }
            .accessibilityIdentifier(a11y)
        }
    }
}
