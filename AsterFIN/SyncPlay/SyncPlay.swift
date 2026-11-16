//
//  SyncPlay.swift
//  AsterFIN
//
//  Watching together, through Jellyfin's SyncPlay: a group on the server
//  that everyone in it plays in step. Starting a group puts what's playing
//  in it; joining one plays what it's playing, from where it's got to.
//  Play, pause and seek go to the group, and the server tells every player
//  what to do and when, by its own clock; each player says when it's
//  buffering and when it's ready, and the group waits for the slowest.
//
//  As Jellyfin's web player: commands for another title, or from before
//  joining, are left; a late play catches up by seeking ahead; a pause
//  pauses here at once as well as asking the group.
//
//  Jellyfin only (Emby has its own, older kind), and titles only: a channel
//  keeps to its own schedule.
//

import Foundation
import Observation

/// What a player does for a group, and what the group needs to know of it.
@MainActor
protocol SyncPlayPlayer: AnyObject {
    /// The title playing, as the server's id.
    var syncItemId: String? { get }
    var syncPositionTicks: Int64 { get }
    var syncIsPlaying: Bool { get }
    /// Stalled waiting for the stream.
    var syncIsBuffering: Bool { get }
    func syncPlay()
    func syncPause()
    func syncSeek(to ticks: Int64) async
    /// Starts another title, at `startTicks`, held paused once it's loaded
    /// (see `SyncPlay.playerLoaded`).
    func syncLoad(itemId: String, startTicks: Int64)
}

@MainActor
@Observable
final class SyncPlay {
    static let shared = SyncPlay()

    /// The group this device is in; nil when it isn't in one.
    private(set) var group: SyncPlayGroupInfo?
    /// Who's in it, as people join and leave.
    private(set) var participants: [String] = []
    private(set) var state: SyncPlayGroupState = .idle
    /// A passing word ("Sam joined"), shown on the player for a moment.
    private(set) var notice: String?
    /// Why the last request didn't work, in plain words.
    private(set) var problem: String?
    /// A request is on its way.
    private(set) var isWorking = false

    var isInGroup: Bool { group != nil }

    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private var socket: JellyfinSocket?
    @ObservationIgnored private let clock = ServerClock()
    @ObservationIgnored private weak var player: (any SyncPlayPlayer)?

    /// The queue's entry playing, by its place in the group's queue.
    @ObservationIgnored private var playlistItemId: String?
    @ObservationIgnored private var lastQueueUpdate: Date?
    /// When this device joined, by the group's last update then: commands
    /// sent before it are old news.
    @ObservationIgnored private var joinedAt: Date?
    @ObservationIgnored private var lastCommand: SyncPlayCommand?
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    /// A title the group asked for, being loaded; held paused once it is.
    @ObservationIgnored private var awaitingItemId: String?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    private init() {
        clock.onSample = { [weak self] ping in
            guard let self, self.isInGroup, let client = self.client else { return }
            Task { try? await client.post("/SyncPlay/Ping", body: SyncPlayPing(ping: ping)) }
        }
    }

    // MARK: The player

    /// Whether a group can be started or joined with `client`: Jellyfin's own.
    static func isAvailable(on client: (any MediaServer)?) -> Bool {
        (client as? JellyfinClient)?.kind == .jellyfin
    }

    /// The player that plays for the group, once it's playing.
    func attach(_ player: any SyncPlayPlayer) {
        self.player = player
    }

    /// The player closed: closing it leaves the group, as watching together
    /// is done from it.
    func detach(_ player: any SyncPlayPlayer) {
        guard self.player === player else { return }
        self.player = nil
        if isInGroup { Task { await leave() } }
    }

    /// Whether `player`'s play, pause and seek go to the group.
    func controls(_ player: any SyncPlayPlayer) -> Bool {
        isInGroup && self.player === player
    }

    /// Whether a title starting in `player` is one the group asked for: it's
    /// held paused, and the group's told it's ready.
    func holdsStart(of itemId: String) -> Bool {
        awaitingItemId == SyncPlayID.normalized(itemId)
    }

    /// The title the group asked for is loaded and held: ready.
    func playerLoaded(_ player: any SyncPlayPlayer) {
        awaitingItemId = nil
        self.player = player
        player.syncPause()
        Task { await sendReadiness(ready: true, isPlaying: false) }
    }

    // MARK: Groups

    /// The server's groups, to join.
    func groups() async -> [SyncPlayGroupInfo] {
        guard let client = prepare() else { return [] }
        do {
            problem = nil
            return try await client.get([SyncPlayGroupInfo].self, "/SyncPlay/List")
        } catch {
            problem = Self.describe(error)
            return []
        }
    }

    /// A new group, with what `player` is playing, from where it's got to.
    func startGroup(named name: String, with player: any SyncPlayPlayer) async {
        guard let client = prepare(), let itemId = player.syncItemId else { return }
        self.player = player
        await perform {
            try await client.post("/SyncPlay/New", body: SyncPlayNewGroup(groupName: name))
            // The group arrives over the socket (10.10 and before answer
            // nothing), then gets what's playing.
            try await self.waitForGroup()
            let ticks = player.syncPositionTicks
            try await client.post("/SyncPlay/SetNewQueue", body: SyncPlaySetQueue(playingQueue: [itemId], playingItemPosition: 0, startPositionTicks: ticks))
        }
    }

