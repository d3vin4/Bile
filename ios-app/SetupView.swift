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
                Section("Pairing") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(state.hasPairingFile ? "Paired ✅" : "Not paired")
                            .foregroundStyle(state.hasPairingFile ? .green : .red)
                    }
                    if state.hasPairingFile {
                        Text(state.pairingFileName).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Start Pairing") {
                        isPairing = true
                        Task {
                            do {
                                let path = try await pairing.startAndWait()
                                PairingController.syncCanonicalPairingFile(from: path)
                                state.refreshPairingFile()
                                state.logLine("Pairing succeeded: \(path)")
                            } catch {
                                state.logLine("Pairing failed: \(error.localizedDescription)")
                            }
                            isPairing = false
                        }
                    }
                    .disabled(isPairing || pairing.running)
                    if isPairing {
                        ProgressView("Pairing… approve PIN in Settings")
                    }
                    if let pin = pairing.pairingPIN {
                        Text("PIN: \(pin)").font(.title2.monospaced())
                    }
                    Button("Delete Pairing Credentials", role: .destructive) {
                        PairingController.deleteStoredPairingCredentials()
                        state.refreshPairingFile()
                    }
                }

                Section("Tunnel") {
                    TextField("Device IP", text: $state.deviceIP)
                        .keyboardType(.decimalPad)
                    let summary = NetworkStatus.summarize(deviceIP: state.deviceIP)
                    HStack { Text("VPN"); Spacer(); Text(summary.vpn ? "Up ✅" : "Down ❌").foregroundStyle(summary.vpn ? .green : .red) }
                    HStack { Text("Wi-Fi"); Spacer(); Text(summary.wifi ? "Up" : "Down") }
                    Text(summary.detail).font(.caption2).foregroundStyle(.secondary)
                }

                Section {
                    Button("Load App Catalog") { state.loadCatalog() }
                        .disabled(!state.hasPairingFile)
                    if state.isLoadingCatalog { ProgressView() }
                    if let e = state.catalogError { Text(e).foregroundStyle(.red).font(.caption) }
                }

                Section {
                    Toggle("Allow risky moves", isOn: $state.allowRiskyMoves)
                    Text("Containers that block direct access can only be listed by temporarily "
                         + "relocating a directory to Media. That moves live app data, so it is "
                         + "off by default. Leave it off unless you need App Group browsing.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("AirLift move mode")
                }

                Section {
                    Button("Scan for leftover files") { state.scanLeftovers() }
                        .disabled(!state.hasPairingFile)
                    if state.leftovers.isEmpty {
                        Text("No leftover files").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(state.leftovers) { item in
                            Button {
                                recoverTarget = item
                                recoverPath = ""
                                showRecover = true
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(item.name).font(.caption.monospaced())
                                    Text("\(item.size) bytes · tap to restore")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text("Files this app moved out of a container but could not move back remain in "
                         + "/var/mobile/Media and are listed here. Nothing is ever deleted "
                         + "automatically.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Recovery")
                }
            }
            .navigationTitle("Readipa Setup")
            .sheet(isPresented: $showRecover) {
                NavigationView {
                    Form {
                        Section("Leftover") {
                            Text(recoverTarget?.name ?? "")
                                .font(.caption.monospaced())
                        }
                        Section("Restore into") {
                            if let c = state.selectedContainer {
                                Text(c.name).font(.caption)
                                TextField("destination folder (e.g. Documents, or empty for the root)", text: $recoverPath)
                                    .autocapitalization(.none)
                            } else {
                                Text("Open a container in the Apps tab first — the leftover is "
                                     + "restored into the container you are currently browsing.")
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
        }
    }
}
