// A small HTTP/1.1 server (Network framework): one request per connection (Connection: close), JSON or streamed bodies.
import Foundation
import Network

public struct Request {
    public let method: String
    public let path: String
    public let headers: [String: String]   // lower-case names
    public let body: Data
}

public final class Responder: @unchecked Sendable {
    let conn: NWConnection
    let lock = NSLock()
    var closed = false
    var started = false

    init(_ conn: NWConnection) { self.conn = conn }

    /// the client went away
    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func markClosed() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    static func reason(_ code: Int) -> String {
        [200: "OK", 204: "No Content", 400: "Bad Request", 404: "Not Found", 413: "Payload Too Large",
         500: "Internal Server Error", 502: "Bad Gateway", 503: "Service Unavailable"][code] ?? "OK"
    }

    func head(_ code: Int, _ headers: [(String, String)]) -> Data {
        var s = "HTTP/1.1 \(code) \(Responder.reason(code))\r\n"
        for (k, v) in headers + [("Access-Control-Allow-Origin", "*"), ("Connection", "close")] { s += "\(k): \(v)\r\n" }
        return Data((s + "\r\n").utf8)
    }

    func raw(_ d: Data, then: (() -> Void)? = nil) {
        conn.send(content: d, completion: .contentProcessed { [weak self] err in
            if err != nil { self?.markClosed() }
            then?()
        })
    }

    public func send(_ code: Int, contentType: String, body: Data, extra: [(String, String)] = []) {
        var d = head(code, [("Content-Type", contentType), ("Content-Length", String(body.count))] + extra)
        d.append(body)
        raw(d) { [weak self] in self?.conn.cancel() }
    }

    public func json(_ code: Int, _ j: JSON) { send(code, contentType: "application/json", body: j.data) }

    /// server-sent events: the head once, then events, then end()
    public func sseStart() {
        started = true
        raw(head(200, [("Content-Type", "text/event-stream"), ("Cache-Control", "no-cache")]))
    }

    public func sse(_ data: String, event: String? = nil) {
        raw(Data(((event.map { "event: \($0)\n" } ?? "") + "data: " + data + "\n\n").utf8))
    }

    public func sse(_ j: JSON, event: String? = nil) { sse(j.dumps(), event: event) }

    public func end() {
        raw(Data()) { [weak self] in self?.conn.cancel() }
    }
}

public final class HTTPServer {
    let listener: NWListener
    let queue = DispatchQueue(label: "garlic.http", attributes: .concurrent)
    let handler: (Request, Responder) -> Void

    public init(port: UInt16, localOnly: Bool, handler: @escaping (Request, Responder) -> Void) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if localOnly { params.requiredInterfaceType = .loopback }   // (this Mac only)
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        self.handler = handler
    }

    public func start(state: @escaping (String?) -> Void) {
        listener.stateUpdateHandler = { s in
            switch s {
            case .ready: state(nil)
            case let .failed(e): state("\(e)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: queue)
    }

    public func stop() { listener.cancel() }

    func accept(_ c: NWConnection) {
        let r = Responder(c)
        c.stateUpdateHandler = { s in
            switch s {
            case .failed, .cancelled: r.markClosed()
            default: break
            }
        }
        c.start(queue: queue)
        read(c, r, Data())
    }

    func read(_ c: NWConnection, _ r: Responder, _ acc: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = acc
            if let data { buf.append(data) }
            if err != nil { c.cancel(); return }
            guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if done || buf.count > 1 << 20 { c.cancel() } else { self.read(c, r, buf) }
                return
            }
            let headText = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
            var lines = headText.components(separatedBy: "\r\n")
            let first = lines.removeFirst().split(separator: " ")
            guard first.count >= 2 else { c.cancel(); return }
            var headers: [String: String] = [:]
            for l in lines {
                guard let i = l.firstIndex(of: ":") else { continue }
                headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
            let need = Int(headers["content-length"] ?? "0") ?? 0
            if need > 256 << 20 { r.json(413, .object([("error", .object([("message", .string("request too large"))]))])); return }
            let have = buf.count - end.upperBound
            if have < need && !done {
                self.read(c, r, buf)
                return
            }
            let body = buf[end.upperBound ..< min(buf.count, end.upperBound + need)]
            let req = Request(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body))
            Thread.detachNewThread { self.handler(req, r) }   // (generation blocks: a thread of its own)
        }
    }
}
