# Send notify-only phone alerts through ntfy

Accepted on 2026-10-22 ([issue #352](https://github.com/r-curio/herdly/issues/352)). This is Herdly's first feature that sends anything off the Mac. When the user turns it on and the Mac has had no input for 2 minutes, a newly arrived approval, question or completion becomes one short alert. Herdly POSTs it to the public ntfy server (`https://ntfy.sh`) on a private random topic. The user's iPhone receives it through the ntfy app.

## Decision

- **Notify-only.** The alert has no Allow, Deny or answer buttons, and tapping it does nothing on the Mac. Approvals keep their 30-second deadline on the Mac, and a phone round trip would rarely beat it. Deciding from the phone would need its own ADR.
- **Content.** Only fixed wording, the agent name and the project folder name leave the Mac. Prompts, responses, commands, option text and full paths never do.
- **Once at arrival.** The rule is pure, in `PhoneAlertPolicy`, with the bounded `PhoneAlertLedger`. Idle is read once, when the item arrives. Restored items, repeats and items that arrived while the user was active never send.
- **Fail open.** One detached POST with a 10-second timeout and no retry. It never touches the queue, acknowledgment or deadlines.
- **Topic.** The topic is the only secret: anyone who knows it can read the alerts.
  - It is "herdly-" plus 20 random base32 characters, stored as a login-Keychain generic password and read off the main actor.
  - A new topic is created only when no item exists, so a read error never replaces one the phone is already subscribed to.
  - It uses the login Keychain rather than the data-protection keychain because ad-hoc builds cannot hold the entitlement that keychain needs. After a rebuild, macOS may ask once for access.
- **Seam.** `PhoneAlertSender` takes a message, and `NtfyPhoneAlertSender` is its only implementation. A native Herdly iPhone app using Apple push would replace only the sender and the Topic row in Settings.
- **Wire format.** ntfy's JSON publish (`{topic,title,message,priority,tags}` to the server root), not `Title` headers. Project names can be non-ASCII, and HTTP header values cannot carry them safely.

## Considered options

- **A Herdly iPhone app on the local network (the Open Island approach).** The Mac serves events over Bonjour and HTTP to a companion app on the same Wi-Fi. Rejected: without Apple push, iOS suspends the app's connection soon after it is backgrounded, so alerts mostly stop while the phone is in a pocket. It also works only on the same network, and it means maintaining an iOS app.
- **A Herdly iPhone app on Apple push now.** Herdly could send to Apple's push service directly. It needs a paid Apple Developer account, about 3–4 days of work, and yearly re-signing. Deferred until the account exists. The sender seam keeps that switch to the sender plus the Topic row.
- **Pushover.** Equivalent effort, with a one-time $5 license per user. ntfy is free, open source and can be self-hosted later; the server URL is a constant, not a setting.
- **Alert at any time, not only when idle.** Rejected: at the desk the notch already covers it.

## Not yet shown live

- **Delivery:** an alert reaching a locked iPhone on cellular from the real arrival path. Only a manual `curl` publish to a throwaway topic has reached the user's phone, on 2026-10-22.
- **Keychain prompt:** whether macOS asks again after every ad-hoc rebuild.
