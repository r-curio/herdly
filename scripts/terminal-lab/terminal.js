// JXA driver for the Terminal.app live proof (#205). One JSON request per call:
//   osascript -l JavaScript terminal.js '{"op": "...", ...}'
// Terminal tabs have no id, so ops address a tab by its tty and resolve it fresh each call.
function run(argv) {
  const app = Application("com.apple.Terminal");
  const req = JSON.parse(argv[0]);

  function eachTab(fn) {
    app.windows().forEach((w, wi) => {
      (w.tabs() || []).forEach((t, ti) => fn(w, wi, t, ti));
    });
  }
  function find(tty) {
    const hits = [];
    eachTab((w, wi, t, ti) => { if (t.tty() === tty) hits.push({w, t}); });
    if (hits.length !== 1) throw new Error(hits.length + " tabs with tty " + tty);
    return hits[0];
  }
  // On current macOS each Terminal tab is its own scripting window (native window tabbing), so
  // "front window" is the front tab and every tab reports selected = true.
  function current() {
    const out = {frontmost: app.frontmost()};
    try {
      const w = app.windows[0];
      out.window = w.id();
      out.selectedTty = w.selectedTab().tty();
      out.windowName = w.name();
    } catch (e) { out.error = String(e); }
    return out;
  }

  switch (req.op) {
    case "version":
      return JSON.stringify({version: app.version(), windows: app.windows().length});
    case "newWindow": {
      const t = app.doScript(req.text || "");
      delay(0.5);
      return JSON.stringify({tty: t.tty()});
    }
    case "inventory": {
      const out = [];
      eachTab((w, wi, t, ti) => {
        out.push({window: w.id(), windowIndex: wi, tabIndex: ti, windowTabs: w.tabs().length, bounds: w.bounds(),
                  tty: t.tty(), selected: t.selected(), customTitle: t.customTitle(),
                  titleDisplaysCustomTitle: t.titleDisplaysCustomTitle(),
                  windowName: w.name(), busy: t.busy(), processes: t.processes()});
      });
      return JSON.stringify({tabs: out, current: current()});
    }
    case "current":
      return JSON.stringify(current());
    case "contents": {
      const t = find(req.tty).t;
      return JSON.stringify({text: t.contents(), history: t.history()});
    }
    case "doScript": {
      const t = find(req.tty).t;
      const r = app.doScript(req.text, {in: t});
      return JSON.stringify({returnedTty: r ? r.tty() : null});
    }
    case "staleDoScript": {
      // Hold a tab reference, close its window, then run do script against the stale reference.
      const w = app.windows().find((x) => x.id() === req.window);
      const t = w.tabs[0];
      const ttyBefore = t.tty();
      w.close();
      delay(1);
      let result;
      try {
        const r = app.doScript(req.text, {in: t});
        result = {ok: true, returnedTty: r ? r.tty() : null};
      } catch (e) { result = {ok: false, error: String(e)}; }
      return JSON.stringify({ttyBefore, ...result, windowsAfter: app.windows().length});
    }
    case "select": {
      // steps: "tab" (selected = true), "window" (frontmost = true), "activate".
      const hit = find(req.tty);
      (req.steps || []).forEach((step) => {
        if (step === "tab") hit.t.selected = true;
        else if (step === "window") hit.w.frontmost = true;
        else if (step === "index") hit.w.index = 1;
        else if (step === "activate") app.activate();
      });
      return JSON.stringify({done: req.steps});
    }
    case "closeWindow": {
      const w = app.windows().find((x) => x.id() === req.window);
      if (w) w.close();
      return JSON.stringify({ok: !!w});
    }
    default:
      throw new Error("unknown op " + req.op);
  }
}
