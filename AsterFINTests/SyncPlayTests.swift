//
//  SyncPlayTests.swift
//  AsterFINTests
//
//  Watch Together's wire: the server's dates (seven fractional digits),
//  its socket messages as Jellyfin writes them, ids without dashes, and
//  what Aster sends back.
//

import Foundation
import Testing
@testable import AsterFIN

struct SyncPlayTests {
    private func json(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    /// The server writes seven digits after the second; the system's own
    /// parser takes three at most.
    @Test func theServersDatesAreRead() throws {
        let seven = try #require(SyncPlayTime.date("2026-11-16T20:00:00.1234567Z"))
        let none = try #require(SyncPlayTime.date("2026-11-16T20:00:00Z"))
        #expect(abs(seven.timeIntervalSince(none) - 0.1234567) < 0.000_001)
        #expect(SyncPlayTime.date("2026-11-16T20:00:00.5") != nil)
        #expect(SyncPlayTime.date("") == nil)
        #expect(SyncPlayTime.date("not a date") == nil)
    }

    /// What Aster sends reads back as the same moment, to the millisecond.
    @Test func sentDatesRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000.25)
        let text = SyncPlayTime.string(now)
        #expect(text.hasSuffix("Z"))
        let back = try #require(SyncPlayTime.date(text))
        #expect(abs(back.timeIntervalSince(now)) < 0.001)
    }

    @Test func idsCompareWithoutDashes() {
        #expect(SyncPlayID.normalized("3F2A1B4C-0000-4D5E-8F90-ABCDEF123456") == "3f2a1b4c00004d5e8f90abcdef123456")
        #expect(SyncPlayID.normalized("3f2a1b4c00004d5e8f90abcdef123456") == "3f2a1b4c00004d5e8f90abcdef123456")
    }

    @Test func aCommandIsRead() throws {
        let data = json(#"{"GroupId":"g1","PlaylistItemId":"AB-CD","When":"2026-11-16T20:00:01.0000000Z","PositionTicks":123450000,"Command":"Unpause","EmittedAt":"2026-11-16T20:00:00.5000000Z"}"#)
        guard case .command(let command) = SyncPlayMessage.parse(type: "SyncPlayCommand", data: data) else {
            Issue.record("Not read as a command")
            return
        }
        #expect(command.kind == .unpause)
        #expect(command.playlistItemId == "abcd")
        #expect(command.positionTicks == 123_450_000)
        #expect(command.emittedAt != nil)
        // A seek without a position, and a command Aster doesn't know.
        let seek = json(#"{"PlaylistItemId":"x","When":"2026-11-16T20:00:01Z","PositionTicks":null,"Command":"Seek"}"#)
        guard case .command(let bare) = SyncPlayMessage.parse(type: "SyncPlayCommand", data: seek) else {
            Issue.record("A seek without a position wasn't read")
            return
        }
        #expect(bare.positionTicks == nil)
        let unknown = json(#"{"PlaylistItemId":"x","When":"2026-11-16T20:00:01Z","Command":"Dance"}"#)
        #expect(SyncPlayMessage.parse(type: "SyncPlayCommand", data: unknown) == nil)
    }

    @Test func joiningAGroupIsRead() throws {
        let data = json(#"{"GroupId":"g1","Type":"GroupJoined","Data":{"GroupId":"g1","GroupName":"bard's group","State":"Paused","Participants":["bard","Sam"],"LastUpdatedAt":"2026-11-16T20:00:00.0000000Z"}}"#)
        guard case .joined(let info) = SyncPlayMessage.parse(type: "SyncPlayGroupUpdate", data: data) else {
            Issue.record("Not read as joined")
            return
        }
        #expect(info.groupName == "bard's group")
        #expect(info.state == .paused)
        #expect(info.participants == ["bard", "Sam"])
        #expect(info.lastUpdatedAt != nil)
    }

    @Test func theGroupsQueueIsRead() throws {
        let data = json(#"{"GroupId":"g1","Type":"PlayQueue","Data":{"Reason":"NewPlaylist","LastUpdate":"2026-11-16T20:00:00.0000000Z","Playlist":[{"ItemId":"ITEM-1","PlaylistItemId":"P-1"},{"ItemId":"item2","PlaylistItemId":"p2"}],"PlayingItemIndex":1,"StartPositionTicks":50000000,"IsPlaying":true,"ShuffleMode":"Sorted","RepeatMode":"RepeatNone"}}"#)
        guard case .queue(let queue) = SyncPlayMessage.parse(type: "SyncPlayGroupUpdate", data: data) else {
            Issue.record("Not read as a queue")
            return
        }
        #expect(queue.reason == "NewPlaylist")
        #expect(queue.playlist.count == 2)
        #expect(queue.playlist[0] == SyncPlayQueue.Entry(itemId: "item1", playlistItemId: "p1"))
        #expect(queue.playing?.itemId == "item2")
        #expect(queue.startPositionTicks == 50_000_000)
        #expect(queue.isPlaying)
        // An index past the end plays nothing.
        var out = queue
        out.playingItemIndex = 5
        #expect(out.playing == nil)
    }

    @Test func peopleAndStatesAreRead() {
        let joined = json(#"{"GroupId":"g1","Type":"UserJoined","Data":"Sam"}"#)
        guard case .userJoined(let name) = SyncPlayMessage.parse(type: "SyncPlayGroupUpdate", data: joined) else {
            Issue.record("Not read as a person joining")
            return
        }
        #expect(name == "Sam")
        let state = json(#"{"GroupId":"g1","Type":"StateUpdate","Data":{"State":"Waiting","Reason":"Buffer"}}"#)
        guard case .state(let value) = SyncPlayMessage.parse(type: "SyncPlayGroupUpdate", data: state) else {
            Issue.record("Not read as a state")
            return
        }
        #expect(value == .waiting)
        let gone = json(#"{"GroupId":"00000000000000000000000000000000","Type":"GroupDoesNotExist","Data":""}"#)
        guard case .refused(let why) = SyncPlayMessage.parse(type: "SyncPlayGroupUpdate", data: gone) else {
            Issue.record("Not read as refused")
            return
        }
        #expect(why == "GroupDoesNotExist")
        // Anything else on the socket isn't SyncPlay's.
        #expect(SyncPlayMessage.parse(type: "LibraryChanged", data: nil) == nil)
    }

    /// The requests' bodies, in the server's names.
    @Test func requestsAreWrittenAsTheServerReadsThem() throws {
        let queue = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SyncPlaySetQueue(playingQueue: ["i1"], playingItemPosition: 0, startPositionTicks: 42))) as? [String: Any]
        #expect(queue?["PlayingQueue"] as? [String] == ["i1"])
        #expect(queue?["PlayingItemPosition"] as? Int == 0)
        #expect(queue?["StartPositionTicks"] as? Int == 42)
        let ready = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SyncPlayReadiness(when: "2026-11-16T20:00:00.000Z", positionTicks: 7, isPlaying: false, playlistItemId: "p1"))) as? [String: Any]
        #expect(ready?["When"] as? String == "2026-11-16T20:00:00.000Z")
        #expect(ready?["PlaylistItemId"] as? String == "p1")
        #expect(ready?["IsPlaying"] as? Bool == false)
        let group = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SyncPlayNewGroup(groupName: "bard's group"))) as? [String: Any]
        #expect(group?["GroupName"] as? String == "bard's group")
    }

    @Test func ticksAndSeconds() {
        #expect(Ticks.ticks(1.5) == 15_000_000)
        #expect(Ticks.seconds(25_000_000) == 2.5)
    }
}

extension SyncPlayMessage: @retroactive Equatable {
    public static func == (lhs: SyncPlayMessage, rhs: SyncPlayMessage) -> Bool {
        String(describing: lhs) == String(describing: rhs)
    }
}
