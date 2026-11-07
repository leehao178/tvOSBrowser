import Foundation
import Network

/// Finds tvOS Browser over Bonjour and sends it pointer packets over UDP.
///
/// Packet format (one JSON object per datagram, protocol v1), matching
/// BrowserMotionInputController on the Apple TV:
///   {"type":"hello","name":"My iPhone"}             → Apple TV replies {"type":"welcome",...}
///   {"type":"motion","dyaw":0.01,"dpitch":-0.002}   radians turned since the previous packet
///   {"type":"scroll","dx":0,"dy":120}               scroll delta in points
///   {"type":"click"}                                primary action at the cursor
///   {"type":"back"}                                 same as the Siri Remote's Menu / Back button
///
/// The last Apple TV the user picked (a Bonjour name or a typed IP) is remembered and
/// reconnected to automatically on launch and when the app returns to the foreground.
final class PointerClient: ObservableObject {
    static let serviceType = "_tvbpointer._udp"
    static let defaultPort: UInt16 = 47800

    struct Device: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var status = "搜尋 Apple TV 中…"
    @Published private(set) var connectedName: String?
    @Published private(set) var targetName: String?
    @Published private(set) var packetsSent = 0

    var isConnected: Bool { connectedName != nil }

    private enum Keys {
        static let deviceName = "lastDeviceName"
        static let host = "lastHost"
    }

    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "remote.pointer.network")
    private var browser: NWBrowser?
    private var currentEndpoint: NWEndpoint?
    private var started = false
    // Only touched on `queue`.
    private var connection: NWConnection?
    private var welcomed = false
    private var sentCount = 0
    private var lastPublishedCount = 0

    /// The IP typed last time, if the user connected by IP rather than picking a found Apple TV.
    var savedHost: String? { defaults.string(forKey: Keys.host) }

    // MARK: - Lifecycle

    /// Starts Bonjour discovery and reconnects to the remembered Apple TV. Call once.
    func start() {
        guard !started else { return }
        started = true
        startBrowsing()
        if let host = savedHost {
            connect(host: host)
        }
    }

    /// Reopens the current connection, e.g. after the app was in the background.
    func reconnect() {
        guard started, let endpoint = currentEndpoint, let label = targetName else { return }
        open(endpoint: endpoint, label: label)
    }

    // MARK: - Discovery

    private func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: NWParameters())
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.publish { $0.status = "搜尋失敗：\(error)（請允許區域網路權限）" }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [Device] = results.compactMap { result in
                if case let .service(name, _, _, _) = result.endpoint {
                    return Device(name: name, endpoint: result.endpoint)
                }
                return nil
            }.sorted { $0.name < $1.name }
            self?.publish { client in
                client.devices = found
                let saved = client.defaults.string(forKey: Keys.deviceName)
                if !client.isConnected, let saved, client.targetName != saved,
                   let device = found.first(where: { $0.name == saved }) {
                    // The Apple TV picked last time is back: reconnect to it.
                    client.connect(to: device)
                } else if client.targetName == nil, found.count == 1, let device = found.first {
                    // Nothing chosen yet and only one Apple TV around: just use it.
                    client.connect(to: device)
                }
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    // MARK: - Connection

    func connect(to device: Device) {
        defaults.set(device.name, forKey: Keys.deviceName)
        defaults.removeObject(forKey: Keys.host)
        open(endpoint: device.endpoint, label: device.name)
    }

    func connect(host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let port = NWEndpoint.Port(rawValue: Self.defaultPort) else { return }
        defaults.set(trimmed, forKey: Keys.host)
        defaults.removeObject(forKey: Keys.deviceName)
        open(endpoint: .hostPort(host: NWEndpoint.Host(trimmed), port: port), label: trimmed)
    }

    private func open(endpoint: NWEndpoint, label: String) {
        currentEndpoint = endpoint
        targetName = label
        connectedName = nil
        status = "連線到 \(label)…"
        queue.async { [weak self] in
            guard let self else { return }
            self.connection?.cancel()
            self.welcomed = false
            let connection = NWConnection(to: endpoint, using: .udp)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                switch state {
                case .ready:
                    self.receive(on: connection)
                    self.sendHelloUntilWelcomed(on: connection)
                case .waiting(let error):
                    self.publish { $0.status = "等待網路：\(error)" }
                case .failed(let error):
                    self.publish { $0.status = "連線失敗：\(error)"; $0.connectedName = nil }
                default:
                    break
                }
            }
            self.connection = connection
            connection.start(queue: self.queue)
        }
    }

    /// UDP has no handshake, so keep saying hello until the Apple TV answers.
    private func sendHelloUntilWelcomed(on connection: NWConnection) {
        guard connection === self.connection, !welcomed else { return }
        send(["type": "hello", "name": deviceName()], on: connection)
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self, weak connection] in
            guard let self, let connection else { return }
            if !self.welcomed {
                self.publish { $0.status = "等待 Apple TV 回應…（App 要開著）" }
            }
            self.sendHelloUntilWelcomed(on: connection)
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            if let data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["type"] as? String == "welcome" {
                self.welcomed = true
                let name = object["device"] as? String ?? "Apple TV"
                self.publish { $0.connectedName = name; $0.status = "已連線：\(name)" }
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }

    // MARK: - Sending

    func sendMotion(dyaw: Double, dpitch: Double) {
        sendPacket(["type": "motion", "dyaw": dyaw, "dpitch": dpitch])
    }

    func sendScroll(dx: Double, dy: Double) {
        sendPacket(["type": "scroll", "dx": dx, "dy": dy])
    }

    func sendClick() {
        sendPacket(["type": "click"])
    }

    func sendBack() {
        sendPacket(["type": "back"])
    }

    private func sendPacket(_ packet: [String: Any]) {
        queue.async { [weak self] in
            guard let self, let connection = self.connection else { return }
            self.send(packet, on: connection)
        }
    }

    private func send(_ packet: [String: Any], on connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: packet) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
        sentCount += 1
        // Publishing every packet at 60 Hz would redraw the UI constantly; ~4 Hz is plenty.
        if sentCount - lastPublishedCount >= 15 || packet["type"] as? String != "motion" {
            lastPublishedCount = sentCount
            let count = sentCount
            publish { $0.packetsSent = count }
        }
    }

    // MARK: - Helpers

    private func deviceName() -> String {
        ProcessInfo.processInfo.hostName
    }

    private func publish(_ update: @escaping (PointerClient) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            update(self)
        }
    }
}
