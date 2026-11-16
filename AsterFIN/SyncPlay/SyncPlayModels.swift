//
//  SyncPlayModels.swift
//  AsterFIN
//
//  Jellyfin's SyncPlay on the wire (10.7 and later): the requests' bodies,
//  the groups, and what the server says over its socket. Names are the
//  server's, PascalCase; ids come without dashes, and dates with seven
//  digits after the second.
//

import Foundation

/// A group, as the server lists it and as joining one says.
nonisolated struct SyncPlayGroupInfo: Decodable, Sendable, Equatable, Identifiable {
    var groupId: String
    var groupName: String
    var state: SyncPlayGroupState
    /// The people in it, by user name.
    var participants: [String]
    var lastUpdatedAt: Date?

    var id: String { groupId }

    enum CodingKeys: String, CodingKey {
        case groupId = "GroupId", groupName = "GroupName", state = "State"
        case participants = "Participants", lastUpdatedAt = "LastUpdatedAt"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groupId = try container.decode(String.self, forKey: .groupId)
        groupName = (try? container.decode(String.self, forKey: .groupName)) ?? ""
        state = (try? container.decode(SyncPlayGroupState.self, forKey: .state)) ?? .idle
        participants = (try? container.decode([String].self, forKey: .participants)) ?? []
        lastUpdatedAt = (try? container.decode(String.self, forKey: .lastUpdatedAt)).flatMap(SyncPlayTime.date)
    }
}

/// Where a group is: nothing playing, waiting for everyone to be ready,
/// paused, or playing.
nonisolated enum SyncPlayGroupState: String, Decodable, Sendable {
    case idle = "Idle", waiting = "Waiting", paused = "Paused", playing = "Playing"

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SyncPlayGroupState(rawValue: raw) ?? .idle
    }
}

/// What the group has to play, and from where.
nonisolated struct SyncPlayQueue: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        var itemId: String
        var playlistItemId: String
    }

    var reason: String
    var lastUpdate: Date?
    var playlist: [Entry]
    var playingItemIndex: Int
    var startPositionTicks: Int64
    var isPlaying: Bool

    var playing: Entry? { playlist.indices.contains(playingItemIndex) ? playlist[playingItemIndex] : nil }
}

/// A play, pause, seek or stop, to carry out at `when` (the server's clock).
nonisolated struct SyncPlayCommand: Sendable, Equatable {
    enum Kind: String, Sendable { case unpause = "Unpause", pause = "Pause", stop = "Stop", seek = "Seek" }

    var kind: Kind
    var playlistItemId: String
    var when: Date
    var positionTicks: Int64?
    var emittedAt: Date?
}

/// What the server's socket says that SyncPlay listens for.
nonisolated enum SyncPlayMessage: Sendable {
    case command(SyncPlayCommand)
    case joined(SyncPlayGroupInfo)
    case left
    case userJoined(String)
    case userLeft(String)
    case state(SyncPlayGroupState)
    case queue(SyncPlayQueue)
    /// Not in a group, the group's gone, or the queue is out of bounds.
    case refused(String)

    /// Reads one socket message, or nil when it isn't SyncPlay's.
    static func parse(type: String, data: Any?) -> SyncPlayMessage? {
        switch type {
        case "SyncPlayCommand":
            guard let data = data as? [String: Any],
                  let raw = data["Command"] as? String, let kind = SyncPlayCommand.Kind(rawValue: raw),
                  let when = (data["When"] as? String).flatMap(SyncPlayTime.date) else { return nil }
            return .command(SyncPlayCommand(
                kind: kind,
                playlistItemId: SyncPlayID.normalized(data["PlaylistItemId"] as? String ?? ""),
                when: when,
                positionTicks: (data["PositionTicks"] as? NSNumber)?.int64Value,
                emittedAt: (data["EmittedAt"] as? String).flatMap(SyncPlayTime.date)
            ))
        case "SyncPlayGroupUpdate":
            guard let update = data as? [String: Any], let kind = update["Type"] as? String else { return nil }
            let payload = update["Data"]
            switch kind {
            case "GroupJoined":
                guard let payload, JSONSerialization.isValidJSONObject(payload),
                      let json = try? JSONSerialization.data(withJSONObject: payload),
                      let info = try? JSONDecoder().decode(SyncPlayGroupInfo.self, from: json) else { return nil }
                return .joined(info)
            case "GroupLeft":
                return .left
            case "UserJoined":
                return .userJoined(payload as? String ?? "")
            case "UserLeft":
                return .userLeft(payload as? String ?? "")
            case "StateUpdate":
                guard let state = (payload as? [String: Any])?["State"] as? String else { return nil }
                return .state(SyncPlayGroupState(rawValue: state) ?? .idle)
            case "PlayQueue":
                guard let data = payload as? [String: Any] else { return nil }
                let playlist = (data["Playlist"] as? [[String: Any]] ?? []).compactMap { entry -> SyncPlayQueue.Entry? in
                    guard let item = entry["ItemId"] as? String, let playlistItem = entry["PlaylistItemId"] as? String else { return nil }
                    return SyncPlayQueue.Entry(itemId: SyncPlayID.normalized(item), playlistItemId: SyncPlayID.normalized(playlistItem))
                }
                return .queue(SyncPlayQueue(
                    reason: data["Reason"] as? String ?? "",
                    lastUpdate: (data["LastUpdate"] as? String).flatMap(SyncPlayTime.date),
                    playlist: playlist,
                    playingItemIndex: (data["PlayingItemIndex"] as? NSNumber)?.intValue ?? 0,
                    startPositionTicks: (data["StartPositionTicks"] as? NSNumber)?.int64Value ?? 0,
                    isPlaying: data["IsPlaying"] as? Bool ?? false
                ))
            case "NotInGroup", "GroupDoesNotExist", "LibraryAccessDenied", "CreateGroupDenied", "JoinGroupDenied":
                return .refused(kind)
            default:
                return nil
            }
        default:
            return nil
        }
    }
}

