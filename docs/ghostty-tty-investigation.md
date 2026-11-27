# Ghostty terminal `tty`: first release and feature check (#117)

Checked 2026-10-07 for [Find the first Ghostty release that exposes terminal tty](https://github.com/r-curio/herdly/issues/117). It answers the open point in [ADR 0011](adr/0011-open-herdr-panes-only-through-an-exact-ghostty-tty-join.md) and the feature-check rule in [Agreed terminal host presentation](product.md#agreed-terminal-host-presentation).

## Answer

1. **No stable Ghostty release exposes a terminal's `tty` yet.** The latest stable release is 1.3.1 (2026-03-13), and it lacks the property. The property is merged on `main` for the open 1.4.0 milestone, but 1.4.0 has not been released. The first release expected to ship it is 1.4.0 (as of 2026-10-07). That is an inference from the milestone, not a verified release.
2. **Dictionary entry (on `main`):** class `terminal` (code `Gtrm`), property `tty`, code `Gtty`, type `text`, read-only. The sibling property `pid` (code `Gpid`, `integer`) arrived in the same PR.
3. **Feature check:** read the scripting dictionary of the Ghostty bundle Herdly will drive. Treat the feature as present only if class `terminal` declares a property with code `Gtty`. This needs no version comparison and sends no Apple Events. At runtime, an empty `tty` string still means "cannot identify" for that terminal.

## Verified facts

### Release status

| Check | Result | Source |
| --- | --- | --- |
| GitHub releases | Only `tip` (the nightly pre-release) is listed. Stable versions are published as tags. | `gh release list -R ghostty-org/ghostty` |
| Stable tags | Newest is `v1.3.1`. There is no `v1.3.2` or `v1.4.0` tag. | `gh api repos/ghostty-org/ghostty/tags` |
| Official release notes | Newest is 1.3.1 (March 13, 2026). Neither 1.3.2 nor 1.4.0 is listed. | [ghostty.org release notes](https://ghostty.org/docs/install/release-notes) |
| Milestones | 1.4.0 is open (744 closed, 29 open issues). 1.3.2 is open (due 2026-05-31, 2 open issues). | `gh api repos/ghostty-org/ghostty/milestones?state=all` |
| Homebrew cask (secondary cross-check) | `ghostty` cask version is 1.3.1. | `https://formulae.brew.sh/api/cask/ghostty.json` |

### The change

- Request: [ghostty#11592](https://github.com/ghostty-org/ghostty/issues/11592), "macOS: Add pid and tty properties to AppleScript terminal class". Closed 2026-04-20.
- Implementation: [ghostty#11922](https://github.com/ghostty-org/ghostty/pull/11922), "macos: add pid and tty properties to AppleScript terminal and App Intents TerminalEntity". Merged 2026-04-20 into `main` as `afdae7293abfdf5daa684dc50c35420b61a1d575`, milestone **1.4.0**. It changes `macos/Ghostty.sdef`, `ScriptTerminal.swift`, `Ghostty.Surface.swift`, `TerminalEntity.swift`, `src/apprt/embedded.zig`, `include/ghostty.h` and `src/config/CApi.zig`. Despite the issue title, App Intents also gets the values.
- Containment: GitHub's compare shows the merge commit 702 commits ahead of and 0 behind both `v1.3.1` and the `1.3.x` branch. So it is not in 1.3.1 and not on the 1.3.x maintenance line.
- `macos/Ghostty.sdef` contains no `Gtty` at `v1.3.1` or on `1.3.x`. It does contain it at the merge commit and on `main` (`b699ea79f4`, 2026-10-07).

### Dictionary entry

From `macos/Ghostty.sdef` on `main`, inside `<class name="terminal" code="Gtrm" ...>`:

```xml
<property name="pid" code="Gpid" type="integer" access="r" description="PID of the foreground process in this terminal."/>
<property name="tty" code="Gtty" type="text" access="r" description="TTY device path for this terminal (e.g. /dev/ttys016)."/>
```

The getter in `macos/Sources/Features/AppleScript/ScriptTerminal.swift` on `main`:

```swift
@objc(tty)
var tty: String {
    guard NSApp.isAppleScriptEnabled else { return "" }
    return surfaceView?.surfaceModel?.ttyName ?? ""
}
```

So a Ghostty that declares the property still returns `""` when AppleScript is disabled in Ghostty or the surface has no model. It does not raise an error in those cases.

### Reading it

These snippets come from the PR's own smoke test (`get tty of every terminal`, `get {id, pid, tty, working directory} of terminal 1`). They match Herdly's JXA style in `Sources/HerdlyApp/Resources/Ghostty.js`. They were **not** run here, because the installed Ghostty lacks the property and this task sends no Apple Events.

```sh
osascript -e 'tell application id "com.mitchellh.ghostty" to get {id, tty} of every terminal'
```

```js
// JXA, alongside Ghostty.js's inventory()
t.terminals().map(p => ({id: p.id(), name: p.name(), tty: p.tty()}))
```

### Installed app

- `/Applications/Ghostty.app` is version 1.3.1 (build 15212). `Info.plist` key `OSAScriptingDefinition` is `Ghostty.sdef`.
- The `terminal` class in `sdef /Applications/Ghostty.app` declares `id`, `name`, `working directory` and the surface-configuration properties. It declares no `tty` and no `pid`.
- The bundle's `Contents/Resources/Ghostty.sdef`, the output of `sdef /Applications/Ghostty.app`, and `macos/Ghostty.sdef` at tag `v1.3.1` have the same SHA-256 (`0ac1bbd8…2adf`). The shipped dictionary is the source-tree file at that tag.
- `python3 scripts/probe_ghostty.py` (read-only, no Apple Events) reports `native_tty_mapping_available: false` for this bundle. The probe already implements the dictionary check below, matching by property name.

## Feature check for Herdly

Recommended, with no version comparison. Implemented as recommended in `Sources/HerdlyCore/GhosttyTTY.swift` (`GhosttyScriptingDictionary`, `GhosttyTTYMatch`) and `GhosttyScriptingSupport` in `Sources/HerdlyApp/GhosttyNavigation.swift`, except that step 4 is met by reading the dictionary fresh on each check rather than tracking bundle changes:

1. Resolve the Ghostty bundle Herdly will actually drive. Prefer the running `com.mitchellh.ghostty` app's `NSRunningApplication.bundleURL`, and fall back to `NSWorkspace.urlForApplication(withBundleIdentifier:)`. Do not hard-code `/Applications`.
2. Read `Contents/Info.plist` → `OSAScriptingDefinition` (currently `Ghostty.sdef`) from `Contents/Resources/`, with bounded size and safe file access. `sdef <bundle>` returns the same XML but spawns a process.
3. Parse the XML. The feature is present only if a `class` with `code="Gtrm"` contains a `property` with `code="Gtty"` and `type="text"`. Matching the four-character codes is more robust than matching names. A missing, unreadable or malformed dictionary means "cannot identify", never "supported".
4. Recheck when the bundle changes (path, `CFBundleVersion` or the dictionary file's modification date), since Ghostty can be updated while Herdly runs. Fail closed: if the check is stale or uncertain, herdr Open is unavailable.
5. At runtime, a declared property is necessary but not sufficient. An empty or non-`/dev/ttys*` value for a terminal, or zero or several matches, still yields "Ghostty cannot identify herdr's tab" (ADR 0011).

Rejected as the primary check: attempting `get tty of …` and treating an error as unsupported. It needs a running Ghostty and Automation permission, and it sends Apple Events just to probe. The error an older Ghostty returns for the raw code `«class Gtty»` was not observed here. A raw-code read is also ambiguous with the `""` that a supporting Ghostty returns when scripting is disabled.

## Inferences and open points

- **First release:** as of 2026-10-07, 1.4.0 is the likely first stable release with `tty`, because the change carries that milestone and is absent from `1.3.x`. A 1.3.2 cut from `1.3.x` would not include it unless backported. Verify by checking the released bundle's dictionary for `Gtty`, then update the "Update Ghostty" wording in `product.md` with the version. `product.md` already holds back the version name until this is verified.
- **Compile-time probing does not work:** `osacompile -e 'tell application "Ghostty" to get tty of every terminal'` compiled without error against 1.3.1 (no events sent). AppleScript accepts an unknown identifier as a variable, so compiling cannot detect the feature.
- **Live proof pending:** no released Ghostty with `tty` was available, so the runtime value, its `/dev/ttysNNN` form and agreement with `lsof` are unproven here. The PR author reports checking `pid` and `tty` against `ps` and `lsof` on a development build.
