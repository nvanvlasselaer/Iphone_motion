//
//  WatchLink.swift
//  Iphone_motion Watch App
//
//  WatchConnectivity on the Watch. Pings are answered inline on the delegate queue (t2 is the
//  first statement); commands go to the main actor and their replies are cached by message id so
//  a retried command gets the same answer.
//

import Foundation
import RecorderCore
import WatchConnectivity

/// Thread-safe source of the status sent back in pong replies.
final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = WatchStatus(phase: .idle)
    private var startUptime: Double?

    func set(_ status: WatchStatus, startUptime: Double?) {
        lock.lock()
        value = status
        self.startUptime = startUptime
        lock.unlock()
    }

    func get() -> (WatchStatus, Double?) {
        lock.lock()
        defer { lock.unlock() }
        return (value, startUptime)
    }
}

private final class ReplyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [UUID: Data] = [:]
    private var order: [UUID] = []
    private let capacity = 32

    func get(_ id: UUID) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return replies[id]
    }

    func put(_ id: UUID, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if replies[id] == nil {
            order.append(id)
        }
        replies[id] = data
        while order.count > capacity {
            replies.removeValue(forKey: order.removeFirst())
        }
    }
}

final class WatchLink: NSObject, @unchecked Sendable {
    /// A command that expects a reply; call the closure exactly once with the reply.
    var onRequest: (@MainActor (Envelope, @escaping (Envelope) -> Void) -> Void)?
    /// A message without reply (sendMessage without handler or transferUserInfo).
    var onMessage: (@MainActor (Envelope) -> Void)?
    var onTransferFinished: (@MainActor (UUID, FileKind, Error?) -> Void)?
    var onReachability: (@MainActor (Bool) -> Void)?
    /// Called on the delegate queue to fill pong replies; must be thread-safe.
    var statusProvider: (@Sendable () -> WatchStatus)?

    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    private let replies = ReplyCache()

    func activate() {
        session?.delegate = self
        session?.activate()
    }

    var isReachable: Bool {
        session?.activationState == .activated && session?.isReachable == true
    }

    /// Fire and forget, falling back to queued delivery when the iPhone app is not reachable.
    func send(_ message: LinkMessage, sid: UUID?) {
        guard let session, session.activationState == .activated else { return }
        let envelope = Envelope(message, sid: sid)
        if session.isReachable, let data = try? LinkCodec.encode(envelope) {
            session.sendMessageData(data, replyHandler: nil) { [weak self] _ in
                self?.enqueue(envelope)
            }
        } else {
            enqueue(envelope)
        }
    }

    private func enqueue(_ envelope: Envelope) {
        guard let session, let info = try? LinkCodec.userInfo(envelope) else { return }
        session.transferUserInfo(info)
    }

    /// Queues a file for the iPhone. The system delivers it even if the apps are not running.
    @discardableResult
    func transfer(file url: URL, info: FileInfo, sid: UUID) -> Bool {
        guard let session, session.activationState == .activated,
              let metadata = try? LinkCodec.userInfo(Envelope(.file(info), sid: sid)) else { return false }
        session.transferFile(url, metadata: metadata)
        return true
    }

    /// (sid, kind) of the files still being transferred.
    func outstandingTransfers() -> [(UUID, FileKind)] {
        guard let session else { return [] }
        return session.outstandingFileTransfers.compactMap { transfer in
            Self.identify(transfer.file.metadata)
        }
    }

    func cancelTransfers(for sid: UUID) {
        guard let session else { return }
        for transfer in session.outstandingFileTransfers where Self.identify(transfer.file.metadata)?.0 == sid {
            transfer.cancel()
        }
    }

    private static func identify(_ metadata: [String: Any]?) -> (UUID, FileKind)? {
        guard let metadata,
              let envelope = try? LinkCodec.envelope(from: metadata),
              let sid = envelope.sid,
              case .file(let info) = envelope.body else { return nil }
        return (sid, info.kind)
    }

    private func onMain(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(work)
        }
    }
}

extension WatchLink: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        onMain { [weak self] in self?.onReachability?(reachable) }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        onMain { [weak self] in self?.onReachability?(reachable) }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        let t2 = MonotonicClock.uptime()
        guard let envelope = try? LinkCodec.decode(messageData) else {
            replyHandler(Data())
            return
        }
        if case .ping(let ping) = envelope.body {
            let status = ping.wantStatus ? statusProvider?() : nil
            let t3 = MonotonicClock.uptime()
            let pong = Envelope(.pong(PongPayload(seq: ping.seq, t2: t2, t3: t3, status: status)))
            replyHandler((try? LinkCodec.encode(pong)) ?? Data())
            return
        }
        if let cached = replies.get(envelope.id) {
            replyHandler(cached)
            return
        }
        onMain { [weak self] in
            guard let self, let onRequest = self.onRequest else {
                replyHandler(Data())
                return
            }
            onRequest(envelope) { reply in
                let data = (try? LinkCodec.encode(reply)) ?? Data()
                self.replies.put(envelope.id, data)
                replyHandler(data)
            }
        }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard let envelope = try? LinkCodec.decode(messageData) else { return }
        onMain { [weak self] in self?.onMessage?(envelope) }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let envelope = try? LinkCodec.envelope(from: userInfo) else { return }
        onMain { [weak self] in self?.onMessage?(envelope) }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let (sid, kind) = Self.identify(fileTransfer.file.metadata) else { return }
        onMain { [weak self] in self?.onTransferFinished?(sid, kind, error) }
    }
}