// MARK: - Requests

nonisolated struct SyncPlayNewGroup: Encodable, Sendable {
    var groupName: String
    enum CodingKeys: String, CodingKey { case groupName = "GroupName" }
}

nonisolated struct SyncPlayJoin: Encodable, Sendable {
    var groupId: String
    enum CodingKeys: String, CodingKey { case groupId = "GroupId" }
}

nonisolated struct SyncPlaySetQueue: Encodable, Sendable {
    var playingQueue: [String]
    var playingItemPosition: Int
    var startPositionTicks: Int64
    enum CodingKeys: String, CodingKey {
        case playingQueue = "PlayingQueue", playingItemPosition = "PlayingItemPosition", startPositionTicks = "StartPositionTicks"
    }
}

nonisolated struct SyncPlaySeek: Encodable, Sendable {
    var positionTicks: Int64
    enum CodingKeys: String, CodingKey { case positionTicks = "PositionTicks" }
}

/// Buffering and Ready both say this: where the player is, and when.
nonisolated struct SyncPlayReadiness: Encodable, Sendable {
    var when: String
    var positionTicks: Int64
    var isPlaying: Bool
    var playlistItemId: String
    enum CodingKeys: String, CodingKey {
        case when = "When", positionTicks = "PositionTicks", isPlaying = "IsPlaying", playlistItemId = "PlaylistItemId"
    }
}

nonisolated struct SyncPlayPing: Encodable, Sendable {
    var ping: Int64
    enum CodingKeys: String, CodingKey { case ping = "Ping" }
}

/// The server's two times for one clock sample.
nonisolated struct SyncPlayUtcTime: Decodable, Sendable {
    var requestReceptionTime: Date
    var responseTransmissionTime: Date

    enum CodingKeys: String, CodingKey {
        case requestReceptionTime = "RequestReceptionTime", responseTransmissionTime = "ResponseTransmissionTime"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let received = SyncPlayTime.date(try container.decode(String.self, forKey: .requestReceptionTime)),
              let sent = SyncPlayTime.date(try container.decode(String.self, forKey: .responseTransmissionTime)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: "Unreadable server time"))
        }
        requestReceptionTime = received
        responseTransmissionTime = sent
    }
}

// MARK: - Ids and dates

nonisolated enum SyncPlayID {
    /// Ids compared as the server writes them: lower case, no dashes.
    static func normalized(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

nonisolated enum SyncPlayTime {
    /// A server date: `2026-11-16T20:00:00.1234567Z`, any number of
    /// fractional digits (the system's parser takes three at most), or none.
    static func date(_ text: String) -> Date? {
        var text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.hasSuffix("Z") { text.removeLast() }
        var fraction = 0.0
        if let dot = text.firstIndex(of: ".") {
            let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
            fraction = Double("0." + digits) ?? 0
            text = String(text[..<dot])
        }
        // A trailing offset (+00:00) after the seconds, kept for the parser.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text + "Z") ?? formatter.date(from: text) {
            return date.addingTimeInterval(fraction)
        }
        return nil
    }

    /// A date to send: UTC, with milliseconds.
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Ticks (the server's units: ten million a second) and seconds.
nonisolated enum Ticks {
    static let perSecond: Double = 10_000_000

    static func seconds(_ ticks: Int64) -> Double { Double(ticks) / perSecond }
    static func ticks(_ seconds: Double) -> Int64 { Int64((seconds * perSecond).rounded()) }
}
