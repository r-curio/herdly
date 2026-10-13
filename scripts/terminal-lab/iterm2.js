// JXA driver for the iTerm2 live proof (#204). One JSON request per call:
//   osascript -l JavaScript iterm2.js '{"op": "...", ...}'
// Every op addresses sessions by their GUID; none of them touches a session
// the caller did not name, except `inventory`, which only reads.
// Lab only: `Application(bundleID)` launches iTerm2 if it quit before an event, so this can relaunch a
// quit iTerm2. Steer's own adapter addresses the process id instead (#270, Resources/AppleEvents.js).
function run(argv) {
  const app = Application("com.googlecode.iterm2");
  const req = JSON.parse(argv[0]);

  function eachSession(fn) {
    // A window or tab that closes mid-walk returns null collections; skip it.
    app.windows().forEach((w, wi) => {
      (w.tabs() || []).forEach((t, ti) => {
        (t.sessions() || []).forEach((s) => fn(w, wi, t, ti, s));
      });
    });
  }
  function find(id) {
    let hit = null;
    eachSession((w, wi, t, ti, s) => { if (s.id() === id) hit = {w, t, s}; });
    if (!hit) throw new Error("session not found: " + id);
    return hit;
  }
  function v(s, name) {
    try { return s.variable({named: name}); } catch (e) { return null; }
  }
  function current() {
    const out = {frontmost: app.frontmost()};
    try {
      const w = app.currentWindow();
      const t = w.currentTab();
      out.window = w.id();
      out.session = t.currentSession().id();
      out.tabSessions = t.sessions().length;
    } catch (e) { out.error = String(e); }
    return out;
  }

  switch (req.op) {
    case "version":
      return JSON.stringify({version: app.version(), windows: app.windows().length});
    case "newWindow": {
      const w = app.createWindowWithDefaultProfile();
      const s = w.currentSession();
      return JSON.stringify({window: w.id(), session: s.id(), tty: s.tty()});
    }
    case "newTab": {
      const w = app.windows().find((x) => x.id() === req.window);
      const t = w.createTabWithDefaultProfile();
      const s = t.currentSession();
      return JSON.stringify({session: s.id(), tty: s.tty()});
    }
    case "split": {
      const s = find(req.session).s.splitVerticallyWithDefaultProfile();
      return JSON.stringify({session: s.id(), tty: s.tty()});
    }
    case "write": {
      const s = find(req.session).s;
      s.write({text: req.text, newline: req.newline !== false});
      return JSON.stringify({ok: true});
    }
    case "contents":
      return JSON.stringify({text: find(req.session).s.contents()});
    case "close":
      find(req.session).s.close();
      return JSON.stringify({ok: true});
    case "inventory": {
      const out = [];
      eachSession((w, wi, t, ti, s) => {
        out.push({window: w.id(), windowIndex: wi, tabIndex: ti, tabSessions: t.sessions().length,
                  session: s.id(), tty: s.tty(), name: s.name(),
                  terminalWindowName: v(s, "terminalWindowName"),
                  terminalIconName: v(s, "terminalIconName"),
                  jobName: v(s, "jobName"), deepestJob: v(s, "deepestJob"),
                  jobPid: v(s, "jobPid"), processTitle: v(s, "processTitle"),
                  termid: v(s, "termid")});
      });
      return JSON.stringify({sessions: out, current: current()});
    }
    case "current":
      return JSON.stringify(current());
    case "select": {
      // steps: any of "window", "tab", "session", "activate", in the given order.
      const hit = find(req.session);
      const done = [];
      (req.steps || []).forEach((step) => {
        if (step === "window") hit.w.select();
        else if (step === "tab") hit.t.select();
        else if (step === "session") hit.s.select();
        else if (step === "activate") app.activate();
        done.push(step);
      });
      return JSON.stringify({done});
    }
    default:
      throw new Error("unknown op " + req.op);
  }
}
