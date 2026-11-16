//
//  JellyfinSocket.swift
//  AsterFIN
//
//  The live connection to a Jellyfin server (/socket), which is how the
//  server tells this device what a SyncPlay group is doing. It carries the
//  same sign-in as the app's requests, so the server knows it's this session.
//  The server asks for a keep-alive within a minute (ForceKeepAlive), and
//  this answers every half of that; a dropped connection is tried again,
//  waiting a little longer each time.
//

import Foundation

@MainActor
final class JellyfinSocket {
    /// Each message: its type and its data, as the JSON had them.
    var onMessage: ((String, Any?) -> Void)?
    /// After a dropped connection is back: anything set up on the old one
    /// (being in a group) can be asked for again.
    var onReconnect: (() -> Void)?

    private let client: JellyfinClient
    private var task: URLSessionWebSocketTask?
    private var receiving: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?
    private var wanted = false
    private var retries = 0
    private var hasConnected = false
    /// Message ids seen lately, as the server can send one twice.
    private var seen: [String] = []

    init(client: JellyfinClient) {
        self.client = client
    }

    var isOpen: Bool { task?.state == .running }

    func connect() {
        wanted = true
        guard task == nil else { return }
        open()
    }

    func disconnect() {
        wanted = false
        close()
    }

    private func open() {
        var components = URLComponents(url: client.url("/socket"), resolvingAgainstBaseURL: false)
        components?.scheme = client.baseURL.scheme?.lowercased() == "https" ? "wss" : "ws"
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: client.accessToken),
            URLQueryItem(name: "deviceId", value: JellyfinDevice.deviceId),
        ]
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.setValue(client.authorizationHeader, forHTTPHeaderField: "Authorization")
        let socket = client.session.webSocketTask(with: request)
        task = socket
        socket.resume()
        DebugLog.note("syncplay", "Socket opening")
        receiving = Task { [weak self] in await self?.receive(on: socket) }
    }

    private func close() {
        receiving?.cancel()
        keepAlive?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func receive(on socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                if retries > 0 || !hasConnected {
                    let again = hasConnected
                    retries = 0
                    hasConnected = true
                    if again { onReconnect?() }
                }
                switch message {
                case .string(let text): handle(Data(text.utf8))
                case .data(let data): handle(data)
                @unknown default: break
                }
            } catch {
                guard !Task.isCancelled, task === socket else { return }
                DebugLog.note("syncplay", "Socket dropped: \(error.localizedDescription)")
                close()
                retryLater()
                return
            }
        }
    }

    private func retryLater() {
        guard wanted else { return }
        retries += 1
        let wait = min(30, pow(2, Double(min(retries, 5))))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, self.wanted, self.task == nil else { return }
            self.open()
        }
    }

    private func handle(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["MessageType"] as? String else { return }
        if let id = object["MessageId"] as? String {
            guard !seen.contains(id) else { return }
            seen.append(id)
            if seen.count > 50 { seen.removeFirst(seen.count - 50) }
        }
        if type == "ForceKeepAlive" {
            let seconds = (object["Data"] as? NSNumber)?.doubleValue ?? 60
            send(["MessageType": "KeepAlive"])
            keepAlive?.cancel()
            keepAlive = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(max(5, seconds / 2)))
                    guard !Task.isCancelled else { return }
                    self?.send(["MessageType": "KeepAlive"])
                }
            }
            return
        }
        if type == "KeepAlive" { return }
        onMessage?(type, object["Data"])
    }

    private func send(_ object: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }
}