    /// Joins `group`: it plays what the group's playing, from where it's got to.
    func join(_ group: SyncPlayGroupInfo, with player: (any SyncPlayPlayer)?) async {
        guard let client = prepare() else { return }
        if let player { self.player = player }
        await perform {
            try await client.post("/SyncPlay/Join", body: SyncPlayJoin(groupId: group.groupId))
            try await self.waitForGroup()
        }
    }

    func leave() async {
        guard let client else { return }
        let wasIn = isInGroup
        reset()
        if wasIn { try? await client.post("/SyncPlay/Leave") }
        socket?.disconnect()
        clock.stop()
    }

    // MARK: What the person does, in a group

    func requestToggle() {
        guard let player else { return }
        if player.syncIsPlaying { requestPause() } else { requestUnpause() }
    }

    /// Pauses here at once, and the group.
    func requestPause() {
        player?.syncPause()
        send("/SyncPlay/Pause")
    }

    /// Asks the group; everyone plays together once all are ready.
    func requestUnpause() {
        send("/SyncPlay/Unpause")
    }

    /// The group seeks together; `thenPlay` plays on from there once all are
    /// ready (a scrub, or a chapter picked).
    func requestSeek(to ticks: Int64, thenPlay: Bool = false) {
        guard let client else { return }
        Task {
            do {
                try await client.post("/SyncPlay/Seek", body: SyncPlaySeek(positionTicks: max(0, ticks)))
                if thenPlay { try await client.post("/SyncPlay/Unpause") }
            } catch {
                problem = Self.describe(error)
            }
        }
    }

    /// Another title for the whole group (Play Next): every player loads it.
    func requestNewQueue(itemId: String, startTicks: Int64) {
        send("/SyncPlay/SetNewQueue", body: SyncPlaySetQueue(playingQueue: [itemId], playingItemPosition: 0, startPositionTicks: startTicks))
    }

    // MARK: Plumbing

    /// The Jellyfin sign-in in use, with the socket open and the clock running.
    private func prepare() -> JellyfinClient? {
        guard let current = AppSession.shared.jellyfin, current.kind == .jellyfin else {
            problem = "Watch Together needs a Jellyfin server."
            return nil
        }
        if client?.baseURL != current.baseURL || client?.accessToken != current.accessToken {
            socket?.disconnect()
            reset()
            client = current
            let socket = JellyfinSocket(client: current)
            socket.onMessage = { [weak self] type, data in
                guard let message = SyncPlayMessage.parse(type: type, data: data) else { return }
                self?.handle(message)
            }
            socket.onReconnect = { [weak self] in self?.rejoin() }
            self.socket = socket
        }
        socket?.connect()
        if !clock.isSynced { clock.start(client: current) }
        return current
    }

    private func perform(_ work: @escaping () async throws -> Void) async {
        isWorking = true
        problem = nil
        defer { isWorking = false }
        do {
            try await work()
        } catch {
            problem = Self.describe(error)
            DebugLog.note("syncplay", "Request failed: \(error.localizedDescription)")
        }
    }

    private func send(_ path: String, body: (any Encodable & Sendable)? = nil) {
        guard let client else { return }
        Task {
            do {
                try await client.post(path, body: body)
            } catch {
                problem = Self.describe(error)
            }
        }
    }

    private func waitForGroup() async throws {
        for _ in 0..<80 where group == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        if group == nil { throw SyncPlayError.noGroup }
    }

    /// Back on a dropped connection: in the group again, as it was.
    private func rejoin() {
        guard let group, let client else { return }
        clock.start(client: client)
        Task { try? await client.post("/SyncPlay/Join", body: SyncPlayJoin(groupId: group.groupId)) }
    }

    private func reset() {
        commandTask?.cancel()
        watchTask?.cancel()
        group = nil
        participants = []
        state = .idle
        playlistItemId = nil
        lastQueueUpdate = nil
        joinedAt = nil
        lastCommand = nil
        awaitingItemId = nil
    }

    // MARK: What the server says

    private func handle(_ message: SyncPlayMessage) {
        switch message {
        case .joined(let info):
            group = info
            participants = info.participants
            state = info.state
            joinedAt = info.lastUpdatedAt
            problem = nil
            watchForBuffering()
            DebugLog.note("syncplay", "In a group of \(info.participants.count)")
        case .left:
            reset()
            show("You left the group")
        case .userJoined(let name):
            if !participants.contains(name) { participants.append(name) }
            show("\(name) joined")
        case .userLeft(let name):
            if let index = participants.firstIndex(of: name) { participants.remove(at: index) }
            show("\(name) left")
        case .state(let new):
            state = new
        case .queue(let queue):
            apply(queue)
        case .command(let command):
            apply(command)
        case .refused(let why):
            if why == "LibraryAccessDenied" {
                problem = "You can't see what this group is playing."
            } else if why == "GroupDoesNotExist" {
                problem = "That group has ended."
                reset()
            } else if why == "NotInGroup" {
                reset()
            } else {
                problem = "The server didn't allow that."
            }
        }
    }

