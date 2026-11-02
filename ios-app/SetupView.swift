import SwiftUI

struct SetupView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingController
    @EnvironmentObject var lang: LanguageManager
    @State private var isPairing = false
    @State private var recoverTarget: LeftoverEntry? = nil
    @State private var recoverPath = ""
    @State private var showRecover = false
    @State private var deleteTarget: LeftoverEntry? = nil
    @State private var showDeleteLeftover = false
    @State private var showRiskyWarning = false
    @State private var showCleanupConfirm = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker(lang("language"), selection: $lang.language) {
                        ForEach(AppLanguage.allCases) { l in
                            Text(l.displayName).tag(l)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                pairingSection
                tunnelSection
                catalogSection
                riskyMovesSection
                recoverySection
            }
            .navigationTitle("Readipa " + lang("setup"))
            .sheet(isPresented: $showRecover) { recoverSheet }
            .alert("Enable risky moves?", isPresented: $showRiskyWarning) {
                Button("Cancel", role: .cancel) { state.allowRiskyMoves = false }
                Button("I understand", role: .destructive) { state.allowRiskyMoves = true }
            } message: {
                Text("Containers that block direct access are only readable by temporarily moving a "
                     + "folder out of the app into /var/mobile/Media and back.\n\n"
                     + "Readipa verifies every move and always puts the folder back, and if anything "
                     + "goes wrong it tells you exactly where the data is kept — but for those seconds "
                     + "the app really is missing that folder. Only enable this for App Groups you "
                     + "need to inspect.")
            }
            .confirmationDialog(
                "Delete “\(deleteTarget?.name ?? "")”?",
                isPresented: $showDeleteLeftover,
                titleVisibility: .visible
            ) {
                Button("Delete permanently", role: .destructive) {
                    if let t = deleteTarget { state.deleteLeftover(t) }
                    deleteTarget = nil
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: {
                Text(deleteTarget?.safeToRemove == true
                     ? "This leftover holds no data, so nothing is lost."
                     : "This leftover CONTAINS DATA. Deleting it cannot be undone.")
            }
            .confirmationDialog(
                "Remove empty leftovers?",
                isPresented: $showCleanupConfirm,
                titleVisibility: .visible
            ) {
                Button("Remove \(safeLeftoverCount) empty items", role: .destructive) {
                    state.cleanupLeftovers()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Only bridge links and empty folders are removed. Anything that still contains "
                     + "files is kept and stays listed.")
            }
        }
    }

    // MARK: - Pairing

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
                Text("Kept in Documents and the Keychain — relaunching keeps it.")
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
                    Text(lang("waiting.approve")).font(.caption)
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
            Text(lang("pairing"))
        } footer: {
            Text(pairing.pairingStatus).font(.caption2)
        }
    }

    // MARK: - Tunnel

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
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(lang("tunnel"))
        } footer: {
            Text("Checks RSD (49152) and lockdownd (62078) on 10.7.0.1 and 192.168.1.2. "
                 + "Start the loopback VPN (LocalDevVPN / StosVPN) before pairing.")
            .font(.caption2)
        }
    }

    // MARK: - Catalog

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

    // MARK: - Risky moves

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
                Label("Risky moves are ON — folders may be relocated for a few seconds.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(lang("airlift.move.mode"))
        } footer: {
            Text("Needed only for containers that refuse both listing and reading. "
                 + "Read-only access never relocates anything.")
            .font(.caption2)
        }
    }

    // MARK: - Recovery

    private var safeLeftoverCount: Int {
        state.leftovers.filter(\.safeToRemove).count
    }

    private var leftoverGroups: [(kind: String, items: [LeftoverEntry])] {
        Dictionary(grouping: state.leftovers, by: \.kind)
            .map { (kind: $0.key, items: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.kind < $1.kind }
    }

    private var recoverySection: some View {
        Section {
            HStack(spacing: 8) {
                Button(lang("scan")) { state.scanLeftovers() }
                    .disabled(!state.hasPairingFile)
                Spacer()
                if safeLeftoverCount > 0 {
                    Button("\(lang("clean.empty")) (\(safeLeftoverCount))") { showCleanupConfirm = true }
                        .foregroundStyle(.orange)
                }
            }

            if state.leftovers.isEmpty {
                Text(lang("nothing.to.recover")).font(.caption).foregroundStyle(.secondary)
            }

            ForEach(leftoverGroups, id: \.kind) { group in
                DisclosureGroup {
                    ForEach(group.items) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.isLink ? "link" : (item.isDir ? "folder" : "doc"))
                                .foregroundStyle(item.safeToRemove ? Color.secondary : Color.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("\(item.explain) · \(FileEntry.prettySize(item.size))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                Button(lang("restore.into")) {
                                    recoverTarget = item
                                    recoverPath = ""
                                    showRecover = true
                                }
                                Button("Delete…", role: .destructive) {
                                    deleteTarget = item
                                    showDeleteLeftover = true
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } label: {
                    HStack {
                        Text(group.kind)
                        Spacer()
                        Text("\(group.items.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(lang("recovery"))
        } footer: {
            Text("Temporary items Readipa left in /var/mobile/Media — usually bridge links and empty "
                 + "staging folders, which hold no data. “Clean empty” removes only those. "
                 + "Anything containing files stays until you delete it yourself.")
            .font(.caption2)
        }
    }

    private var recoverSheet: some View {
        NavigationView {
            Form {
                Section(lang("leftover")) {
                    Text(recoverTarget?.name ?? "").font(.caption.monospaced())
                    Text(recoverTarget?.explain ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Section(lang("restore.into")) {
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
                    Button(lang("restore")) {
                        if let item = recoverTarget {
                            state.recoverLeftover(item, intoFolder: recoverPath)
                        }
                        showRecover = false
                    }
                    .disabled(state.selectedContainer == nil)
                    Button(lang("cancel")) { showRecover = false }
                }
            }
            .navigationTitle(lang("restore.leftover"))
        }
    }
}
