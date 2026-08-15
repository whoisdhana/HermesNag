// HermesNag — iOS home-screen widget (Scriptable app, free on the App Store)
//
// Setup:
//   1. Install "Scriptable" from the App Store
//   2. New script → paste this file → set TOKEN below
//   3. Long-press home screen → add a Scriptable widget → choose this script
//   4. Tailscale app must be connected (the URL is tailnet-only)
//
// Tapping the widget opens the full mobile page.

const BASE = "https://YOUR-BOX.your-tailnet.ts.net:10003";
const TOKEN = "PASTE-YOUR-TOKEN-HERE";

const ACCENT = new Color("#ff9900");
const RED = new Color("#ff5555");
const DIM = new Color("#999999");

async function get(path) {
  const r = new Request(BASE + path);
  r.headers = { Authorization: "Bearer " + TOKEN };
  r.timeoutInterval = 10;
  return await r.loadJSON();
}

async function build() {
  const w = new ListWidget();
  w.backgroundColor = new Color("#111111");
  w.url = BASE + "/m";
  w.setPadding(14, 14, 12, 14);

  const title = w.addText("🔔 HermesNag");
  title.font = Font.boldSystemFont(13);
  title.textColor = Color.white();
  w.addSpacer(8);

  try {
    const [tasks, habits] = await Promise.all([get("/tasks"), get("/habits?active=true")]);
    const open = tasks.tasks.filter(t => ["pending", "snoozed"].includes(t.status));
    const due = habits.habits.filter(h => h.enabled && h.in_active_hours && h.is_due);

    // must-priority first, then by due date
    open.sort((a, b) =>
      (b.priority === "must") - (a.priority === "must")
      || ((a.due_at || "9") < (b.due_at || "9") ? -1 : 1));

    if (!open.length && !due.length) {
      const ok = w.addText("All clear ✓");
      ok.font = Font.systemFont(12);
      ok.textColor = DIM;
    }

    for (const t of open.slice(0, 3)) {
      const row = w.addText((t.priority === "must" ? "❗ " : "○ ") + t.title);
      row.font = Font.systemFont(12);
      row.textColor = t.priority === "must" ? RED : Color.white();
      row.lineLimit = 1;
      w.addSpacer(3);
    }

    for (const h of due.slice(0, 2)) {
      const row = w.addText("→ " + h.name);
      row.font = Font.systemFont(11);
      row.textColor = ACCENT;
      row.lineLimit = 1;
      w.addSpacer(2);
    }

    w.addSpacer();
    const foot = w.addText(
      `${open.length} open · updated ${new Date().toLocaleTimeString("en-IN",
        { hour: "2-digit", minute: "2-digit" })}`);
    foot.font = Font.systemFont(9);
    foot.textColor = DIM;
  } catch (e) {
    const err = w.addText("Offline — is Tailscale on?");
    err.font = Font.systemFont(11);
    err.textColor = DIM;
  }

  // Ask iOS to refresh roughly every 15 minutes.
  w.refreshAfterDate = new Date(Date.now() + 15 * 60 * 1000);
  return w;
}

const widget = await build();
if (config.runsInWidget) {
  Script.setWidget(widget);
} else {
  widget.presentMedium();
}
Script.complete();
