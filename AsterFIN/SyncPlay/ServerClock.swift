//
//  ServerClock.swift
//  AsterFIN
//
//  The server's clock, as this device sees it, so a group's "play at 21:04:05.250"
//  lands at the same moment on every screen. As Jellyfin's web player does:
//  each sample asks /GetUtcTime and times the round trip; of the last eight,
//  the one with the shortest trip is trusted. A sample a second at first, then
//  one a minute.
//

import Foundation

@MainActor
final class ServerClock {
    private struct Sample {
        /// Server time minus this device's.
        var offset: TimeInterval
        /// The round trip, less the server's own time on it.
        var delay: TimeInterval
    }

    private var samples: [Sample] = []
    private var task: Task<Void, Never>?
    /// Called after each sample, with the trip's one-way time in milliseconds.
    var onSample: ((Int64) -> Void)?

    /// Whether a sample has come in: commands wait for one.
    var isSynced: Bool { !samples.isEmpty }

    private var best: Sample? { samples.min { $0.delay < $1.delay } }

    /// Server time minus this device's, from the best sample.
    var offset: TimeInterval { best?.offset ?? 0 }

    /// Half the best round trip, in milliseconds: the group's "ping".
    var pingMilliseconds: Int64 { Int64(((best?.delay ?? 0) / 2 * 1000).rounded()) }

    func now() -> Date { Date().addingTimeInterval(offset) }
    func toLocal(_ server: Date) -> Date { server.addingTimeInterval(-offset) }

    /// Starts sampling (again from the start: a sample a second for a few).
    func start(client: JellyfinClient) {
        task?.cancel()
        samples = []
        task = Task { [weak self] in
            var taken = 0
            while !Task.isCancelled {
                await self?.sample(client: client)
                taken += 1
                try? await Task.sleep(for: .seconds(taken < 5 ? 1 : 60))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func sample(client: JellyfinClient) async {
        let sent = Date()
        guard let reply = try? await client.get(SyncPlayUtcTime.self, "/GetUtcTime") else { return }
        let received = Date()
        let offset = ((reply.requestReceptionTime.timeIntervalSince(sent)) + (reply.responseTransmissionTime.timeIntervalSince(received))) / 2
        let delay = received.timeIntervalSince(sent) - reply.responseTransmissionTime.timeIntervalSince(reply.requestReceptionTime)
        samples.append(Sample(offset: offset, delay: max(0, delay)))
        if samples.count > 8 { samples.removeFirst(samples.count - 8) }
        onSample?(pingMilliseconds)
    }
}
