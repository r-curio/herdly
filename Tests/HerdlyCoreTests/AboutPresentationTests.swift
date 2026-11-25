import Testing
@testable import HerdlyCore

// Settings › About (AB2, AB4, #483): the version pill's text and copy, and the Works with lists.

@Test func versionPillShowsVersionWithDimmedBuildAndCopiesBoth() {
    let pill = AboutVersion(infoDictionary: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "620"])
    #expect(pill.primaryText == "0.1.0")
    #expect(pill.buildText == " (build 620)")
    #expect(pill.copyText == "0.1.0 (620)")
    #expect(pill.accessibilityLabel == "Version 0.1.0, build 620")
}

@Test func versionPillWithoutBuildShowsAndCopiesVersionOnly() {
    let pill = AboutVersion(version: "0.1.0", build: "  ")
    #expect(pill.buildText == nil)
    #expect(pill.copyText == "0.1.0")
    #expect(pill.accessibilityLabel == "Version 0.1.0")
}

@Test func versionPillWithoutVersionReadsDevelopmentAndDropsBuild() {
    for pill in [AboutVersion(infoDictionary: nil), AboutVersion(version: "", build: "620"),
                 AboutVersion(infoDictionary: ["CFBundleVersion": "620"])] {
        #expect(pill.primaryText == "Development")
        #expect(pill.buildText == nil)
        #expect(pill.copyText == "Development")
        #expect(pill.accessibilityLabel == "Version Development")
    }
}

@Test func worksWithListsAgentsAndEveryShownHostInSettingsOrder() {
    #expect(AboutWorksWith.agents == ["Codex desktop", "Codex CLI", "Claude Code", "Claude Desktop"])
    #expect(AboutWorksWith.terminals == TerminalHost.terminals.filter(\.showsCard).map(\.displayName))
    #expect(AboutWorksWith.multiplexers == TerminalHost.multiplexers.filter(\.showsCard).map(\.displayName))
    #expect(AboutWorksWith.terminals.first == "Ghostty")
    #expect(Set(AboutWorksWith.terminals).isDisjoint(with: AboutWorksWith.multiplexers))
}
