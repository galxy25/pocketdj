#if canImport(GroupActivities)
import Combine
import Foundation
import GroupActivities

// ============================================================================
// MARK: - SharePlay activity + transport
// ============================================================================

/// The SharePlay activity. Carries the session MODE so a joiner knows whether it is joining a
/// Listen Together room or becoming a Backseat speaker before the first message lands.
struct PocketDJSessionActivity: GroupActivity {
    static let activityIdentifier = "com.levi.pocketdj.remote-session"
    var mode: RemoteSessionMode

    var metadata: GroupActivityMetadata {
        var m = GroupActivityMetadata()
        m.title = mode == .backseat ? "PocketDJ Backseat" : "PocketDJ Remote"
        m.subtitle = mode == .backseat ? "Control the music from the back seat"
                                       : "Listen together in sync"
        m.type = .listenTogether
        return m
    }
}

/// `RemoteTransport` over a live `GroupSession`: one RELIABLE messenger for state / commands /
/// hellos and one UNRELIABLE one for clock pings (a late ping is worse than a lost one — it
/// only ever inflates the RTT that `SharedClock` then discards).
@MainActor
final class GroupSessionTransport: RemoteTransport {
    let session: GroupSession<PocketDJSessionActivity>
    private let reliable: GroupSessionMessenger
    private let unreliable: GroupSessionMessenger
    let inbound: AsyncStream<RemoteInbound>
    let participants: AsyncStream<Set<String>>
    private let inboundCont: AsyncStream<RemoteInbound>.Continuation
    private let rosterCont: AsyncStream<Set<String>>.Continuation
    private var byId: [String: Participant] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var tasks: [Task<Void, Never>] = []
    /// Every outbound message, delivered serially (order kept, joiner sends buffered, retries).
    private var outbound: RemoteSendQueue<Participants>!

    var localParticipantId: String { session.localParticipant.id.uuidString }

    init(session: GroupSession<PocketDJSessionActivity>) {
        self.session = session
        reliable = GroupSessionMessenger(session: session, deliveryMode: .reliable)
        unreliable = GroupSessionMessenger(session: session, deliveryMode: .unreliable)
        (inbound, inboundCont) = AsyncStream.makeStream(of: RemoteInbound.self)
        (participants, rosterCont) = AsyncStream.makeStream(of: Set<String>.self,
                                                            bufferingPolicy: .bufferingNewest(1))
        let reliableMessenger = reliable, unreliableMessenger = unreliable
        outbound = RemoteSendQueue(resolve: { [weak self] to in
            switch to {
            case .all: return Participants.all
            case .participant(let id): return self?.byId[id].map { Participants.only($0) }
            }
        }, send: { env, recipients, isReliable in
            try await (isReliable ? reliableMessenger : unreliableMessenger).send(env, to: recipients)
        })
        for messenger in [reliable, unreliable] {
            let cont = inboundCont
            tasks.append(Task {
                for await (env, ctx) in messenger.messages(of: RemoteEnvelope.self) {
                    cont.yield(RemoteInbound(envelope: env, from: ctx.source.id.uuidString))
                }
            })
        }
        session.$activeParticipants
            .receive(on: DispatchQueue.main)
            .sink { [weak self] set in
                guard let self else { return }
                self.byId = Dictionary(set.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
                self.outbound.participantsChanged()
                self.rosterCont.yield(Set(self.byId.keys))
            }
            .store(in: &subscriptions)
        session.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if case .invalidated = state { self?.finish() }
            }
            .store(in: &subscriptions)
    }

    func send(_ envelope: RemoteEnvelope, to: RemoteRecipient, reliable: Bool) {
        outbound.enqueue(envelope, to: to, reliable: reliable)
    }

    func leave() {
        session.leave()
        finish()
    }

    private func finish() {
        for t in tasks { t.cancel() }
        tasks.removeAll()
        outbound.finish()
        subscriptions.removeAll()
        inboundCont.finish()
        rosterCont.finish()
    }
}

// MARK: - Session plumbing on the controller

extension RemoteSessionController {
    /// App-scoped: every SharePlay session for PocketDJ (one we started, or one a FaceTime peer /
    /// nearby device offered) arrives here for the app's lifetime. A session that lands while a
    /// start is pending is OURS to host. Started ONCE from app init and owned by the controller
    /// (a window's `.task` died with that window — multi-window ⌘N — and took SharePlay with it).
    func startObservingGroupSessions() {
        guard groupSessionsObserver == nil else { return }
        groupSessionsObserver = Task { [weak self] in
            for await session in PocketDJSessionActivity.sessions() {
                guard let self else { return }
                let asHost = self.pendingStartMode != nil
                self.pendingStartMode = nil
                DiagLog.shared.telemetry("action", "remote session arrived mode=\(session.activity.mode.rawValue) host=\(asHost)")
                let transport = GroupSessionTransport(session: session)
                session.join()
                self.attach(transport, mode: session.activity.mode, asHost: asHost)
            }
        }
    }

    enum StartOutcome: Equatable {
        /// Activated inside a FaceTime call (or the system offered its own share UI).
        case activated
        /// No call to share into — present `RemoteShareSheet` instead (Messages / nearby).
        case needsShareSheet
        case cancelled
        case failed(String)
    }

    /// Start a session in `mode` through FaceTime when a call is up.
    func start(_ mode: RemoteSessionMode) async -> StartOutcome {
        let activity = PocketDJSessionActivity(mode: mode)
        pendingStartMode = mode
        switch await activity.prepareForActivation() {
        case .activationPreferred:
            do {
                return try await activity.activate() ? .activated : .needsShareSheet
            } catch {
                pendingStartMode = nil
                return .failed(error.localizedDescription)
            }
        case .activationDisabled:
            return .needsShareSheet
        case .cancelled:
            pendingStartMode = nil
            return .cancelled
        @unknown default:
            return .needsShareSheet
        }
    }
}
#endif
