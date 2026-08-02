import Foundation

enum WebOSError: LocalizedError {
    case notConnected
    case connectionLost
    case timedOut
    case tvError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected."
        case .connectionLost: return "Connection lost."
        case .timedOut: return "The TV didn't answer in time."
        case .tvError(let message): return message
        }
    }
}

/// Low-level webOS SSAP client over a WebSocket. Handles the registration/pairing
/// handshake and correlates request ids to responses. One instance == one TV connection.
final class WebOSClient: NSObject {
    private let host: String
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeouts: [String: DispatchWorkItem] = [:]
    private var registerContinuation: CheckedContinuation<String, Error>?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var nextId = 0
    private var open = false
    private var closed = false

    // Guarded by `lock`: read by URLSession's delegate queue while the controller's
    // reconnect loop swaps it (a torn unsynchronized access here crashed in the wild).
    private var _onDisconnected: (() -> Void)?

    /// Raised once when the socket drops, so the controller can reconnect.
    var onDisconnected: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onDisconnected }
        set { lock.lock(); defer { lock.unlock() }; _onDisconnected = newValue }
    }

    init(host: String) {
        self.host = host
    }

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return open && !closed
    }

    /// Opens the WebSocket and starts receiving. When `secure`, connects wss:// and
    /// accepts the TV's self-signed certificate. Fails after `timeout` seconds.
    func connect(port: Int, secure: Bool, timeout: TimeInterval = 6) async throws {
        let scheme = secure ? "wss" : "ws"
        guard let url = URL(string: "\(scheme)://\(host):\(port)") else {
            throw WebOSError.tvError("Bad host: \(host)")
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            connectContinuation = cont
            lock.unlock()

            // Connect timeout: URLSessionWebSocketTask can dawdle far longer than we want.
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let cont = self.connectContinuation
                self.connectContinuation = nil
                self.lock.unlock()
                if let cont {
                    task.cancel()
                    cont.resume(throwing: WebOSError.timedOut)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
            task.resume()
        }

        receiveLoop()
    }

    /// Performs the pairing handshake. With a stored client-key the TV re-authorizes
    /// silently; otherwise it shows the on-screen prompt and this call completes once
    /// the user accepts. Returns the client-key to persist.
    func register(clientKey: String?) async throws -> String {
        guard isConnected else { throw WebOSError.notConnected }
        let id = makeId("register")
        let message: [String: Any] = [
            "id": id,
            "type": "register",
            "payload": SsapPayloads.registerPayload(clientKey: clientKey)
        ]
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            registerContinuation = cont
            lock.unlock()
            sendRaw(message) { [weak self] error in
                if let error, let self {
                    self.lock.lock()
                    let c = self.registerContinuation
                    self.registerContinuation = nil
                    self.lock.unlock()
                    c?.resume(throwing: error)
                }
            }
        }
    }

    /// Sends a request and awaits the correlated response payload.
    /// A `timeout` caps the wait, so a dead-but-open socket can't hang a caller forever.
    func request(_ uri: String, payload: [String: Any]? = nil,
                 timeout: TimeInterval? = nil) async throws -> [String: Any] {
        guard isConnected else { throw WebOSError.notConnected }
        let id = makeId("req")
        var message: [String: Any] = ["id": id, "type": "request", "uri": uri]
        if let payload { message["payload"] = payload }

        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            pending[id] = cont
            if let timeout {
                let item = DispatchWorkItem { [weak self] in
                    self?.fail(id: id, with: WebOSError.timedOut)
                }
                timeouts[id] = item
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
            }
            lock.unlock()

            sendRaw(message) { [weak self] error in
                if let error { self?.fail(id: id, with: error) }
            }
        }
    }

    /// Executes a privileged luna:// call indirectly via the notification-alert API — the
    /// only way unprivileged SSAP clients can write picture settings on stock TVs. Creates
    /// an alert whose button/onclose carries the luna URI + params, then closes it to fire it.
    /// Returns the createAlert response (its returnValue confirms the alert was accepted).
    func lunaRequest(_ lunaUri: String, params: [String: Any],
                     timeout: TimeInterval? = nil) async throws -> [String: Any] {
        let full = "luna://" + lunaUri
        let payload: [String: Any] = [
            "message": " ",
            "modal": true,
            "buttons": [["label": "", "onClick": full, "params": params]],
            "onclose": ["uri": full, "params": params],
            "type": "confirm"
        ]
        let created = try await request(SsapPayloads.createAlert, payload: payload, timeout: timeout)
        if let alertId = created["alertId"] as? String, !alertId.isEmpty {
            _ = try await request(SsapPayloads.closeAlert, payload: ["alertId": alertId], timeout: timeout)
        }
        return created
    }

    // MARK: - Internals

    private func makeId(_ prefix: String) -> String {
        lock.lock(); defer { lock.unlock() }
        nextId += 1
        return "\(prefix)_\(nextId)"
    }

    private func sendRaw(_ message: [String: Any], completion: @escaping (Error?) -> Void) {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: message) else {
            completion(WebOSError.notConnected)
            return
        }
        task.send(.string(String(decoding: data, as: UTF8.self))) { error in
            completion(error)
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    self.handleMessage(text)
                } else if case .data(let data) = message {
                    self.handleMessage(String(decoding: data, as: UTF8.self))
                }
                self.receiveLoop()
            case .failure:
                self.handleClosed()
            }
        }
    }

    private func handleMessage(_ json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let msg = object as? [String: Any] else { return }

        let type = msg["type"] as? String
        let payload = msg["payload"] as? [String: Any]

        // Registration: ignore the intermediate PROMPT response, complete on "registered".
        if type == "registered" {
            let key = payload?["client-key"] as? String ?? ""
            lock.lock()
            let cont = registerContinuation
            registerContinuation = nil
            lock.unlock()
            cont?.resume(returning: key)
            return
        }
        if type == "error" {
            let error = msg["error"] as? String ?? "TV returned an error"
            if let id = msg["id"] as? String, hasPending(id) {
                fail(id: id, with: WebOSError.tvError(error))
            } else {
                lock.lock()
                let cont = registerContinuation
                registerContinuation = nil
                lock.unlock()
                cont?.resume(throwing: WebOSError.tvError(error))
            }
            return
        }

        if let id = msg["id"] as? String {
            lock.lock()
            let cont = pending.removeValue(forKey: id)
            timeouts.removeValue(forKey: id)?.cancel()
            lock.unlock()
            cont?.resume(returning: payload ?? [:])
        }
    }

    private func hasPending(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pending[id] != nil
    }

    private func fail(id: String, with error: Error) {
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        timeouts.removeValue(forKey: id)?.cancel()
        lock.unlock()
        cont?.resume(throwing: error)
    }

    private func handleClosed() {
        lock.lock()
        let wasClosed = closed
        closed = true
        open = false
        let conts = pending.values
        pending.removeAll()
        for item in timeouts.values { item.cancel() }
        timeouts.removeAll()
        let reg = registerContinuation
        registerContinuation = nil
        let connect = connectContinuation
        connectContinuation = nil
        let disconnectHandler = _onDisconnected
        lock.unlock()

        for cont in conts { cont.resume(throwing: WebOSError.connectionLost) }
        reg?.resume(throwing: WebOSError.connectionLost)
        connect?.resume(throwing: WebOSError.connectionLost)
        if !wasClosed { disconnectHandler?() }
    }

    func dispose() {
        lock.lock()
        let alreadyClosed = closed
        closed = true
        lock.unlock()
        onDisconnected = nil
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        if !alreadyClosed {
            // Fail whatever is still pending so no caller hangs.
            handleClosed()
        }
        task = nil
        session = nil
    }
}

extension WebOSClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        lock.lock()
        open = true
        let cont = connectContinuation
        connectContinuation = nil
        lock.unlock()
        cont?.resume()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        handleClosed()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let ns = error as NSError
            Log.write("ws \(host): \(ns.domain) \(ns.code) — \(ns.localizedDescription)"
                      + (ns.userInfo[NSUnderlyingErrorKey].map { " | underlying: \($0)" } ?? ""))
            handleClosed()
        }
    }

    // The TV's wss:// endpoint uses a self-signed certificate — accept it. This client
    // only ever talks to the one TV host it was created for.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
