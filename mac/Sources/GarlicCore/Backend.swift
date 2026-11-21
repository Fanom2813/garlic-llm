// The console side: where it is, which model it has loaded (with that model's tokenizer from the models folders), and
// one generation at a time over POST /v1/raw (token ids in, token ids out, with the console's prompt cache).
import Foundation

public struct GenStats {
    public var prompt = 0, cached = 0, generated = 0
    public var prefillSeconds = 0.0, decodeSeconds = 0.0
    public var finish = "error"
    public var error: String?
}

/// What the menu shows; changes go to Backend.onChange (any thread)
public struct Snapshot {
    public var host: String?
    public var port = 8080
    public var reachable = false
    public var how = ""                 // "announcement" / "network scan" / "fixed"
    public var consoleModel = ""        // the name the console reports
    public var busy = false
    public var phase = ""               // "reading the prompt" / "writing"
    public var liveTokS = 0.0
    public var liveTokens = 0
    public var lastRequest = ""
    public var requests = 0
    public var tokensIn = 0, tokensCached = 0, tokensOut = 0
    public var log: [String] = []

    public init() {}
}

public final class Backend: @unchecked Sendable {
    let lock = NSLock()
    let genLock = NSLock()
    public private(set) var snap = Snapshot()
    public var onChange: ((Snapshot) -> Void)?
    let modelDirs: [URL]
    var models: [String: Model] = [:]
    var current: Model?
    var currentName = ""
    var modelCheckedAt = Date.distantPast
    var beaconAt = Date.distantPast
    var scanAt = Date.distantPast
    var scanning = false
    var switchChecking = false
    var ignored = Set<String>()   // addresses whose announcements were ignored (logged once)
    let fixed: Bool
    // the token-exact text of the last exchange, so the next prompt reuses its ids (keeps the console's cache hitting)
    var lastText: String?
    var lastIds: [Int]?
    var lastModel: String?
    let idsLock = NSLock()   // (lastText / lastIds: also read before a generation, to check the prompt fits)
    /// the console's context in tokens (learned from its refusal if it differs)
    public var contextLimit = 16384
    public var defaultMaxTokens = 4096
    public var defaultTemperature = 0.6
    public var defaultThink = false
    // ~/Library/Logs/Garlic.log (started afresh each launch; the previous one kept as Garlic.old.log)
    let logFile: FileHandle? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        let f = dir.appendingPathComponent("Garlic.log"), old = dir.appendingPathComponent("Garlic.old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: f, to: old)
        FileManager.default.createFile(atPath: f.path, contents: nil)
        return try? FileHandle(forWritingTo: f)
    }()

    public init(modelDirs: [URL], fixedHost: String? = nil, fixedPort: Int = 8080) {
        self.modelDirs = modelDirs
        fixed = fixedHost != nil
        if let h = fixedHost {
            snap.host = h
            snap.port = fixedPort
            snap.how = "fixed"
        }
    }

    func update(_ f: (inout Snapshot) -> Void) {
        lock.lock()
        f(&snap)
        let s = snap
        lock.unlock()
        onChange?(s)
    }

