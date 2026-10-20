import Testing
@testable import HerdlyCore

@Test func registryListsTerminalsThenMultiplexersInSettingsOrder() {
    #expect(TerminalHost.terminals == [.ghostty, .iTerm2, .terminalApp, .wezTerm])
    #expect(TerminalHost.multiplexers == [.tmux, .zellij, .herdr])
    #expect(TerminalHost.allCases.map(\.displayName)
        == ["Ghostty", "iTerm2", "Terminal.app", "WezTerm", "tmux", "Zellij", "herdr"])
    // Only hosts whose acceptance has passed show a card: iTerm2 since #243, Terminal.app since #244,
    // WezTerm since #245; tmux and Zellij stay hidden until theirs.
    #expect(TerminalHost.allCases.filter(\.showsCard) == [.ghostty, .iTerm2, .terminalApp, .wezTerm, .herdr])
    #expect(TerminalHost.terminals.filter(\.showsCard) == [.ghostty, .iTerm2, .terminalApp, .wezTerm])
    #expect(TerminalHost.multiplexers.filter(\.showsCard) == [.herdr])
    // Ghostty keeps its existing preference key so its stored choice carries over unchanged.
    #expect(TerminalHost.ghostty.defaultsKey == "ghosttyControlsEnabled")
    #expect(Set(TerminalHost.allCases.map(\.defaultsKey)).count == TerminalHost.allCases.count)
}

@Test func upgradeStartsHerdrWhereTheGhosttySwitchWas() {
    for ghostty in [true, false] {
        let restored = TerminalHostSwitches.restore(stored: [.ghostty: ghostty])
        #expect(restored.switches.isOn(.herdr) == ghostty)
        #expect(restored.switches.isOn(.ghostty) == ghostty)
        // Written back once, so a later Ghostty change no longer moves herdr.
        #expect(restored.toPersist == [.herdr: ghostty])
    }
}

@Test func freshInstallStartsEverySwitchOff() {
    let restored = TerminalHostSwitches.restore(stored: [:])
    #expect(restored.switches == TerminalHostSwitches())
    #expect(TerminalHost.allCases.allSatisfy { !restored.switches.isOn($0) })
    #expect(restored.toPersist == [.herdr: false])
}

@Test func newSwitchesOtherThanHerdrStartOffOnUpgrade() {
    let restored = TerminalHostSwitches.restore(stored: [.ghostty: true])
    for host in [TerminalHost.iTerm2, .terminalApp, .wezTerm, .tmux, .zellij] {
        #expect(!restored.switches.isOn(host))
    }
}

@Test func storedHerdrChoiceIsKeptAfterTheUpgrade() {
    let restored = TerminalHostSwitches.restore(stored: [.ghostty: true, .herdr: false, .tmux: true])
    #expect(!restored.switches.isOn(.herdr))
    #expect(restored.switches.isOn(.tmux))
    #expect(restored.toPersist.isEmpty)
}

@Test func switchedOffHostsAreNeverContacted() {
    var switches = TerminalHostSwitches()
    #expect(TerminalHost.allCases.allSatisfy { !switches.mayContact($0) })
    switches.set(.ghostty, on: true)
    #expect(switches.mayContact(.ghostty))
    #expect(!switches.mayContact(.herdr))
    #expect(!switches.mayContact(.iTerm2))
    switches.set(.ghostty, on: false)
    #expect(!switches.mayContact(.ghostty))
}

@Test func aMultiplexerIsContactedOnlyWhileATerminalIsAlsoOn() {
    var switches = TerminalHostSwitches(enabled: [.herdr])
    #expect(switches.isOn(.herdr))
    #expect(!switches.anyTerminalOn)
    #expect(!switches.mayContact(.herdr))
    switches.set(.ghostty, on: true)
    #expect(switches.anyTerminalOn)
    #expect(switches.mayContact(.herdr))
}
