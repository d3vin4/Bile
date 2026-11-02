import Foundation
import ActivityKit
import AirliftFFI

/// Drives the RPPairing host: requests Local Network, keeps the app alive while
/// the user approves the PIN in Settings, advertises the service over Bonjour,
/// and runs `al_pairing_run_host` off the main thread.
@MainActor
final class PairingController: ObservableObject {

    static let shared = PairingController()

    private let hostName = "Readipa"
    private let hostModel = "Mac17,7"   // device sees a Mac-like pairing host
    private let bindAddress = "0.0.0.0"

    private var netService: NetService?
    private let localNetwork = LocalNetworkAuthorization()
    private let keepAlive = KeepAlive()
    private var pairingActivity: Activity<PairingActivityAttributes>? = nil

    @Published private(set) var running = false
    @Published var pairingStatus: String = "idle"
    @Published var pairingPIN: String? = nil

    /// Path to the pairing file that was actively found or created.
    static var customPairingFilePath: String? = nil

    /// Persisted altIRK keeps the host identity stable across pairings so a
    /// device that has already paired recognises this host.
    nonisolated private static let altIRKKey = "readipa.pairingHostAltIRK"
    nonisolated private static var storedAltIRK: String {
        get { UserDefaults.standard.string(forKey: altIRKKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: altIRKKey) }
    }

    private var pairContinuation: CheckedContinuation<String, Error>?

    // MARK: - Public API