    /// What the group plays, and from where: loaded here and held, then
    /// "ready", and the group plays once everyone is.
    private func apply(_ queue: SyncPlayQueue) {
        if let last = lastQueueUpdate, let update = queue.lastUpdate, update <= last { return }
        lastQueueUpdate = queue.lastUpdate
        guard let entry = queue.playing else { return }
        let reasons = ["NewPlaylist", "SetCurrentItem", "NextItem", "PreviousItem", "RemoveItems"]
        let changed = playlistItemId != entry.playlistItemId
        playlistItemId = entry.playlistItemId
        guard reasons.contains(queue.reason), changed || queue.reason == "NewPlaylist" else { return }
        var ticks = queue.startPositionTicks
        if queue.isPlaying, let update = queue.lastUpdate {
            ticks += Ticks.ticks(max(0, clock.now().timeIntervalSince(update)))
        }
        if let player, player.syncItemId.map(SyncPlayID.normalized) == entry.itemId {
            Task {
                player.syncPause()
                await player.syncSeek(to: ticks)
                await sendReadiness(ready: true, isPlaying: false)
            }
        } else {
            awaitingItemId = entry.itemId
            if let player {
                player.syncLoad(itemId: entry.itemId, startTicks: ticks)
            } else {
                AppSession.shared.router.play(PlaybackRequest(itemId: entry.itemId, startTicks: ticks))
            }
        }
    }

    /// A play, pause, seek or stop, carried out at the server's `when`.
    private func apply(_ command: SyncPlayCommand) {
        if let joinedAt, let emitted = command.emittedAt, emitted < joinedAt { return }
        if command.kind != .stop, command.playlistItemId != playlistItemId { return }
        if command == lastCommand { return }
        lastCommand = command
        commandTask?.cancel()
        commandTask = Task { [weak self] in
            guard let self else { return }
            // Times mean nothing until the clock's been read once.
            for _ in 0..<30 where !self.clock.isSynced {
                try? await Task.sleep(for: .milliseconds(100))
            }
            await self.carryOut(command)
        }
    }

    private func carryOut(_ command: SyncPlayCommand) async {
        guard let player else { return }
        let at = clock.toLocal(command.when)
        let wait = at.timeIntervalSinceNow
        switch command.kind {
        case .unpause:
            if wait > 0 {
                if let ticks = command.positionTicks, abs(player.syncPositionTicks - ticks) > Ticks.ticks(0.4) {
                    await player.syncSeek(to: ticks)
                }
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                player.syncPlay()
            } else {
                player.syncPlay()
                if let ticks = command.positionTicks {
                    let target = ticks + Ticks.ticks(-wait)
                    if abs(player.syncPositionTicks - target) > Ticks.ticks(0.4) {
                        await player.syncSeek(to: target)
                    }
                }
            }
        case .pause:
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            player.syncPause()
            if let ticks = command.positionTicks, abs(player.syncPositionTicks - ticks) > Ticks.ticks(0.4) {
                await player.syncSeek(to: ticks)
            }
        case .seek:
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            player.syncPause()
            if let ticks = command.positionTicks { await player.syncSeek(to: ticks) }
            await sendReadiness(ready: true, isPlaying: false)
        case .stop:
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            player.syncPause()
        }
    }

    /// While in a group: a stall of three seconds says "buffering", and
    /// playing again says "ready", so the group waits for the slowest.
    private func watchForBuffering() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            var stalledSince: Date?
            var reported = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.isInGroup, let player = self.player else { continue }
                if player.syncIsBuffering {
                    stalledSince = stalledSince ?? Date()
                    if !reported, let since = stalledSince, Date().timeIntervalSince(since) > 3 {
                        reported = true
                        await self.sendReadiness(ready: false, isPlaying: true)
                    }
                } else {
                    stalledSince = nil
                    if reported {
                        reported = false
                        await self.sendReadiness(ready: true, isPlaying: player.syncIsPlaying)
                    }
                }
            }
        }
    }

    private func sendReadiness(ready: Bool, isPlaying: Bool) async {
        guard let client, let player, let playlistItemId else { return }
        let body = SyncPlayReadiness(
            when: SyncPlayTime.string(clock.now()),
            positionTicks: player.syncPositionTicks,
            isPlaying: isPlaying,
            playlistItemId: playlistItemId
        )
        try? await client.post(ready ? "/SyncPlay/Ready" : "/SyncPlay/Buffering", body: body)
    }

    private func show(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private static func describe(_ error: any Error) -> String {
        if case JellyfinError.http(let status, _) = error, status == 401 || status == 403 {
            return "This account can't use SyncPlay on this server. An administrator can allow it in the user's settings in Jellyfin."
        }
        if error is SyncPlayError { return "The server didn't answer. Try again." }
        return error.localizedDescription
    }
}

nonisolated enum SyncPlayError: Error {
    case noGroup
}
