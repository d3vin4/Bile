import SwiftUI

struct SetupView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingController
    @State private var isPairing = false

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
            }
            .navigationTitle("Readipa Setup")
        }
    }
}