    enum PairingError: LocalizedError {
        case busy
        case localNetworkDenied
        case zeroBytes
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .busy: return "Pairing is already in progress."
            case .localNetworkDenied: return "Local Network permission is off. Enable it in Settings › Readipa › Local Network."
            case .zeroBytes: return "Pairing produced an empty file. Approve the pairing request, then try again."
            case let .failed(msg): return msg
            }
        }
    }

    /// Stores the pairing file in Documents *and* the Keychain so a relaunch
    /// (or a reinstall that wipes the container) never loses the pairing.
    @discardableResult
    static func syncCanonicalPairingFile(from sourcePath: String) -> String {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: sourcePath)) {
            _ = PairingStore.write(data)
        }
        return PairingStore.canonicalURL.path
    }

    /// Restores the credentials from the Keychain if the file is missing.
    /// Called on every launch before the UI reports "not paired".
    @discardableResult
    static func restorePairingIfNeeded() -> Bool {
        PairingStore.read() != nil
    }

    /// Deletes every credential copy created or adopted by Readipa.
    static func deleteStoredPairingCredentials() {
        PairingStore.deleteAll()
        customPairingFilePath = nil
        storedAltIRK = ""
    }

    /// Path the pairing file is written to and read from.
    static func pairingFilePath() -> String {
        // Touch the store first so a Keychain-only pairing is restored.
        _ = PairingStore.read()
        return PairingStore.canonicalURL.path
    }

    /// Start the host and resolve with the pairing-file path, or throw.
    func startAndWait() async throws -> String {
        // If already running, cancel previous to allow clean restart
        if running {
            softCancel()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return try await withCheckedThrowingContinuation { cont in
            pairContinuation = cont
            start()
        }
    }

    func softCancel() {
        endPairingActivity()
        stopAdvertising()
        keepAlive.stopAll()
        running = false
        pairingPIN = nil
        pairingStatus = "Cancelled"
        resolve(.failure(CancellationError()))
    }

    private func resolve(_ result: Result<String, Error>) {
        guard let cont = pairContinuation else { return }
        pairContinuation = nil
        cont.resume(with: result)
    }

    func start() {
        stopAdvertising()
        keepAlive.stopAll()
        running = true
        pairingPIN = nil
        pairingStatus = "Starting local host…"

        // Show the Live Activity from the very first moment: the PIN arrives a
        // few seconds later and is pushed into the same activity.
        startPairingActivity(pin: nil)

        Task {
            _ = await localNetwork.request()
            guard running else { return }

            keepAlive.startAudio()
            pairingStatus = "Broadcasting… open Settings to pair"
            updatePairingActivity(status: "Waiting for Settings › Developer Mode…")
            runHost()
        }
    }

    // MARK: - Private

    private func runHost() {
        let bind = bindAddress
        let name = hostName
        let model = hostModel
        let outPath = Self.pairingFilePath()
        let altIRK = Self.storedAltIRK
        nonisolated(unsafe) let ctx = UnsafeMutableRawPointer(
            Unmanaged.passRetained(self).toOpaque()
        )

        DispatchQueue.global(qos: .userInitiated).async {
            var result = ALPairResult()
            let rc = bind.withCString { bindC in
                name.withCString { nameC in
                    model.withCString { modelC in
                        outPath.withCString { outC in
                            altIRK.withCString { irkC in
                                al_pairing_run_host(
                                    bindC, 0, nameC, modelC, outC, irkC,
                                    pairReadyCallback, pairPinCallback, ctx, &result)
                            }
                        }
                    }
                }
            }

            let outcome: Outcome
            if rc == 0 {
                let issued = cStr(result.host_alt_irk_hex)
                if !issued.isEmpty { Self.storedAltIRK = issued }
                let devName = cStr(result.device_name)
                let filePath = cStr(result.pairing_file_path)
                outcome = .success(
                    name: devName.isEmpty ? "iPhone" : devName,
                    path: filePath.isEmpty ? outPath : filePath
                )
            } else {
                let msg = cStr(result.error)
                outcome = .failure(msg.isEmpty ? "pairing failed (rc=\(rc))" : msg)
            }
            al_pairing_result_free(&result)

            DispatchQueue.main.async {
                Unmanaged<PairingController>.fromOpaque(ctx).release()
                self.finish(outcome)
            }
        }
    }

    private enum Outcome {
        case success(name: String, path: String)
        case failure(String)
    }

    private func finish(_ outcome: Outcome) {
        endPairingActivity()
        stopAdvertising()
        // Keep background alive for 5s so iOS doesn't kill the app before user returns from Settings
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.keepAlive.stopAll()
        }
        running = false
        pairingPIN = nil

        switch outcome {
        case let .success(name, path):
            let canonical = Self.syncCanonicalPairingFile(from: path)
            let size = (try? FileManager.default.attributesOfItem(atPath: canonical)[.size] as? Int) ?? 0
            if size == 0 {
                pairingStatus = "Failed: empty pairing file"
                resolve(.failure(PairingError.zeroBytes))
            } else {
                pairingStatus = "Paired: \(name) (\(size)B)"
                resolve(.success(canonical))
            }
        case let .failure(message):
            pairingStatus = "Failed: \(message)"
            resolve(.failure(PairingError.failed(message)))
        }
    }


    // MARK: Bonjour advertising

    fileprivate func startAdvertising(serviceID: String, port: Int32, txt: [String: Data]) {
        stopAdvertising()
        let service = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: serviceID,
            port: port
        )
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        netService = service
        pairingStatus = "Advertising — open Settings › Privacy & Security › Developer Mode"
    }

    fileprivate func presentPin(_ pin: String) {
        pairingPIN = pin
        pairingStatus = "Enter PIN \(pin) in Settings › Privacy & Security › Developer Mode › Pair with Readipa"
        updatePairingActivity(pin: pin, status: "Enter this PIN in Settings › Developer Mode")
    }

    // MARK: - Live Activity

    nonisolated static var liveActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Requests the Live Activity. Safe to call twice — the second call updates
    /// the existing one instead of creating another.
    private func startPairingActivity(pin: String?) {
        guard Self.liveActivitiesEnabled else {
            PairingController.log("Live Activities are disabled for Readipa in Settings › Readipa › Live Activities")
            return
        }
        if pairingActivity != nil {
            updatePairingActivity(pin: pin, status: "Waiting for Settings › Developer Mode…")
            return
        }
        let attributes = PairingActivityAttributes(deviceName: "Readipa")
        let state = PairingActivityAttributes.ContentState(
            pin: pin ?? "······",
            status: "Waiting for Settings › Developer Mode…"
        )
        do {
            pairingActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            PairingController.log("Live Activity started (\(pairingActivity?.id ?? "?")) ✅")
        } catch {
            PairingController.log("Live Activity could not start: \(error.localizedDescription)")
        }
    }

    private func updatePairingActivity(pin: String? = nil, status: String) {
        guard let activity = pairingActivity else {
            // Not started yet (e.g. the PIN arrived first): start it now.
            startPairingActivity(pin: pin)
            return
        }
        let next = PairingActivityAttributes.ContentState(
            pin: pin ?? activity.content.state.pin,
            status: status
        )
        Task {
            await activity.update(.init(state: next, staleDate: nil))
        }
    }

    private func endPairingActivity() {
        guard let activity = pairingActivity else { return }
        pairingActivity = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    nonisolated private static func log(_ message: String) {
        DispatchQueue.main.async { AppState.shared.logLine("pairing: \(message)") }
    }

    private func stopAdvertising() {
        netService?.stop()
        netService = nil
    }
}

// MARK: - C callbacks

private let pairReadyCallback: ALPairReadyCb = { ctx, serviceID, port, keys, vals, count in
    guard let ctx = ctx, let serviceID = serviceID else { return }
    let controller = Unmanaged<PairingController>.fromOpaque(ctx).takeUnretainedValue()
    let id = String(cString: serviceID)

    var txt: [String: Data] = [:]
    if let keys = keys, let vals = vals {
        for i in 0..<Int(count) {
            guard let k = keys[i], let v = vals[i] else { continue }
            txt[String(cString: k)] = Data(String(cString: v).utf8)
        }
    }
    DispatchQueue.main.async {
        controller.startAdvertising(serviceID: id, port: Int32(port), txt: txt)
    }
}

private let pairPinCallback: ALPairPinCb = { pin, ctx in
    guard let ctx = ctx, let pin = pin else { return }
    let controller = Unmanaged<PairingController>.fromOpaque(ctx).takeUnretainedValue()
    let pinString = String(cString: pin)
    DispatchQueue.main.async {
        controller.presentPin(pinString)
    }
}

private func cStr(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
    guard let ptr = ptr else { return "" }
    return String(cString: ptr)
}

