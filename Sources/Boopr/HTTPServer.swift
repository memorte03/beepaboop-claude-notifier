import Foundation
import Network

/// Minimal HTTP/1.1 server on 127.0.0.1.
/// Routes:
///   GET  /health      → liveness (full state counts only when the token is supplied)
///   POST /notify      → enqueue NotifyRequest, return 200 immediately
///   POST /permission  → enqueue + long-poll until user clicks; return PermissionResponse JSON
///
/// `@unchecked Sendable` is sound because every stored property is immutable
/// (`let`) and the only mutable state — `store` — is a `@MainActor` object only
/// touched via `MainActor.run` / `Task { @MainActor }`.
final class HTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let store: NotificationStore
    private let queue = DispatchQueue(label: "boopr.http")
    /// Shared secret hooks must echo back in the x-boopr-token header. When nil
    /// (token file unwritable) auth is disabled rather than locking everyone out.
    private let token: String?

    /// Caps to keep an unauthenticated peer from exhausting memory. Legitimate
    /// payloads are a few KB; these are generous ceilings, not tight limits.
    private let maxHeaderBytes = 16 * 1024
    private let maxBodyBytes = 1 * 1024 * 1024
    /// Wall-clock budget for reading a full request. This bounds only the
    /// request-reading phase — the /permission long-poll happens after routing,
    /// while the app holds the connection waiting for the user, and is unaffected.
    private let readTimeout: TimeInterval = 10

    /// Sendable box around the read-deadline work item so it can cross the
    /// `@Sendable` receive closures (DispatchWorkItem isn't Sendable).
    private final class Deadline: @unchecked Sendable {
        private let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    init(port: UInt16, store: NotificationStore, token: String?) throws {
        self.store = store
        self.token = token
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NWError.posix(.EADDRNOTAVAIL)
        }
        self.listener = try NWListener(using: params, on: nwPort)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: queue)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        // Cancel the connection if a full request hasn't been read in time. Armed
        // here, disarmed in `route` once we've finished reading and start serving.
        let item = DispatchWorkItem { conn.cancel() }
        queue.asyncAfter(deadline: .now() + readTimeout, execute: item)
        readRequest(conn, buffer: Data(), deadline: Deadline(item))
    }

    private func readRequest(_ conn: NWConnection, buffer: Data, deadline: Deadline) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                NSLog("recv error: \(error)")
                conn.cancel(); deadline.cancel()
                return
            }
            var buf = buffer
            if let data, !data.isEmpty { buf.append(data) }

            guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                // No header terminator yet: bail if we've buffered too much (a
                // peer dribbling headers forever) or the peer closed.
                if buf.count > self.maxHeaderBytes {
                    self.respond(conn, status: 431, body: "headers too large", deadline: deadline); return
                }
                if isComplete { conn.cancel(); deadline.cancel(); return }
                self.readRequest(conn, buffer: buf, deadline: deadline)
                return
            }

            let headerData = buf.subdata(in: 0..<headerEnd.lowerBound)
            guard let headerStr = String(data: headerData, encoding: .utf8) else {
                self.respond(conn, status: 400, body: "bad headers", deadline: deadline); return
            }
            let lines = headerStr.components(separatedBy: "\r\n")
            let parts = (lines.first ?? "").components(separatedBy: " ")
            guard parts.count >= 2 else {
                self.respond(conn, status: 400, body: "bad request line", deadline: deadline); return
            }
            let method = parts[0]
            let path = parts[1]

            var parsed: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                parsed[name] = value
            }
            let headers = parsed   // immutable snapshot for the @Sendable captures below

            // /health is the only unauthenticated route; it returns liveness, and
            // full state counts only to a caller holding the token.
            if path == "/health" {
                deadline.cancel()
                let authed = self.tokenOK(headers)
                Task { @MainActor in
                    let body = authed
                        ? #"{"ok":true,"current":\#(self.store.current != nil),"queued":\#(self.store.queue.count),"pending":\#(self.store.pending.count)}"#
                        : #"{"ok":true}"#
                    self.queue.async { self.respond(conn, status: 200, body: body, contentType: "application/json") }
                }
                return
            }

            // Authenticate + content-negotiate BEFORE reading any body, so an
            // unauthenticated peer can never make us buffer a large payload.
            guard method == "POST" else {
                self.respond(conn, status: 405, body: "method not allowed", deadline: deadline); return
            }
            guard self.tokenOK(headers) else {
                self.respond(conn, status: 403, body: #"{"error":"missing or bad token"}"#,
                             contentType: "application/json", deadline: deadline); return
            }
            guard headers["content-type"]?.lowercased().contains("application/json") == true else {
                self.respond(conn, status: 415, body: #"{"error":"expected application/json"}"#,
                             contentType: "application/json", deadline: deadline); return
            }

            // Validate Content-Length: a body-bearing route requires it, and a
            // negative or oversized value is rejected rather than trusted.
            guard let clString = headers["content-length"], let contentLength = Int(clString) else {
                self.respond(conn, status: 411, body: #"{"error":"length required"}"#,
                             contentType: "application/json", deadline: deadline); return
            }
            guard contentLength >= 0, contentLength <= self.maxBodyBytes else {
                self.respond(conn, status: 413, body: #"{"error":"body too large"}"#,
                             contentType: "application/json", deadline: deadline); return
            }

            let bodyStart = headerEnd.upperBound
            let alreadyRead = buf.count - bodyStart
            if alreadyRead < contentLength {
                self.readBody(conn, accumulated: buf, needed: contentLength + bodyStart, deadline: deadline) { full in
                    let upper = min(bodyStart + contentLength, full.count)
                    let body = upper > bodyStart ? full.subdata(in: bodyStart..<upper) : Data()
                    self.route(conn, method: method, path: path, body: body, deadline: deadline)
                }
            } else {
                let body = contentLength > 0 ? buf.subdata(in: bodyStart..<(bodyStart + contentLength)) : Data()
                self.route(conn, method: method, path: path, body: body, deadline: deadline)
            }
        }
    }

    private func readBody(_ conn: NWConnection, accumulated: Data, needed: Int,
                          deadline: Deadline, done: @escaping @Sendable (Data) -> Void) {
        if accumulated.count >= needed { done(accumulated); return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { NSLog("body recv: \(error)"); conn.cancel(); deadline.cancel(); return }
            var buf = accumulated
            if let data { buf.append(data) }
            if buf.count >= needed || isComplete { done(buf) }
            else { self.readBody(conn, accumulated: buf, needed: needed, deadline: deadline, done: done) }
        }
    }

    private func route(_ conn: NWConnection, method: String, path: String, body: Data, deadline: Deadline) {
        deadline.cancel()   // request fully read — we own the connection's lifetime now
        Debug.log("HTTP \(method) \(path) body=\(body.count) bytes")
        switch path {
        case "/notify":
            do {
                let req = try JSONDecoder().decode(NotifyRequest.self, from: body)
                Task { @MainActor in self.store.enqueue(req) }
                respond(conn, status: 200, body: #"{"ok":true}"#, contentType: "application/json")
            } catch {
                NSLog("/notify decode failed: \(error)")
                respond(conn, status: 400, body: #"{"error":"bad json"}"#, contentType: "application/json")
            }

        case "/permission":
            do {
                let req = try JSONDecoder().decode(NotifyRequest.self, from: body)
                Task {
                    let handle = await MainActor.run { self.store.enqueuePermission(req) }
                    let result = await handle.awaitDecision()
                    let json = (try? JSONEncoder().encode(result)) ?? Data(#"{"decision":"ask"}"#.utf8)
                    // Pin the response to the connection's own queue so `conn` is
                    // never touched concurrently from two executors.
                    self.queue.async {
                        self.respond(conn, status: 200, bodyData: json, contentType: "application/json")
                    }
                }
            } catch {
                NSLog("/permission decode failed: \(error)")
                respond(conn, status: 400, body: #"{"error":"bad json"}"#, contentType: "application/json")
            }

        default:
            respond(conn, status: 404, body: "not found")
        }
    }

    /// True when auth is disabled (no token) or the request carries the matching
    /// token, compared in constant time.
    private func tokenOK(_ headers: [String: String]) -> Bool {
        guard let token else { return true }
        guard let provided = headers[AuthToken.header] else { return false }
        return Self.constantTimeEquals(provided, token)
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.count { diff |= lhs[i] ^ rhs[i] }
        return diff == 0
    }

    private func respond(_ conn: NWConnection, status: Int, body: String,
                         contentType: String = "text/plain", deadline: Deadline? = nil) {
        deadline?.cancel()
        respond(conn, status: status, bodyData: Data(body.utf8), contentType: contentType)
    }

    private func respond(_ conn: NWConnection, status: Int, bodyData: Data, contentType: String) {
        let head = """
        HTTP/1.1 \(status) \(Self.reasonPhrase(status))\r
        Content-Type: \(contentType)\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r

        """
        var out = Data(head.utf8)
        out.append(bodyData)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 431: return "Request Header Fields Too Large"
        default:  return "Error"
        }
    }
}
