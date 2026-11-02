import SwiftUI

struct SetupView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingController
    @EnvironmentObject var lang: LanguageManager
    @State private var isPairing = false
    @State private var showRiskyWarning = false

    var body: some View {
        NavigationView {
            Form {
                languageSection
                pairingSection
                tunnelSection
                catalogSection
                riskyMovesSection
                recoverySection
                iconCacheSection
            }
            .navigationTitle("Readipa " + lang("setup"))
            .alert(lang("enable.risky.moves"), isPresented: $showRiskyWarning) {
                Button(lang("cancel"), role: .cancel) { state.allowRiskyMoves = false }
                Button(lang("i.understand"), role: .destructive) { state.allowRiskyMoves = true }
            } message: {
                Text(lang("risky.moves.explain"))
            }
        }
    }

    private var languageSection: some View {
        Section {
            Picker(lang("language"), selection: $lang.language) {
                ForEach(AppLanguage.allCases) { l in
                    Text(l.displayName).tag(l)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var pairingSection: some View {
        Section {
            HStack {
                Text(lang("status"))
                Spacer()
                Text(state.hasPairingFile ? lang("paired") : lang("not.paired"))
                    .foregroundStyle(state.hasPairingFile ? Color.green : Color.red)
                    .bold()
            }
            if state.hasPairingFile {
                Text(PairingStore.fileName).font(.caption).foregroundStyle(.secondary)
                Text(lang("stored.in.documents.keychain"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button(lang("start.pairing")) {
                isPairing = true
                Task {
                    do {
                        let path = try await pairing.startAndWait()
                        PairingController.syncCanonicalPairingFile(from: path)
                        state.refreshPairingFile()
                        state.logLine(lang("pairing.succeeded"))
                    } catch {
                        state.logLine("\(lang("pairing.failed")): \(error.localizedDescription)")
                    }
                    isPairing = false
                }
            }
            .readipaGlassButton(prominent: true)
            .disabled(isPairing || pairing.running)

            if isPairing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(lang("waiting.approve")).font(.caption)
                }
            }
            if let pin = pairing.pairingPIN {
                HStack(spacing: 12) {
                    Text(pin)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    Text(lang("enter.in.settings"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            if !state.liveActivitiesEnabled {
                Text(lang("live.activities.off"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Button(lang("delete.pairing"), role: .destructive) {
                PairingController.deleteStoredPairingCredentials()
                state.refreshPairingFile()
            }
        } header: {
            Text(lang("pairing"))
        } footer: {
            Text(pairing.pairingStatus).font(.caption2)
        }
    }

    private var tunnelSection: some View {
        Section {
            TextField(lang("device.ip"), text: $state.deviceIP)
                .keyboardType(.decimalPad)
                .autocapitalization(.none)

            let summary = NetworkStatus.summarize(deviceIP: state.deviceIP)
            HStack(spacing: 8) {
                StatusChip(title: "tunnel", value: summary.vpn ? "up" : "down", ok: summary.vpn)
                StatusChip(title: "wi-fi", value: summary.wifi ? "up" : "down", ok: summary.wifi)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))

            Button(lang("test.tunnel")) { state.testTunnel() }
                .disabled(state.isTestingTunnel)
            if state.isTestingTunnel { ProgressView() }

            ForEach(state.tunnelResults) { result in
                HStack {
                    Text(result.host).font(.caption.monospaced())
                    Spacer()
                    Text(result.summary)
                        .font(.caption2)
                        .foregroundStyle(result.ok ? Color.green : Color.secondary)
                }
            }
            let hint = TunnelProbe.hint(for: state.tunnelResults)
            if !hint.isEmpty {
                Text(hint).font(.caption2).foregroundStyle(.orange)
            }
        } header: {
            Text(lang("tunnel"))
        } footer: {
            Text(lang("tunnel.checks")).font(.caption2)
        }
    }

    private var catalogSection: some View {
        Section {
            Button(lang("load.app.catalog")) { state.loadCatalog() }
                .disabled(!state.hasPairingFile)
            if state.isLoadingCatalog { ProgressView() }
            if let e = state.catalogError {
                Text(e).foregroundStyle(.red).font(.caption).textSelection(.enabled)
            }
        } header: {
            Text(lang("catalog"))
        }
    }

    private var riskyMovesSection: some View {
        Section {
            Toggle(lang("allow.risky.moves"), isOn: Binding(
                get: { state.allowRiskyMoves },
                set: { newValue in
                    if newValue {
                        showRiskyWarning = true
                    } else {
                        state.allowRiskyMoves = false
                    }
                }
            ))
            if state.allowRiskyMoves {
                Label(lang("risky.moves.on"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(lang("airlift.move.mode"))
        } footer: {
            Text(lang("risky.moves.needed")).font(.caption2)
        }
    }

    private var recoverySection: some View {
        Section {
            NavigationLink(destination: RecoveryView()) {
                HStack {
                    Label(lang("recovery"), systemImage: "arrow.uturn.backward.circle")
                    Spacer()
                    if !state.leftovers.isEmpty {
                        Text("\(state.leftovers.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if state.needsRecoveryCheck {
                Label("A previous operation may have been interrupted",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(lang("recovery"))
        } footer: {
            Text("Temporary items Readipa left in /var/mobile/Media. Nothing is ever deleted "
                 + "automatically.")
                .font(.caption2)
        }
    }

    private var iconCacheSection: some View {
        Section {
            Button(lang("gate.reset")) {
                UserDefaults.standard.set(false, forKey: LaunchGateView.skipKey)
                state.logLine("The start-up warning will show again next launch")
            }
            Button(lang("refresh.icons")) {
                IconStore.shared.clearCache()
                state.logLine("Icon cache cleared — icons reload as you scroll")
            }
        } header: {
            Text(lang("icons"))
        } footer: {
            Text("App icons come from SpringBoard and are cached locally.")
                .font(.caption2)
        }
    }
}