    public func log(_ line: String) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        let l = "\(df.string(from: Date())) \(line)"
        FileHandle.standardError.write(Data((l + "\n").utf8))
        logFile?.seekToEndOfFile()
        logFile?.write(Data((l + "\n").utf8))
        update {
            $0.log.append(l)
            if $0.log.count > 300 { $0.log.removeFirst($0.log.count - 300) }
        }
    }

    public var address: (String, Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let h = snap.host else { return nil }
        return (h, snap.port)
    }

    // ---- finding the console ----

    public func start() {
        if !fixed {
            startBeaconListener(found: { [weak self] host, port, model in
                guard let self else { return }
                self.lock.lock()
                self.beaconAt = Date()
                let changed = self.snap.host != host || self.snap.port != port
                self.lock.unlock()
                if changed { self.switchConsole(host, port, how: "announcement" + (model.isEmpty ? "" : ", model \(model)")) }
            }, failed: { [weak self] msg in self?.log("announcements: \(msg); finding the console by scanning") })
            scan()
        }
        Thread.detachNewThread { [weak self] in   // every 5 s: is it there, and with which model
            while let self {
                self.checkConsole()
                Thread.sleep(forTimeInterval: 5)
            }
        }
    }

    /// Announcements and scan results are not authenticated (anyone on the network could send one and receive the
    /// prompts): another address is only taken when the current console, asked right now, does not answer.
    func switchConsole(_ host: String, _ port: Int, how: String) {
        lock.lock()
        let cur = snap.host.map { ($0, snap.port) }, busy = snap.busy
        lock.unlock()
        guard let (ch, cp) = cur else { setConsole(host, port, how: how); return }
        if busy { return }   // (mid-request the console may be too busy to answer the check: never switch then)
        lock.lock()
        let checking = switchChecking
        switchChecking = true
        lock.unlock()
        if checking { return }   // (one check at a time; a flood of announcements starts nothing more)
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            defer { self.lock.lock(); self.switchChecking = false; self.lock.unlock() }
            // three checks over ~4 s must all fail before a console that worked is given up
            var alive = false
            for i in 0 ..< 3 where !alive {
                if i > 0 { Thread.sleep(forTimeInterval: 2) }
                if let (code, _) = httpGet(host: ch, port: cp, path: "/v1/models", timeout: 2), code == 200 { alive = true }
            }
            self.lock.lock()
            let nowBusy = self.snap.busy, moved = self.snap.host != ch
            self.lock.unlock()
            if nowBusy || moved { return }
            if alive {
                self.lock.lock()
                let first = self.ignored.insert(host).inserted
                self.lock.unlock()
                if first { self.log("ignoring \(how) from \(host):\(port): the console at \(ch) still answers") }
                return
            }
            self.setConsole(host, port, how: how)
        }
    }

    func setConsole(_ host: String, _ port: Int, how: String) {
        log("console at \(host):\(port) (\(how))")
        update {
            $0.host = host
            $0.port = port
            $0.how = how.hasPrefix("announcement") ? "announcement" : how
        }
        lock.lock()
        modelCheckedAt = .distantPast
        lock.unlock()
        checkConsole()
    }

    /// a scan of the local networks, in the background (not while announcements arrive; at most every 20 s)
    public func scan(force: Bool = false) {
        lock.lock()
        let now = Date()
        let skip = fixed || scanning || (!force && (now.timeIntervalSince(scanAt) < 20 || now.timeIntervalSince(beaconAt) < 10))
        if !skip { scanning = true; scanAt = now }
        lock.unlock()
        if skip { return }
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            let found = scanForConsole()
            self.lock.lock()
            self.scanning = false
            let same = found != nil && self.snap.host == found
            self.lock.unlock()
            if let h = found {
                if !same { self.switchConsole(h, 8080, how: "network scan") }
            } else {
                self.log("scan: no Garlic Server on " + localSubnets().map { $0 + ".x" }.joined(separator: ", "))
            }
        }
    }

    /// GET /v1/models: reachable, and the model name
    func checkConsole() {
        if snap.busy { return }   // (the console answers one connection at a time: it is busy with ours)
        guard let (h, p) = address else { scan(); return }
        if let (code, body) = httpGet(host: h, port: p, path: "/v1/models", timeout: 4), code == 200,
           let j = try? JSON.parse(body), let name = j["data"]?[0]?["id"]?.string {
            let was = snap.reachable
            update {
                $0.reachable = true
                $0.consoleModel = name
            }
            if !was { log("console reachable at \(h):\(p), model \(name)") }
        } else {
            if snap.reachable { log("console at \(h):\(p) stopped answering") }
            update { $0.reachable = false }
            scan()
        }
    }

    // ---- models ----

    func folder(for name: String) -> URL? {
        // (the name comes from the console: only a plain folder name, never a path)
        guard !name.isEmpty, name.count <= 64, !name.contains(".."),
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else { return nil }
        var n = name
        while true {   // "maple-fast" -> "maple-fast", then "maple"
            for d in modelDirs {
                let f = d.appendingPathComponent(n)
                if FileManager.default.fileExists(atPath: f.appendingPathComponent("tokenizer.json").path) { return f }
            }
            guard let i = n.lastIndex(of: "-") else { return nil }
            n = String(n[..<i])
        }
    }

    public func availableModels() -> [String] {
        var out = Set<String>()
        for d in modelDirs {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
            where FileManager.default.fileExists(atPath: d.appendingPathComponent(f).appendingPathComponent("tokenizer.json").path) {
                out.insert(f)
            }
        }
        return out.sorted()
    }

    func load(_ name: String, _ folder: URL) -> Model? {
        if let m = models[folder.path] { return m }
        let sem = DispatchSemaphore(value: 0)
        var result: Model?
        var failure: Error?
        Task.detached {
            do { result = try await Model(folder: folder, name: name) } catch { failure = error }
            sem.signal()
        }
        sem.wait()
        if let failure { log("cannot load the tokenizer in \(folder.path): \(failure)") }
        if let result { models[folder.path] = result }
        return result
    }

    /// the model loaded on the console (checked every 3 s), with its tokenizer
    public func currentModel() -> Model? {
        lock.lock()
        let fresh = (Date().timeIntervalSince(modelCheckedAt) < 3 || snap.busy) && current != nil
        lock.unlock()
        if fresh { return current }
        var name = snap.consoleModel
        if let (h, p) = address, let (code, body) = httpGet(host: h, port: p, path: "/v1/models", timeout: 4), code == 200,
           let j = try? JSON.parse(body), let n = j["data"]?[0]?["id"]?.string {
            name = n
            update { $0.reachable = true; $0.consoleModel = n }
        } else {
            scan()
        }
        lock.lock()
        modelCheckedAt = Date()
        lock.unlock()
        if !name.isEmpty, name != currentName {
            if let f = folder(for: name), let m = load(name, f) {
                current = m
                currentName = name
                log("model on the console: \(name) (tokenizer \(f.lastPathComponent))")
            } else if current == nil {
                log("the console reports model \"\(name)\" but no tokenizer folder matches it")
            }
        }
        if current == nil, let first = availableModels().first, let f = folder(for: first) {
            current = load(first, f)
            currentName = ""
        }
        return current
    }

    // ---- generation ----

    func promptIds(_ model: Model, _ text: String) -> [Int] {
        idsLock.lock()
        defer { idsLock.unlock() }
        if lastModel != model.name { lastText = nil; lastIds = nil; lastModel = model.name }
        if let lt = lastText, let li = lastIds, text.hasPrefix(lt) {
            return li + model.encode(String(text.dropFirst(lt.count)))
        }
        return model.encode(text)
    }

    func setLast(_ text: String?, _ ids: [Int]?) {
        idsLock.lock()
        lastText = text; lastIds = ids
        idsLock.unlock()
    }

    /// prompt length in tokens, as generate() will send it
    public func countPrompt(_ model: Model, _ text: String) -> Int { promptIds(model, text).count }

    /// streams the reply: onTokens(ids) per step; one generation at a time
    public func generate(model: Model, text: String, maxNew: Int, temperature: Double, seed: UInt32,
                         onTokens: ([Int]) -> Void, cancelled: () -> Bool) -> GenStats {
        genLock.lock()
        defer { genLock.unlock() }
        var st = GenStats()
        let ids = promptIds(model, text)
        st.prompt = ids.count
        let stops = model.stopIds
        var body = Data("GRW1".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { body.append(contentsOf: $0) } }
        let room = contextLimit - ids.count - 2   // (the reply must fit the console's context too)
        u32(UInt32(ids.count)); u32(UInt32(max(1, min(maxNew, room))))
        u32(Float(temperature).bitPattern); u32(seed); u32(UInt32(stops.count)); u32(0)
        for s in stops { u32(UInt32(s)) }
        for i in ids { u32(UInt32(i)) }
        update {
            $0.busy = true
            $0.phase = "reading the prompt"
            $0.liveTokS = 0
            $0.liveTokens = 0
        }
        defer { update { $0.busy = false; $0.phase = "" } }
        var gen: [Int] = []
        guard let (h, p) = address else {
            st.error = "the console has not been found on the network yet"
            scan(force: true)
            return st
        }
        guard let c = Conn(host: h, port: p, connectTimeout: 5, ioTimeout: 1800),
              let code = c.request(method: "POST", host: h, path: "/v1/raw", body: body, contentType: "application/octet-stream")
        else {
            st.error = "cannot reach the console at \(h):\(p)"
            update { $0.reachable = false }
            scan(force: true)
            setLast(nil, nil)
            return st
        }
        if code != 200 {
            st.error = "console HTTP \(code): \(String(decoding: c.readAll(limit: 300), as: UTF8.self))"
            return st
        }
        var t0: Date?
        while let line = c.readLine() {
            let kind = line.prefix(1)
            let rest = line.count > 2 ? String(line.dropFirst(2)) : ""
            let f = rest.split(separator: " ")
            if kind == "c", let n = f.first.flatMap({ Int($0) }) {
                st.cached = n
            } else if kind == "p", f.count >= 2 {
                st.prefillSeconds = Double(f[1]) ?? 0
                update { $0.phase = "writing" }
            } else if kind == "t" {
                let toks = f.compactMap { Int($0) }
                if t0 == nil { t0 = Date() }
                gen.append(contentsOf: toks)
                onTokens(toks)
                let el = Date().timeIntervalSince(t0!)
                let n = gen.count
                if el > 0.25 { update { $0.liveTokens = n; $0.liveTokS = Double(n) / el } } else { update { $0.liveTokens = n } }
                if cancelled() { st.finish = "cancel"; break }
            } else if kind == "d", f.count >= 3 {
                st.finish = String(f[0])
                st.generated = Int(f[1]) ?? gen.count
                st.decodeSeconds = Double(f[2]) ?? 0
                break
            } else if kind == "e" {
                st.error = "console: " + rest
                if let r = rest.range(of: "does not fit the context ("),   // learn the console's real context
                   let n = Int(rest[r.upperBound...].prefix { $0.isNumber }), n > 0 { contextLimit = n }
                break
            }
        }
        if st.finish == "error" && st.error == nil && st.generated == 0 && gen.isEmpty {
            st.error = "the console closed the connection"
        }
        // what the console has read: the prompt and every generated token except a final stop token
        let read = (gen.last.map { stops.contains($0) } ?? false) ? Array(gen.dropLast()) : gen
        if st.error == nil && (st.finish == "stop" || st.finish == "length") {
            setLast(text + model.decode(read), ids + read)
        } else {
            setLast(nil, nil)
        }
        return st
    }

    func recordRequest(_ st: GenStats, calls: Int) {
        let tps = st.decodeSeconds > 0 ? Double(st.generated) / st.decodeSeconds : 0
        let line = "prompt \(st.prompt) (\(st.cached) cached, read in \(String(format: "%.1f", st.prefillSeconds)) s), " +
            "\(st.generated) new" + (tps > 0 ? String(format: " at %.1f tok/s", tps) : "") + ", \(st.finish)" +
            (calls > 0 ? ", \(calls) tool call\(calls == 1 ? "" : "s")" : "") + (st.error.map { ", ERROR \($0)" } ?? "")
        log(line)
        update {
            $0.lastRequest = line
            $0.requests += 1
            $0.tokensIn += st.prompt
            $0.tokensCached += st.cached
            $0.tokensOut += st.generated
            if tps > 0 { $0.liveTokS = tps }
        }
    }
}
