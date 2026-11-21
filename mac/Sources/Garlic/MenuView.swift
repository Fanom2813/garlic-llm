import AppKit
import GarlicCore
import SwiftUI

struct MenuView: View {
    @EnvironmentObject var app: AppModel
    @State private var showLog = false

    var body: some View {
        let s = app.snap
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(s.reachable ? Color.green : (s.host == nil ? Color.gray : Color.orange)).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.reachable ? "PS4 connected" : (s.host == nil ? "Looking for the PS4…" : "PS4 not answering"))
                        .font(.headline)
                    Text(s.host.map { "\($0):\(s.port)" + (s.how.isEmpty ? "" : " · found by \(s.how)") } ?? "listening for its announcement")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { app.backend.scan(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Look for the PS4 again")
            }

            if !s.consoleModel.isEmpty {
                LabeledContent("Model", value: s.consoleModel).font(.callout)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    if s.busy {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(s.phase.capitalized(with: nil)).font(.callout)
                            Spacer()
                            if s.liveTokS > 0 {
                                Text(String(format: "%.1f tok/s", s.liveTokS)).font(.system(.callout, design: .monospaced))
                            }
                        }
                        if s.liveTokens > 0 { Text("\(s.liveTokens) tokens").font(.caption).foregroundStyle(.secondary) }
                    } else if s.requests == 0 {
                        Text("No requests yet").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(s.lastRequest).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if s.requests > 0 {
                        Text("\(s.requests) requests · \(s.tokensIn) prompt tokens (\(s.tokensCached) from the cache) · \(s.tokensOut) written")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 4) {
                endpoint("OpenAI", app.openAIURL)
                endpoint("Anthropic", app.anthropicURL)
                if let e = app.serverError { Text("API server: \(e)").font(.caption).foregroundStyle(.red) }
            }

            DisclosureGroup("Log", isExpanded: $showLog) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(s.log.suffix(120).enumerated()), id: \.offset) { i, l in
                                Text(l).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).id(i)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 160)
                    .onAppear { proxy.scrollTo(min(119, s.log.count - 1)) }
                }
            }
            .font(.callout)

            Divider()
            Toggle("Open at login", isOn: Binding(get: { app.openAtLogin }, set: { app.setOpenAtLogin($0) }))
                .font(.callout)
            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    func endpoint(_ name: String, _ url: String) -> some View {
        HStack {
            Text(name).font(.caption).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
            Text(url).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy")
        }
    }
}
