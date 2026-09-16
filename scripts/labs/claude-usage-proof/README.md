# Claude usage proof prototype

Throwaway native prototype behind [the proof](../../../docs/claude-usage-proof.md). It is not product code or an installer.

```sh
mkdir -p snapshots
swiftc NativeForward.swift -o native-forward
printf '%s' '{"version":"2.1.273"}' | ./native-forward 'cat'
```

Point a disposable command-line `statusLine.command` at `native-forward '<existing command>'` to reproduce the live rendering check. Use `descendant-status.sh` only in a disposable session: it demonstrates why setup must reject composition when the cancellation/exit probe fails.
