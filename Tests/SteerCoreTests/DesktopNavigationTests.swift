import Foundation
import Testing
@testable import SteerCore

@Test @MainActor func navigationNeverConfusesDeliveryWithTaskSelection() async {
    let taskID = "01a08f1d-1129-7b91-8056-de6cbc656b0b"
    let app = URL(fileURLWithPath: "/Applications/ChatGPT.app")
    let other = URL(fileURLWithPath: "/Users/test/Applications/Codex.app")
    var calls = 0
    let opener: (URL, URL) async throws -> Void = { task, installation in
        calls += 1
        #expect(task.absoluteString == "codex://threads/\(taskID)")
        #expect(installation == app)
    }
    let badID = await DesktopNavigation.open(taskID: "../wrong?target=x", runningAppURLs: [app], using: opener)
    #expect(badID == .invalidTask)
    for candidates: [URL?] in [[], [nil]] {
        let result = await DesktopNavigation.open(taskID: taskID, runningAppURLs: candidates, using: opener)
        #expect(result == .unavailable)
    }
    let duplicate = await DesktopNavigation.open(taskID: taskID, runningAppURLs: [app, other], using: opener)
    #expect(duplicate == .ambiguous)
    #expect(calls == 0)
    let delivered = await DesktopNavigation.open(taskID: taskID, runningAppURLs: [app], using: opener)
    #expect(delivered == .requestedUnverified && calls == 1)
    let missing = await DesktopNavigation.open(taskID: "00000000-0000-0000-0000-000000000000", runningAppURLs: [app]) { _, _ in }
    #expect(missing == .requestedUnverified)
    struct OpenError: Error {}
    let failed = await DesktopNavigation.open(taskID: taskID, runningAppURLs: [app]) { _, _ in throw OpenError() }
    #expect(failed == .failed)
}
