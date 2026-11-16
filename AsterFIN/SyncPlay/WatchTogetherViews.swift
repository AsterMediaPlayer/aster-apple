//
//  WatchTogetherViews.swift
//  AsterFIN
//
//  Watch Together on the player: a small badge while in a group (waiting
//  for everyone, who's joined or left, what went wrong), and on iPhone,
//  iPad and the Mac the sheet that starts, joins and leaves a group. On
//  Apple TV the same choices are a tab of the player's panel.
//

import SwiftUI

extension SyncPlay {
    /// A new group's name: the person's, as Jellyfin's apps name them.
    static var newGroupName: String {
        if let name = AppSession.shared.userName, !name.isEmpty { return "\(name)'s group" }
        return "Aster group"
    }

    /// Who's watching, for a line under the group's name.
    var watchingLine: String {
        let others = participants.filter { $0 != AppSession.shared.userName }
        switch others.count {
        case 0: return "Just you so far"
        case 1: return "With \(others[0])"
        case 2: return "With \(others[0]) and \(others[1])"
        default: return "With \(others[0]) and \(others.count - 1) others"
        }
    }

    /// What the group's doing, when it's worth saying.
    var stateLine: String? {
        switch state {
        case .waiting: "Waiting for everyone…"
        case .paused: "Paused"
        case .idle, .playing: nil
        }
    }
}

/// The player's corner while watching together: waiting, a passing word,
/// or a problem. Nothing at all outside a group, or while all's well.
struct WatchTogetherBadge: View {
    private var syncPlay: SyncPlay { .shared }

    private var text: String? {
        if let problem = syncPlay.problem, syncPlay.isInGroup { return problem }
        if let notice = syncPlay.notice { return notice }
        guard syncPlay.isInGroup else { return nil }
        return syncPlay.state == .waiting ? "Waiting for everyone…" : nil
    }

    var body: some View {
        if let text {
            HStack(spacing: 10) {
                Image(systemName: "person.2.fill")
                Text(text)
                    .lineLimit(2)
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.black.opacity(0.65), in: Capsule())
            .foregroundStyle(.white)
            .transition(.opacity)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
        }
    }
}

#if !os(tvOS)
/// Starting, joining and leaving a group, from the player's Watch Together button.
struct WatchTogetherSheet: View {
    let player: any SyncPlayPlayer

    @Environment(\.dismiss) private var dismiss
    @State private var groups: [SyncPlayGroupInfo] = []
    @State private var loading = true

    private var syncPlay: SyncPlay { .shared }

    var body: some View {
        NavigationStack {
            Form {
                if let group = syncPlay.group {
                    Section {
                        LabeledContent(group.groupName.isEmpty ? "Your group" : group.groupName) {
                            Text("\(syncPlay.participants.count) watching")
                        }
                        Text(syncPlay.watchingLine)
                            .foregroundStyle(.secondary)
                        if let state = syncPlay.stateLine {
                            Text(state)
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Play, pause and seek here or on any device in the group, and everyone follows.")
                    }
                    Section {
                        Button("Leave Group", role: .destructive) {
                            Task {
                                await syncPlay.leave()
                                dismiss()
                            }
                        }
                    }
                } else {
                    Section {
                        Button {
                            Task {
                                await syncPlay.startGroup(named: SyncPlay.newGroupName, with: player)
                                if syncPlay.isInGroup { dismiss() }
                            }
                        } label: {
                            Label("Start a Group", systemImage: "plus.circle")
                        }
                        .disabled(syncPlay.isWorking)
                    } footer: {
                        Text("Others on this server can join from their own Jellyfin apps, and watch this with you, in step.")
                    }
                    Section("Join a Group") {
                        if loading {
                            ProgressView()
                        } else if groups.isEmpty {
                            Text("No groups on the server right now.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(groups) { group in
                            Button {
                                Task {
                                    await syncPlay.join(group, with: player)
                                    if syncPlay.isInGroup { dismiss() }
                                }
                            } label: {
                                LabeledContent(group.groupName.isEmpty ? "A group" : group.groupName) {
                                    Text(group.participants.joined(separator: ", "))
                                }
                            }
                            .disabled(syncPlay.isWorking)
                        }
                    }
                }
                if let problem = syncPlay.problem {
                    Section {
                        Text(problem)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Watch Together")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                guard !syncPlay.isInGroup else { return }
                groups = await syncPlay.groups()
                loading = false
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }
}
#endif
