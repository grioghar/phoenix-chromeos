const BASE = "http://127.0.0.1:8098";
const COLORS = { ok: "#2e9b4e", info: "#3b82c4", warning: "#e0a800", critical: "#d93025", unknown: "#9aa0a6" };
// setting -> [label, help, choices]
const SETTINGS = {
  performance_mode:   ["Performance mode", "Faster on older CPUs, less protected against CPU flaws (after reboot)", ["off", "on"]],
  throttle_override:  ["Throttle override", "Undo firmware throttling (dead battery, unknown charger)", ["on", "off"]],
  thermal_guard:      ["Thermal guard", "Lower the speed when the CPU gets too hot", ["on", "off"]],
  thermal_limit:      ["Temperature limit (°C)", "The guard keeps the CPU at or below this", ["80", "85", "90", "95", "100"]],
  cpu_profile:        ["CPU profile", "", ["balanced", "performance", "quiet"]],
  fan_mode:           ["Fan", "Firmware decides, or a Phoenix fan curve", ["bios", "auto", "quiet", "max"]],
  android_animations: ["Android animations", "1 = normal, 0.5 = faster, 0 = off", ["1", "0.5", "0"]],
  maintenance:        ["Daily maintenance", "", ["on", "off"]],
  health_interval:    ["Check every", "", ["60", "300", "900", "3600"]],
};
const LABELS = { "60": "1 min", "300": "5 min", "900": "15 min", "3600": "1 hour" };

async function renderIssues() {
  const { last, lvl = "unknown", at } = await chrome.storage.local.get(["last", "lvl", "at"]);
  document.getElementById("dot").style.background = COLORS[lvl];
  const issues = last ? (last.issues || []) : [];
  document.getElementById("summary").textContent =
    !last ? "Phoenix status not available" : issues.length ? `${issues.length} thing(s) need attention` : "All good";
  const list = document.getElementById("list"); list.textContent = "";
  for (const i of issues) {
    const d = document.createElement("div"); d.className = "issue";
    const b = document.createElement("b"); const s = document.createElement("span");
    s.className = "dot"; s.style.background = COLORS[i.severity] || COLORS.info; b.append(s, i.title);
    const p = document.createElement("p"); p.textContent = i.message; d.append(b, p); list.append(d);
  }
  document.getElementById("when").textContent = at ? "Checked " + new Date(at).toLocaleTimeString() : "";
}

async function renderSettings() {
  let st;
  try { st = await (await fetch(BASE + "/settings", { cache: "no-store" })).json(); }
  catch (e) { document.getElementById("live").textContent = "Phoenix is not reachable."; return; }
  document.getElementById("live").textContent =
    `${st.machine} · ${st.cpu_mhz} MHz (max ${st.cpu_max_mhz}) · ${st.temp_c} °C` +
    (st.settings.performance_mode === "on" && !st.settings.performance_active ? " · performance mode after reboot" : "");
  const box = document.getElementById("settings"); box.textContent = "";
  for (const [key, [label, help, choices]] of Object.entries(SETTINGS)) {
    const row = document.createElement("div"); row.className = "row";
    const l = document.createElement("div"); l.textContent = label;
    if (help) { const h = document.createElement("small"); h.textContent = help; l.append(h); }
    const sel = document.createElement("select");
    const cur = String(st.settings[key]);
    for (const c of (choices.includes(cur) ? choices : [cur, ...choices])) {
      const o = document.createElement("option"); o.value = c; o.textContent = LABELS[c] && key === "health_interval" ? LABELS[c] : c;
      if (c === cur) o.selected = true; sel.append(o);
    }
    sel.onchange = () => change(key, sel.value);
    row.append(l, sel); box.append(row);
  }
}

async function change(key, value) {
  const msg = document.getElementById("msg");
  if (key === "performance_mode" && value === "on" &&
      !confirm("Performance mode turns off the CPU's security workarounds (Spectre, Meltdown...). " +
               "Faster, but a malicious website or app could read memory of other programs. Turn it on?")) {
    renderSettings(); return;
  }
  const r = await fetch(BASE + "/set", { method: "POST", body: `${key}=${value}` });
  const j = await r.json().catch(() => ({}));
  msg.textContent = r.ok ? (j.reboot ? "Saved. Takes effect after a reboot." : "Saved.") : (j.error || "Not saved.");
  renderSettings();
}

document.getElementById("refresh").onclick = () => chrome.runtime.sendMessage("refresh", () => { renderIssues(); renderSettings(); });
renderIssues(); renderSettings();
