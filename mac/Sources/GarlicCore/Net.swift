// Talking to the console: a small blocking HTTP/1.1 client over BSD sockets (timeouts, streamed lines), and finding the
// console on the network (its UDP announcement, or a scan of this Mac's /24 networks).
import Darwin
import Foundation

public final class Conn {
    let fd: Int32
    var buf = [UInt8]()
    var pos = 0

    /// connects with a timeout; nil if it cannot
    public init?(host: String, port: Int, connectTimeout: Double, ioTimeout: Double) {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { return nil }
        defer { freeaddrinfo(res) }
        let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard s >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        var r = connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
        if r != 0 && errno == EINPROGRESS {
            var p = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            r = poll(&p, 1, Int32(connectTimeout * 1000)) == 1 ? 0 : -1
            if r == 0 {
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
                if err != 0 { r = -1 }
            }
        }
        if r != 0 { close(s); return nil }
        _ = fcntl(s, F_SETFL, flags)
        var tv = timeval(tv_sec: Int(ioTimeout), tv_usec: Int32((ioTimeout - Double(Int(ioTimeout))) * 1e6))
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        fd = s
    }

    deinit { close(fd) }

    public func send(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + off, raw.count - off, 0)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    func fill() -> Bool {
        if pos > 0 && pos == buf.count { buf.removeAll(keepingCapacity: true); pos = 0 }
        var tmp = [UInt8](repeating: 0, count: 65536)
        let n = recv(fd, &tmp, tmp.count, 0)
        if n <= 0 { return false }
        buf.append(contentsOf: tmp[0 ..< n])
        return true
    }

    /// one line without its "\n" (and "\r"); nil at the end or on a timeout
    public func readLine() -> String? {
        while true {
            if let i = buf[pos...].firstIndex(of: 0x0A) {
                var line = buf[pos ..< i]
                if line.last == 0x0D { line = line.dropLast() }
                pos = i + 1
                return String(decoding: line, as: UTF8.self)
            }
            if !fill() {
                if pos < buf.count {
                    let rest = String(decoding: buf[pos...], as: UTF8.self)
                    pos = buf.count
                    return rest
                }
                return nil
            }
        }
    }

    public func readAll(limit: Int = 1 << 20) -> Data {
        while buf.count - pos < limit, fill() {}
        let d = Data(buf[pos...])
        pos = buf.count
        return d
    }

    /// sends a request; returns the status code (headers read), or nil
    public func request(method: String, host: String, path: String, body: Data? = nil,
                        contentType: String = "application/json") -> Int? {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n"
        if let body { head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n" }
        head += "\r\n"
        var d = Data(head.utf8)
        if let body { d.append(body) }
        guard send(d), let status = readLine() else { return nil }
        let parts = status.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return nil }
        while let h = readLine(), !h.isEmpty {}
        return code
    }
}

/// GET path -> (status, body); nil if unreachable
public func httpGet(host: String, port: Int, path: String, timeout: Double) -> (Int, Data)? {
    guard let c = Conn(host: host, port: port, connectTimeout: timeout, ioTimeout: timeout),
          let code = c.request(method: "GET", host: host, path: path) else { return nil }
    return (code, c.readAll())
}

// ---- finding the console ---------------------------------------------------------------------------------------------

public let beaconPort: UInt16 = 8099

/// listens for "GARLIC1 <port> <model>" on UDP 8099 (Garlic Server 1.21+, every 2 s); calls found(host, port, model)
public func startBeaconListener(found: @escaping (String, Int, String) -> Void, failed: @escaping (String) -> Void) {
    Thread.detachNewThread {
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { failed("no UDP socket"); return }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = beaconPort.bigEndian
        a.sin_addr.s_addr = INADDR_ANY
        let ok = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { failed("cannot listen on UDP \(beaconPort) (errno \(errno))"); close(s); return }
        var buf = [UInt8](repeating: 0, count: 512)
        while true {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(s, &buf, buf.count, 0, $0, &len) }
            }
            if n <= 0 { usleep(500_000); continue }
            let f = String(decoding: buf[0 ..< n], as: UTF8.self).split(whereSeparator: { $0 == " " || $0 == "\n" })
            guard f.count >= 2, f[0] == "GARLIC1", let port = Int(f[1]) else { continue }
            let host = String(cString: inet_ntoa(from.sin_addr))
            found(host, port, f.count > 2 ? String(f[2]) : "")
        }
    }
}

/// the /24 networks of this Mac's IPv4 interfaces ("192.168.1")
public func localSubnets() -> [String] {
    var nets = Set<String>()
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0 else { return [] }
    defer { freeifaddrs(ifap) }
    var p = ifap
    while let i = p {
        if let sa = i.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (i.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 {
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { String(cString: inet_ntoa($0.pointee.sin_addr)) }
            let parts = addr.split(separator: ".")
            if parts.count == 4, !addr.hasPrefix("169.254.") { nets.insert(parts[0 ..< 3].joined(separator: ".")) }
        }
        p = i.pointee.ifa_next
    }
    return nets.sorted()
}

/// asks every address of the local /24 networks for GET /v1/models on port 8080, 64 at a time; the first that answers
public func scanForConsole() -> String? {
    let hosts = localSubnets().flatMap { n in (1 ... 254).map { "\(n).\($0)" } }
    let lock = NSLock()
    var found: String?
    var next = 0
    let group = DispatchGroup()
    for _ in 0 ..< min(64, hosts.count) {   // (threads of their own: the probes block for up to 1.5 s each)
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            while true {
                lock.lock()
                let i = next
                next += 1
                let done = found != nil || i >= hosts.count
                lock.unlock()
                if done { return }
                let h = hosts[i]
                if let (code, body) = httpGet(host: h, port: 8080, path: "/v1/models", timeout: 1.5), code == 200,
                   String(decoding: body, as: UTF8.self).contains("\"data\"") {
                    lock.lock()
                    if found == nil { found = h }
                    lock.unlock()
                }
            }
        }
    }
    group.wait()
    return found
}
