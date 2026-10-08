# Connect to Codex's daemon socket as the same user, with no credential of Steer's own

Accepted with the user on 2026-09-14 (issue #42). The user also chose to install Codex's managed standalone package so a daemon can run; the live proof in `docs/user-input-requests.md` is still to be recorded.

When Codex's local app-server daemon is running, Steer may answer a `request_user_input` question exactly, by call id, by being a second JSON-RPC client on `~/.codex/app-server-control/app-server-control.sock`. The question this ADR settles is how Steer authenticates to that socket.

Proposal: rely on the daemon's own protection and add nothing. The daemon creates the socket inside a directory that is private to the user (mode 0700), and the local control socket has no token, pairing, or credential of its own; remote control is a separate, opt-in websocket enrollment that Steer never enables or uses. Steer therefore:

- connects only to that exact path under the user's home (or a `--daemon-socket` override in a lab), and only when the file is a Unix socket owned by the current user with no group or other permission bits (`AppServerSocketCheck`); anything looser is refused and reported in the controls window, never connected. Amended 2026-10-08: Codex 0.161 makes that path a symlink to a socket in `/private/tmp/codex-daemon-<uid>/`. One level of symlink is followed only when the link is owned by the user and its absolute target is a socket passing the same checks inside a directory owned by the user with no group or other permission bits; that directory's mode is what keeps another user from substituting the socket in world-writable `/tmp`. A relative target, a second link, or a looser directory is refused. Because `connect` follows the link again after the check, Steer then requires the accepting process to run as the same user (`getpeereid`) and talks to nothing else; the herdr socket gets the same peer check;
- identifies itself as `steer` in `initialize`, so the daemon's own logs and the TUI can tell the client apart;
- holds no secret, passes no environment variable, and never enables, pairs, or reads remote control;
- subscribes (`thread/resume`) only to thread ids the daemon reports as already loaded, so it never loads a thread from disk into the daemon, and unsubscribes nothing it did not subscribe;
- writes exactly two kinds of message: its own requests (`initialize`, `initialized`, `thread/loaded/list`, `thread/resume`) and one response per question request the user answered in the notch.

Consequences: any process running as the user could do the same, which is already true of the rollouts, hooks and state files Steer reads; the socket does not widen that. If a Codex release adds a credential to the control socket, Steer stops connecting (the handshake fails closed) until this decision is revisited. Steer never starts, restarts, stops, bootstraps or updates the daemon: that stays the user's workflow (ADR 0001).

Rejected: a Steer-side token or allowlist (there is nothing for the daemon to check it against); connecting through `codex app-server proxy` as a child process (the same socket with an extra process, and it would tie Steer to a CLI path); the remote-control websocket (a network listener with pairing, far more than one local answer needs).

Prerequisite: on this machine `codex app-server daemon start` refused to run until Codex's managed standalone package was installed beside the Homebrew CLI (`docs/evidence/app-server-daemon.json`); the user chose to install it. Until a daemon runs and the live proof in `docs/user-input-requests.md` passes, the daemon path is a draft integration, not a capability.
