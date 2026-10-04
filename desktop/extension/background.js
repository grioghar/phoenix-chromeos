// Phoenix Health: polls the local Phoenix status server, colours the toolbar icon green / yellow /
// red, and raises ChromeOS notifications (they stay in the tray's notification centre) for new issues.
const BASE = "http://127.0.0.1:8098";
const COLORS = { ok: "#2e9b4e", info: "#3b82c4", warning: "#e0a800", critical: "#d93025", unknown: "#9aa0a6" };

function level(issues) {
  if (issues.some(i => i.severity === "critical")) return "critical";
  if (issues.some(i => i.severity === "warning")) return "warning";
  if (issues.length) return "info";
  return "ok";
}

function icon(color) {
  const out = {};
  for (const size of [16, 32]) {
    const c = new OffscreenCanvas(size, size), g = c.getContext("2d");
    g.beginPath(); g.arc(size / 2, size / 2, size * 0.42, 0, 2 * Math.PI);
    g.fillStyle = color; g.fill();
    g.lineWidth = Math.max(1, size / 16); g.strokeStyle = "rgba(0,0,0,0.35)"; g.stroke();
    out[size] = g.getImageData(0, 0, size, size);
  }
  return out;
}

async function refresh() {
  let data;
  try { data = await (await fetch(BASE + "/health", { cache: "no-store" })).json(); }
  catch (e) { data = null; }
  const issues = data ? (data.issues || []) : [];
  const lvl = data ? level(issues) : "unknown";
  await chrome.action.setIcon({ imageData: icon(COLORS[lvl]) });
  await chrome.action.setTitle({ title: data ? (issues.length ? `Phoenix: ${issues.map(i => i.title).join("; ")}` : "Phoenix: all good") : "Phoenix: status not available" });
  await chrome.action.setBadgeText({ text: issues.filter(i => i.severity !== "info").length ? String(issues.filter(i => i.severity !== "info").length) : "" });
  await chrome.action.setBadgeBackgroundColor({ color: COLORS[lvl] });
  await chrome.storage.local.set({ last: data, lvl, at: Date.now() });

  // notify once per new issue (and again if it comes back after being resolved)
  const { seen = [] } = await chrome.storage.local.get("seen");
  const ids = issues.map(i => i.id);
  for (const i of issues) {
    if (seen.includes(i.id) || i.severity === "info") continue;
    chrome.notifications.create("phoenix-" + i.id, {
      type: "basic", iconUrl: "icon128.png", title: "Phoenix: " + i.title, message: i.message,
      priority: i.severity === "critical" ? 2 : 1, requireInteraction: i.severity === "critical"
    });
  }
  await chrome.storage.local.set({ seen: ids });
}

async function schedule() {
  let interval = 300;
  try { interval = (await (await fetch(BASE + "/config", { cache: "no-store" })).json()).interval || 300; } catch (e) {}
  await chrome.alarms.create("phoenix-health", { periodInMinutes: Math.max(1, interval / 60) });
}

chrome.runtime.onInstalled.addListener(() => { schedule(); refresh(); });
chrome.runtime.onStartup.addListener(() => { schedule(); refresh(); });
chrome.alarms.onAlarm.addListener(a => { if (a.name === "phoenix-health") { refresh(); schedule(); } });
chrome.runtime.onMessage.addListener((m, s, reply) => { if (m === "refresh") refresh().then(() => reply(true)); return true; });
