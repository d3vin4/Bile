import SwiftUI

struct SetupView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingController
    @State private var isPairing = false
    @State private var recoverTarget: FileEntry? = nil
    @State private var recoverPath = ""
    @State private var showRecover = false

    var body: some View {
        NavigationView {
            Form {
                pairingSection
                tunnelSection
                catalogSection
                riskyMovesSection
                recoverySection
                aboutSection
            }
            .navigationTitle("Readipa Setup")
            .sheet(isPresented: $showRecover) { recoverSheet }
        }
    }

    // MARK: - Sections

    private var pairingSection: some View {
        Section {
            HStack {
                Text("Status")
                Spacer()
                Text(state.hasPairingFile ? "Paired" : "Not paired")
                    .foregroundStyle(state.hasPairingFile ? .green : .red)
                    .bold()
            }
            if state.hasPairingFile {
                Text(PairingStore.fileName).font(.caption).foregroundStyle(.secondary)
                Text("Stored in Documents and the Keychain — relaunching or reinstalling keeps it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("Start Pairing") {
                isPairing = true
                Task {
                    do {
                        let path = try await pairing.startAndWait()
                        PairingController.syncCanonicalPairingFile(from: path)
                        state.refreshPairingFile()
                        state.logLine("Pairing succeeded")
                    } catch {
                        state.logLine("Pairing failed: \(error.localizedDescription)")
                    }
                    isPairing = false
                }
            }
            .readipaGlassButton(prominent: true)
            .disabled(isPairing || pairing.running)

            if isPairing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting… approve the request in Settings").font(.caption)
                }
            }
            if let pin = pairing.pairingPIN {
                HStack(spacing: 12) {
                    Text(pin)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    VStack(alignment: .leading) {
                        Text("Enter in Settings › Privacy & Security ›")
                        Text("Developer Mode › Pair with Readipa")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            if !state.liveActivitiesEnabled {
                Text("Live Activities are off for Readipa, so the PIN stays on this screen only. "
                     + "Enable Settings › Readipa › Live Activities to keep it on the Lock Screen.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Button("Delete Pairing Credentials", role: .destructive) {
                PairingController.deleteStoredPairingCredentials()
                state.refreshPairingFile()
            }
        } header: {
            Text("Pairing")
        } footer: {
            Text(pairing.pairingStatus).font(.caption2)
        }
    }

    private var tunnelSection: some View {
        Section {
            TextField("Device IP", text: $state.deviceIP)
                .keyboardType(.decimalPad)
                .autocapitalization(.none)

            let summary = NetworkStatus.summarize(deviceIP: state.deviceIP)
            HStack(spacing: 8) {
                StatusChip(title: "tunnel iface", value: summary.vpn ? "up" : "down", ok: summary.vpn)
                StatusChip(title: "wi-fi", value: summary.wifi ? "up" : "down", ok: summary.wifi)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))

            Button("Test tunnel") { state.testTunnel() }
                .disabled(state.isTestingTunnel)
            if state.isTestingTunnel { ProgressView() }

            ForEach(state.tunnelResults) { result in
                HStack {
                    Text(result.host).font(.caption.monospaced())
                    Spacer()
                    Text(result.summary)
                        .font(.caption2)
                        .foregroundStyle(result.ok ? .green : .secondary)
                }
            }

            Text(summary.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        } header: {
            Text("Tunnel")
        } footer: {
            Text("The AirLift pipeline needs a loopback VPN (LocalDevVPN, StosVPN, SideStore WireGuard). "
                 + "Test tunnel dials the RSD port 49152 and lockdownd 62078 on every candidate address.")
            .font(.caption2)
        }
    }

    private var catalogSection: some View {
        Section {
            Button("Load App Catalog") { state.loadCatalog() }
                .disabled(!state.hasPairingFile)
            if state.isLoadingCatalog { ProgressView() }
            if let e = state.catalogError {
                Text(e).foregroundStyle(.red).font(.caption).textSelection(.enabled)
            }
        } header: {
            Text("Catalog")
        }
    }

    private var riskyMovesSection: some View {
        Section {
            Toggle("Allow risky moves", isOn: $state.allowRiskyMoves)
            Text("Containers that block direct access can only be listed or exported by temporarily "
                 + "relocating a folder to Media. Every relocation is verified and always moved back, "
                 + "but it touches live app data — keep this off unless you need App Group access.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } header: {
            Text("AirLift move mode")
        }
    }

    private var recoverySection: some View {
        Section {
            Button("Scan for leftover files") { state.scanLeftovers() }
                .disabled(!state.hasPairingFile)
            if state.leftovers.isEmpty {
                Text("No leftovers").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(state.leftovers) { item in
                    Button {
                        recoverTarget = item
                        recoverPath = ""
                        showRecover = true
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.name).font(.caption.monospaced())
                            Text("\(FileEntry.prettySize(item.size)) · tap to restore")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("Files Readipa moved out of a container but could not move back stay in "
                 + "/var/mobile/Media and are listed here. Nothing is ever deleted automatically.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } header: {
            Text("Recovery")
        }
    }

    private var aboutSection: some View {
        Section {
            HStack { Text("Scope"); Spacer(); Text("Data Containers + App Groups").font(.caption) }
            HStack { Text("Engine"); Spacer(); Text(state.bridgeMode.isEmpty ? "—" : state.bridgeMode).font(.caption) }
            HStack { Text("Build"); Spacer(); Text(appVersion).font(.caption) }
        } header: {
            Text("About")
        } footer: {
            Text("Readipa only operates inside /var/mobile/Containers/Data/Application and "
                 + "/var/mobile/Containers/Shared/AppGroup. Build adopts Liquid Glass on iOS 26+.")
            .font(.caption2)
        }
    }

    private var recoverSheet: some View {
        NavigationView {
            Form {
                Section("Leftover") {
                    Text(recoverTarget?.name ?? "").font(.caption.monospaced())
                }
                Section("Restore into") {
                    if let c = state.selectedContainer {
                        Text(c.name).font(.caption)
                        TextField("destination folder (empty = container root)", text: $recoverPath)
                            .autocapitalization(.none)
                    } else {
                        Text("Open a container in the Apps tab first — the leftover is restored into "
                             + "the container you are currently browsing.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Button("Restore") {
                        if let item = recoverTarget {
                            state.recoverLeftover(item, intoFolder: recoverPath)
                        }
                        showRecover = false
                    }
                    .disabled(state.selectedContainer == nil)
                    Button("Cancel") { showRecover = false }
                }
            }
            .navigationTitle("Restore leftover")
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
