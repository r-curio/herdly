# Launch-at-login evidence

Issue: [Add a native launch-at-login setting](https://github.com/r-curio/herdly/issues/56)

Status: automated checks cover state presentation and reconciliation without changing the user's login item. Installed-app checks require human interaction and remain unverified until the table below records an artifact and observation.

## Automated boundary

`LaunchAtLoginState` is tested with supplied registration observations. These tests do not call `SMAppService.register()` or `unregister()`. The app adapter is the only code that mutates the real ServiceManagement registration, and it always reads `SMAppService.mainApp.status` again after an attempted change.

## Installed-app checks

Record **pass**, **fail**, or **uncertain**, the date, and the packaged artifact manifest SHA-256. Do not infer one row from another.

| Scenario | Expected observation | Result | Date | Artifact SHA-256 |
| --- | --- | --- | --- | --- |
| Default off | A newly installed app reports **Off** and does not launch at the next sign-in. | Pending | | |
| Enable | Turning the switch on results in **On**, or accurately reports **Approval required** with a working System Settings action. | Pending | | |
| Login launch | After sign-out and sign-in, the registered app starts without opening its controls window; the menu-bar item and notch remain available. | Pending | | |
| Disable | Turning the switch off reports **Off**, and Steer does not launch after the next sign-in. | Pending | | |
| Replace in place | Replacing the installed bundle at the same path leaves the UI matching macOS's actual status; no automatic repair occurs. | Pending | | |
| Relocate app | Moving between `/Applications` and `~/Applications` leaves the UI matching macOS's actual status and gives accurate recovery guidance if unavailable. | Pending | | |

These observations establish installed behavior only for the recorded artifact and host. A package build or smoke test does not complete this table.
