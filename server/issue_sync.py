#!/usr/bin/env python3
"""Daily intake of `phoenix submit` hardware reports from GitHub issues (runs on the Phoenix server).

For each new open issue labeled hardware-report:
  - saves the issue (title, body, author, link) to INTAKE/issues/<number>.md
  - extracts the machine identity and the Phoenix assessment from the report
  - writes a draft machine profile to INTAKE/drafts/<vendor>/<model>.conf when Phoenix has no
    profile for that machine yet (a person reviews it and moves it into profiles/)
  - appends a one-line summary to INTAKE/summary.log
Reading public issues needs no token; GITHUB_TOKEN (or the server token file) raises rate limits.
State (the last issue number handled) is kept in INTAKE/state.json.

  issue_sync.py [--all]     --all: re-process every open report
"""
import json, os, re, sys, time, urllib.request

REPO = "grioghar/phoenix-chromeos"
PHOENIX = os.environ.get("PHOENIX_REPO", "/root/phoenix")
INTAKE = os.environ.get("PHOENIX_INTAKE", "/root/phoenix-intake")
TOKEN_FILE = "/root/phoenix-secrets/github-token"

def api(path):
    req = urllib.request.Request("https://api.github.com" + path, headers={
        "Accept": "application/vnd.github+json", "User-Agent": "phoenix-issue-sync"})
    tok = os.environ.get("GITHUB_TOKEN") or (open(TOKEN_FILE).read().strip() if os.path.isfile(TOKEN_FILE) else "")
    if tok: req.add_header("Authorization", "Bearer " + tok)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)

def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")

def field(text, key):
    m = re.search(r"^%s: (.*)$" % re.escape(key), text, re.M)
    return m.group(1).strip() if m else ""

def draft_profile(report, number, url):
    vendor = field(report, "sys_vendor"); model = field(report, "product_name")
    if vendor == "LENOVO": model = field(report, "product_version") or model
    if not vendor or not model or vendor == "?": return None, "no DMI identity in report"
    rel = os.path.join(slug(vendor.split()[0]), slug(model) + ".conf")
    if os.path.exists(os.path.join(PHOENIX, "profiles", rel)):
        return None, "profile already exists: profiles/" + rel
    g = lambda k: (re.search(r"^\s*%s=(.*)$" % re.escape(k), report, re.M) or [None, ""])[1].strip()
    lines = [f"# DRAFT from hardware report #{number}: {url}",
             f"# {vendor} {model} -- review before moving into profiles/{rel}",
             f"# Problem reported: {field(report, 'problem')}",
             f"# Assessment: cpu={g('cpu.name')} gpu={g('gpu.main')}/{g('gpu.stack')} firmware={g('firmware')} "
             f"touchpad={g('input.touchpad')} fan={g('fan.control')} android={g('android')}"]
    tp = g("input.touchpad")
    if tp and tp not in ("none", "unknown"): lines.append(f"touchpad={tp}")
    lines += ["cpu_profile=balanced", "fan_mode=bios", f"notes=from hardware report #{number}"]
    path = os.path.join(INTAKE, "drafts", rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write("\n".join(lines) + "\n")
    return path, "draft written"

def main():
    os.makedirs(os.path.join(INTAKE, "issues"), exist_ok=True)
    state_f = os.path.join(INTAKE, "state.json")
    state = json.load(open(state_f)) if os.path.isfile(state_f) else {"last": 0}
    last = 0 if "--all" in sys.argv else state["last"]
    issues = api(f"/repos/{REPO}/issues?labels=hardware-report&state=open&sort=created&direction=asc&per_page=100")
    new = [i for i in issues if i["number"] > last and "pull_request" not in i]
    log = open(os.path.join(INTAKE, "summary.log"), "a")
    for i in new:
        body = i.get("body") or ""
        open(os.path.join(INTAKE, "issues", f"{i['number']}.md"), "w").write(
            f"# #{i['number']} {i['title']}\n{i['html_url']}\nby {i['user']['login']} at {i['created_at']}\n\n{body}\n")
        path, what = draft_profile(body, i["number"], i["html_url"])
        line = f"{time.strftime('%Y-%m-%d %H:%M')} #{i['number']} {i['title']} -> {what}"
        print(line); log.write(line + "\n")
        state["last"] = max(state["last"], i["number"])
    json.dump(state, open(state_f, "w"))
    print(f"{len(new)} new report(s); {len(issues)} open")

if __name__ == "__main__":
    main()
