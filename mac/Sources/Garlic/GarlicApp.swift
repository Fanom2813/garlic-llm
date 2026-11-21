// Garlic for Mac: the PS4 (Garlic Server) as a local OpenAI / Anthropic API for coding agents, from the menu bar.
import AppKit
import GarlicCore
import ServiceManagement
import SwiftUI

@main
struct GarlicApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(app)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: app.snap.reachable ? (app.snap.busy ? "bolt.horizontal.circle.fill" : "circle.hexagongrid.fill")
                    : "circle.hexagongrid")
                if app.snap.busy, app.snap.liveTokS > 0 { Text(String(format: "%.0f", app.snap.liveTokS)) }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppModel: ObservableObject {
    @Published var snap = Snapshot()
    @Published var serverError: String?
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    let backend: Backend
    let api: API
    var server: HTTPServer?
    let port: UInt16
    var lastPublish = Date.distantPast
    var pending = false

    init() {
        let d = UserDefaults.standard
        port = UInt16(d.integer(forKey: "port") == 0 ? 8000 : d.integer(forKey: "port"))
        var dirs: [URL] = []
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Garlic/models")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        dirs.append(support)
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("models")) }
        let fixed = d.string(forKey: "ps4")   // (optional: a fixed address, defaults write local.garlic.mac ps4 1.2.3.4)
        backend = Backend(modelDirs: dirs, fixedHost: fixed?.isEmpty == false ? fixed : nil)
        api = API(backend: backend)
        backend.onChange = { [weak self] s in self?.publish(s) }
        backend.log("Garlic for Mac; models: " + backend.availableModels().joined(separator: ", "))
        backend.start()
        startServer()
    }

    // (at most ~10 updates a second to the menu)
    func publish(_ s: Snapshot) {
        DispatchQueue.main.async {
            let now = Date()
            if now.timeIntervalSince(self.lastPublish) >= 0.1 || !s.busy {
                self.lastPublish = now
                self.snap = s
            } else if !self.pending {
                self.pending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.pending = false
                    self.snap = self.backend.snap
                    self.lastPublish = Date()
                }
            }
        }
    }

    func startServer() {
        do {
            let s = try HTTPServer(port: port, localOnly: true) { [api] req, r in api.handle(req, r) }
            s.start { [weak self] err in
                DispatchQueue.main.async {
                    self?.serverError = err
                    if let err { self?.backend.log("API server: \(err)") } else {
                        self?.backend.log("API on http://127.0.0.1:\(self?.port ?? 0)/v1 (OpenAI) and http://127.0.0.1:\(self?.port ?? 0) (Anthropic)")
                    }
                }
            }
            server = s
        } catch {
            serverError = "\(error)"
        }
    }

    var openAIURL: String { "http://127.0.0.1:\(port)/v1" }
    var anthropicURL: String { "http://127.0.0.1:\(port)" }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            backend.log("open at login: \(error.localizedDescription)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}
