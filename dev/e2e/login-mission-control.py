"""ADR-0060 P2 exit check: log in to front4 as a dev user (dev Cognito pool) and Mission Control renders data.

Run with the front4 slice up (make dev SVC=front4), from the repo root:
  SEC=$(aws secretsmanager get-secret-value --secret-id packiot/dev/cognito --query SecretString --output text)
  docker run --rm --network host --ipc host -e DEV_USER=dev-viewer@example.com \
    -e DEV_PASSWORD="$(jq -r '.users["dev-viewer@example.com"]' <<<"$SEC")" -v "$PWD/dev/e2e:/e2e:ro" -v /tmp:/out \
    mcr.microsoft.com/playwright/python:v1.48.0-jammy sh -c 'pip install -q playwright==1.48.0 && python3 /e2e/login-mission-control.py'
PASS = login lands on /home, every read-api call is < 400, mission-control answered 200 and anonymized
"Equipment <hash>" cards are on screen. Prints the hosts contacted outside localhost (expect Cognito + fonts).
"""
import json, os, sys, time
from playwright.sync_api import sync_playwright

BASE = "http://localhost:5173"
calls, console_errors, external_hosts = [], [], set()
with sync_playwright() as p:
    b = p.chromium.launch()
    page = b.new_page(viewport={"width": 1600, "height": 1000})
    page.on("console", lambda m: console_errors.append(m.text[:160]) if m.type == "error" else None)
    def on_resp(r):
        if "/v1/query" in r.url or "/v1/language-packs" in r.url:
            ds = ""
            try:
                ds = json.loads(r.request.post_data or "{}").get("dataset", "")
            except Exception:
                pass
            calls.append((ds or r.url.split("/v1/")[-1], r.status))
    page.on("response", on_resp)
    from urllib.parse import urlparse
    page.on("request", lambda r: external_hosts.add(urlparse(r.url).hostname) if urlparse(r.url).hostname not in ("localhost", "127.0.0.1", None) else None)
    page.goto(f"{BASE}/login", wait_until="networkidle")
    page.fill('input[type="email"]', os.environ["DEV_USER"])
    page.fill('input[type="password"]', os.environ["DEV_PASSWORD"])
    page.click('button[type="submit"]')
    page.wait_for_url("**/home**", timeout=60000)
    print("logged in →", page.url)
    page.wait_for_timeout(4000)
    page.goto(f"{BASE}/mission-control", wait_until="networkidle")
    deadline = time.time() + 60
    while time.time() < deadline and not any(d == "mission-control" for d, _ in calls):
        page.wait_for_timeout(1000)
    page.wait_for_timeout(5000)
    body = page.inner_text("body")
    cards = body.count("Equipment ")
    page.screenshot(path="/out/mission-control.png", full_page=True)
    print("calls:", sorted(set(calls)))
    print("anonymized equipment names on Mission Control:", cards)
    bad = [c for c in calls if c[1] >= 400]
    print("failed calls:", bad)
    print("console errors (first 5):", console_errors[:5])
    print("hosts contacted outside localhost:", sorted(h for h in external_hosts if h))
    b.close()
ok = cards > 0 and not bad and any(d == "mission-control" and s == 200 for d, s in calls)
print("P2 EXIT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
