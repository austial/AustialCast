import SwiftUI
import AustialCastCore

struct MenuView: View {
    @ObservedObject var model: AppModel
    @State private var showManual = false
    @State private var showPaired = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.hasPermission { permissionBanner }

            if model.isStreaming {
                streamingCard
            } else if model.isCasting {
                ProgressView().controlSize(.small)
            } else if let req = model.pinRequest {
                pinCard(req)
            } else {
                receiverList
            }

            Divider()
            sourceSection
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 360)
        .task { await model.refreshSources() }
    }

    // MARK: sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.menuBarSymbol)
                .font(.title2)
                .foregroundStyle(model.isStreaming ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("AustialCast").font(.headline)
                Text(model.statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AustialCast needs permission to record your screen.").font(.callout)
            Button("Open Privacy Settings…") { model.requestPermission() }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.15)))
    }

    private var streamingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(String(format: "%.0f fps", model.stats.fps), systemImage: "speedometer")
                Spacer()
                Label(String(format: "%.1f Mbit/s", model.stats.bitrateKbps / 1000), systemImage: "arrow.up.right")
                Spacer()
                Label(model.stats.rttMs.map { String(format: "%.0f ms", $0) } ?? "– ms", systemImage: "timer")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if model.stats.droppedFrames > 0 {
                Text("Network is slow: \(model.stats.droppedFrames) frames skipped, quality adapts automatically.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill") { model.togglePause() }
                Button("Stop casting", systemImage: "stop.fill", role: .destructive) { model.stop() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12)))
    }

    private func pinCard(_ req: PinRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(req.wrongPin ? "Wrong PIN — a new PIN is shown on \(req.name)." : "Enter the PIN shown on \(req.name)")
                .font(.callout)
                .foregroundStyle(req.wrongPin ? .orange : .primary)
            HStack {
                TextField("6-digit PIN", text: $model.pinInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.title3, design: .monospaced))
                    .frame(width: 140)
                    .onSubmit { model.submitPin() }
                    .onChange(of: model.pinInput) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(6))
                        if digits != new { model.pinInput = digits }
                    }
                Button("Cast") { model.submitPin() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.pinInput.count != 6)
                Button("Cancel") { model.cancelPin() }
            }
            Text("You only need the PIN once. This Mac is remembered afterwards.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var receiverList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cast to").font(.subheadline).foregroundStyle(.secondary)
            if model.receivers.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for TVs running AustialCast on this network…").font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(model.receivers) { r in
                Button {
                    model.connect(to: r)
                } label: {
                    HStack {
                        Image(systemName: model.paired.contains { $0.id == r.id } ? "tv.badge.wifi" : "tv")
                        Text(r.name)
                        Spacer()
                        if model.paired.contains(where: { $0.id == r.id }) {
                            Text("paired").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
            }
            DisclosureGroup("Enter TV address manually", isExpanded: $showManual) {
                HStack {
                    TextField("192.168.1.20", text: $model.manualHost)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.connectManual() }
                    Button("Connect") { model.connectManual() }.disabled(model.manualHost.isEmpty)
                }
                .padding(.top, 4)
            }
            .font(.callout)
            .onAppear { if model.manualHost.isEmpty { model.manualHost = model.lastHost } }
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Share", selection: Binding(get: { model.sourceKind }, set: { model.sourceKind = $0 })) {
                ForEach(SourceKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(model.isCasting)

            if model.sourceKind == .display {
                Picker("Screen", selection: $model.displayId) {
                    ForEach(model.displays) { d in Text("\(d.name) (\(d.width)×\(d.height))").tag(Int(d.id)) }
                }
                .disabled(model.isCasting || model.displays.isEmpty)
            } else {
                Picker("Window", selection: $model.windowId) {
                    ForEach(model.windows) { w in Text("\(w.appName) — \(w.title)").lineLimit(1).tag(Int(w.id)) }
                }
                .disabled(model.isCasting || model.windows.isEmpty)
            }

            Picker("Quality", selection: Binding(get: { model.preset }, set: { model.preset = $0 })) {
                ForEach(QualityPreset.all) { Text($0.name).tag($0) }
            }
            .disabled(model.isCasting)

            Toggle("Share Mac audio", isOn: $model.captureAudio).disabled(model.isCasting)
            Toggle("Show mouse pointer", isOn: $model.showCursor).disabled(model.isCasting)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.paired.isEmpty {
                DisclosureGroup("Paired TVs (\(model.paired.count))", isExpanded: $showPaired) {
                    ForEach(model.paired) { p in
                        HStack {
                            Text(p.name)
                            Spacer()
                            Button("Forget") { model.forget(p.id) }.buttonStyle(.link)
                        }
                    }
                }
                .font(.callout)
            }
            Toggle("Launch AustialCast at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .font(.callout)
            HStack {
                Button("Refresh") { Task { await model.refreshSources() } }.buttonStyle(.link)
                Spacer()
                Button("Quit AustialCast") {
                    model.stop()
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
    }
}
