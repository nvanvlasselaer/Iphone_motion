//
//  PhoneLink.swift
//  Iphone_motion
//
//  WatchConnectivity on the iPhone. Delegate callbacks arrive on a private serial queue:
//  ping timestamps are taken there immediately; received files are moved synchronously (they are
//  deleted when the callback returns); everything else is forwarded to the main actor in order.
//

import Foundation
import RecorderCore
import WatchConnectivity

final class PhoneLink: NSObject, @unchecked Sendable {
    struct State: Equatable, Sendable {
        var supported = false
        var activated = false
        var paired = false
        var installed = false
        var reachable = false
    }

    /// Set before `activate()`.
    var onEnvelope: (@MainActor (Envelope) -> Void)?
    var onState: (@MainActor (State) -> Void)?
    var onFileReceived: (@MainActor (UUID) -> Void)?
    var inboxRoot: URL?

    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil

    func activate() {
        guard let session else {
            publishState()
            return
        }
        session.delegate = self
        session.activate()
    }

    var state: State {
        guard let session else { return State() }
        let activated = session.activationState == .activated
        return State(
            supported: true,
            activated: activated,
            paired: activated && session.isPaired,
            installed: activated && session.isWatchAppInstalled,
            reachable: activated && session.isReachable
        )
    }

    // MARK: Sending

    /// One request/reply exchange.
    func request(_ message: LinkMessage, sid: UUID?, id: UUID = UUID(), timeout: Double = 3) async throws -> Envelope {
        guard let session, session.activationState == .activated else { throw LinkError.notActivated }
        guard session.isReachable else { throw LinkError.notReachable }
        let data = try LinkCodec.encode(Envelope(message, sid: sid, id: id))
        let reply: Data
        do {
            reply = try await withOneShot(timeout: timeout) { shot in
                session.sendMessageData(data, replyHandler: { shot.resume(.success($0)) }, errorHandler: { error in
                    shot.resume(.failure(LinkError.transport(error.localizedDescription)))
                })
            }
        } catch OneShotError.timedOut {
            throw LinkError.timedOut
        }
        return try LinkCodec.decode(reply)
    }

    /// Request with retries (same message id, so the Watch answers repeated commands idempotently).
    func requestWithRetry(
        _ message: LinkMessage,
        sid: UUID?,
        attempts: Int = 3,
        timeout: Double = 3,
        reachabilityWait: Double = 5
    ) async throws -> Envelope {
        let id = UUID()
        var lastError: Error = LinkError.notReachable
        for attempt in 0..<attempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(0.5 * pow(2, Double(attempt - 1)) * 1e9))
            }
            if !state.reachable {
                _ = await waitForReachability(timeout: reachabilityWait)
            }
            do {
                return try await request(message, sid: sid, id: id, timeout: timeout)
            } catch {
                lastError = error
                if case LinkError.versionMismatch = error { break }
            }
        }
        throw lastError
    }

    /// Fire and forget; optionally queued with transferUserInfo when the Watch is not reachable.
    func send(_ message: LinkMessage, sid: UUID?, queueIfUnreachable: Bool = false) {
        guard let session, session.activationState == .activated,
              let data = try? LinkCodec.encode(Envelope(message, sid: sid)) else { return }
        if session.isReachable {
            session.sendMessageData(data, replyHandler: nil) { [weak self] _ in
                if queueIfUnreachable {
                    self?.enqueue(message, sid: sid)
                }
            }
        } else if queueIfUnreachable {
            enqueue(message, sid: sid)
        }
    }

    /// Queued delivery that survives the Watch app not running.
    func enqueue(_ message: LinkMessage, sid: UUID?) {
        guard let session, session.activationState == .activated,
              let info = try? LinkCodec.userInfo(Envelope(message, sid: sid)) else { return }
        session.transferUserInfo(info)
    }

    /// One clock-sync ping. t1 is read just before sending, t4 first thing in the reply handler.
    func ping(seq: Int, burst: PingBurst, wantStatus: Bool, timeout: Double = 2) async -> (PingSample, WatchStatus?) {
        guard let session, session.activationState == .activated, session.isReachable,
              let data = try? LinkCodec.encode(Envelope(.ping(PingPayload(seq: seq, t1: MonotonicClock.uptime(), wantStatus: wantStatus))))
        else {
            return (PingSample(seq: seq, burst: burst, t1: MonotonicClock.uptime(), status: .error), nil)
        }
        let t1 = MonotonicClock.uptime()
        do {
            let (t4, reply): (Double, Data) = try await withOneShot(timeout: timeout) { shot in
                session.sendMessageData(data, replyHandler: { reply in
                    let t4 = MonotonicClock.uptime()
                    shot.resume(.success((t4, reply)))
                }, errorHandler: { error in
                    shot.resume(.failure(error))
                })
            }
            guard case .pong(let pong) = try LinkCodec.decode(reply).body, pong.seq == seq else {
                return (PingSample(seq: seq, burst: burst, t1: t1, status: .error), nil)
            }
            return (PingSample(seq: seq, burst: burst, t1: t1, t2: pong.t2, t3: pong.t3, t4: t4, status: .ok), pong.status)
        } catch OneShotError.timedOut {
            return (PingSample(seq: seq, burst: burst, t1: t1, status: .timeout), nil)
        } catch {
            return (PingSample(seq: seq, burst: burst, t1: t1, status: .error), nil)
        }
    }

    func waitForReachability(timeout: Double) async -> Bool {
        let deadline = MonotonicClock.uptime() + timeout
        while MonotonicClock.uptime() < deadline {
            if state.reachable { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return state.reachable
    }

    // MARK: Main-actor delivery

    private func onMain(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(work)
        }
    }

    private func publishState() {
        let current = state
        onMain { [weak self] in self?.onState?(current) }
    }

    private func deliver(_ data: Data) {
        guard let envelope = try? LinkCodec.decode(data) else { return }
        onMain { [weak self] in self?.onEnvelope?(envelope) }
    }
}

extension PhoneLink: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        publishState()
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        publishState()
    }

    func sessionDidDeactivate(_ session: WCSession) {
        // The user switched to another Watch: activate again for the new one.
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        publishState()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        publishState()
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        deliver(messageData)
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        deliver(messageData)
        let ack = Envelope(.ack(CommandAck(accepted: true, phase: .idle)))
        replyHandler((try? LinkCodec.encode(ack)) ?? Data())
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let data = userInfo[LinkCodec.userInfoKey] as? Data {
            deliver(data)
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let inboxRoot,
              let metadata = file.metadata,
              let envelope = try? LinkCodec.envelope(from: metadata),
              let sid = envelope.sid,
              case .file(let info) = envelope.body else { return }
        let fileManager = FileManager.default
        let directory = inboxRoot.appendingPathComponent(sid.uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: SessionStore.protection)
            let destination = directory.appendingPathComponent(info.kind.watchFileName)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: file.fileURL, to: destination)
        } catch {
            return
        }
        onMain { [weak self] in self?.onFileReceived?(sid) }
    }
}
