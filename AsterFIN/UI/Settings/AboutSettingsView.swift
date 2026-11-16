//
//  AboutSettingsView.swift
//  AsterFIN
//
//  Settings ▸ About.
//

import SwiftUI

// MARK: - About

struct AboutSettingsView: View {
    @State private var sendingReport = false

    #if os(tvOS)
    private enum Focus { case openSource }
    @FocusState private var focus: Focus?
    #endif

    var body: some View {
        SettingsPage(title: "About") {
            // Only what can be pressed takes focus on Apple TV. The version,
            // the description and the web addresses were made focusable, and
            // focus stuck on them: down the page couldn't be reached. Open
            // Source & Licenses has it as the page opens, which also gives
            // tvOS somewhere for the Back press to go.
            Section {
                LabeledContent("Aster Media Player", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                SettingsNote("A Jellyfin, Emby and Plex client for Apple TV, iPhone, iPad and Mac, with DVD and Blu-ray style menus on Jellyfin from the Aster Disc plugin.")
            }
            Section {
                AboutLink(title: "Help & Support", systemImage: "questionmark.circle", address: AboutLink.support)
                AboutLink(title: "Privacy Policy", systemImage: "hand.raised", address: AboutLink.privacy)
                NavigationLink(value: OpenSourceRoute.list) {
                    Label("Open Source & Licenses", systemImage: "doc.text")
                }
                #if os(tvOS)
                .focused($focus, equals: .openSource)
                #endif
                Button {
                    sendingReport = true
                } label: {
                    Label("Send Debug Report", systemImage: "ladybug")
                }
            }
        }
        #if os(tvOS)
        .defaultFocus($focus, .openSource)
        .task {
            // Set as the page appears, focus can be ignored: again once it's up.
            focus = .openSource
            try? await Task.sleep(for: .milliseconds(300))
            if focus == nil { focus = .openSource }
        }
        #endif
        .sheet(isPresented: $sendingReport) {
            DebugReportView()
        }
    }
}

/// One of Aster's web pages: a link where there's a browser, and the address
/// to type in on Apple TV, which has none.
private struct AboutLink: View {
    static let support = "https://astermediaplayer.com/support.html"
    static let privacy = "https://astermediaplayer.com/privacy.html"

    let title: String
    let systemImage: String
    let address: String

    var body: some View {
        #if os(tvOS)
        // Just the address to type in elsewhere: nothing to press, so no focus.
        LabeledContent {
            Text(address.replacingOccurrences(of: "https://", with: ""))
        } label: {
            Label(title, systemImage: systemImage)
        }
        #else
        if let url = URL(string: address) {
            Link(destination: url) {
                Label(title, systemImage: systemImage)
            }
        }
        #endif
    }
}
