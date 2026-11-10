"""Frontend environment selection (docs/DEPLOYMENT_FRONTEND_CONFIGURATION.md).

local origin -> local stack only; local origin + ?env=staging -> js/config.staging.js only; a production host ->
js/config.js; any other host -> no connection. The production and unknown hosts are simulated by serving this working copy
under those URLs inside the browser (page.route); every request to a hosted *.supabase.co is recorded and ABORTED, so no
real project is contacted. A temporary js/config.staging.js (fake project, git-ignored) exists only during check S2.
"""
import re
from pathlib import Path
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright

from class_ui_common import APP, check, report

ROOT = Path(__file__).resolve().parents[3]
STAGING_FILE = ROOT / "js" / "config.staging.js"
TYPES = {".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".webp": "image/webp", ".woff2": "font/woff2",
         ".svg": "image/svg+xml", ".json": "application/json"}
CONFIG = (ROOT / "js" / "config.js").read_text(encoding="utf-8")
PROD_URL = re.search(r"SUPABASE_URL = '([^']+)'", CONFIG).group(1)
PROD_KEY = re.search(r"SUPABASE_PUBLISHABLE_KEY = '([^']+)'", CONFIG).group(1)
PLACEHOLDER = "YOUR-PROJECT" in PROD_URL or "YOUR-KEY" in PROD_KEY      # before the release values are set
# privileged or unknown credentials that must never appear in a committable frontend file
SECRET_PATTERNS = [r"sb_secret_[A-Za-z0-9_-]{8,}", r"sbp_[A-Za-z0-9]{20,}", r"gh[pousr]_[A-Za-z0-9]{20,}", r"github_pat_",
                   r"BEGIN [A-Z ]*PRIVATE KEY", r"postgres(ql)?://[^:@/\s'\"]+:[^@/\s'\"]+@"]
JWT = re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.([A-Za-z0-9_-]{10,})\.[A-Za-z0-9_-]*")


def host(u):
    """Host of a recorded hosted request, WebSocket or the client's configured URL ("configured:https://…")."""
    return urlparse(u.removeprefix("configured:")).hostname


def serve_from_disk(prefix):
    """Fulfil requests under `prefix` from the working copy (like GitHub Pages would)."""
    def handler(route):
        path = urlparse(route.request.url).path.split("/tavern_ledger/", 1)[-1] or "index.html"
        f = ROOT / path
        if f.is_file():
            route.fulfill(status=200, body=f.read_bytes(), headers={"content-type": TYPES.get(f.suffix, "application/octet-stream")})
        else:
            route.fulfill(status=404, body=b"not found")
    return prefix + "**", handler


def open_page(browser, url, prefix=None):
    ctx = browser.new_context()
    hosted, errors = [], []
    ctx.route(re.compile(r"https://[a-z0-9]+\.supabase\.co/.*"), lambda r: (hosted.append(r.request.url), r.abort()))
    # WebSockets are not covered by route(): a mocked socket that never connects to any server
    ctx.route_web_socket(re.compile(r"wss?://.*supabase\.co/.*"), lambda ws: hosted.append(ws.url))
    if prefix:
        ctx.route(*serve_from_disk(prefix))
    page = ctx.new_page()
    page.on("pageerror", lambda e: errors.append(str(e)))
    requests = []
    page.on("request", lambda r: requests.append(r.url))
    page.goto(url)
    page.wait_for_timeout(2500)
    env = page.evaluate("() => import('./js/supabase.js?v=21').then((m) => m.environment + '|' + (m.supabase ? m.supabase.supabaseUrl : '')).catch((e) => 'import failed: ' + e)")
    env, _, configured = env.partition("|")
    hosted.append("configured:" + configured) if configured.startswith("https://") else None
    return ctx, page, env, hosted, requests, errors


def jwt_role(segment):
    import base64
    import json
    try:
        return json.loads(base64.urlsafe_b64decode(segment + "=" * (-len(segment) % 4))).get("role")
    except Exception:                                                     # noqa: BLE001 - not a JWT payload
        return None


def static_checks():
    """K1/K2: the committable frontend files (index.html, js/*.js except the git-ignored local/staging configs) hold no
    privileged credential, and js/config.js holds only placeholders or browser-safe values."""
    files = [ROOT / "index.html"] + [f for f in sorted((ROOT / "js").glob("*.js")) if f.name not in ("config.local.js", "config.staging.js")]
    hits = []
    for f in files:
        t = f.read_text(encoding="utf-8")
        hits += [f"{f.name}: {pat[:14]}" for pat in SECRET_PATTERNS if re.search(pat, t)]
        hits += [f"{f.name}: JWT role {jwt_role(m.group(1))}" for m in JWT.finditer(t) if jwt_role(m.group(1)) != "anon"]
    check("K1 no committable frontend file contains a secret key, service_role JWT, access token, private key or DB password (%d files)" % len(files),
          not hits, hits)
    url_ok = PLACEHOLDER or re.fullmatch(r"https://[a-z0-9]+\.supabase\.co", PROD_URL)
    key_ok = PROD_KEY.startswith("sb_publishable_") or jwt_role((PROD_KEY.split(".") + ["", ""])[1]) == "anon"
    check("K2 js/config.js holds only a project URL and a publishable key (%s)" % ("placeholders: release values not set yet" if PLACEHOLDER else "release values"),
          url_ok and key_ok, (PROD_URL[:30], PROD_KEY[:15]))


def main():
    static_checks()
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)

        # L: the local origin talks to the local stack only
        ctx, page, env, hosted, reqs, errs = open_page(browser, APP)
        local_api = [u for u in reqs if urlparse(u).port == 54321]
        check("L1 a local origin selects 'local' and contacts no hosted project", env == "local" and not hosted, (env, hosted[:2]))
        check("L2 ... it reaches the local stack (sign-in form rendered)", page.locator("input[name=email]").count() == 1 and not errs, errs)
        ctx.close()

        # S1: staging requested but not configured -> a clear message, no connection anywhere
        assert not STAGING_FILE.exists(), "a real js/config.staging.js exists; this test only runs without one"
        ctx, page, env, hosted, reqs, errs = open_page(browser, APP + "?env=staging")
        check("S1 ?env=staging without js/config.staging.js: 'Staging is not configured', no hosted or local API request",
              env == "staging" and "Staging is not configured" in page.locator("body").inner_text() and not hosted
              and not [u for u in reqs if urlparse(u).port == 54321], (env, hosted[:2]))
        ctx.close()

        # S2: staging configured -> only the staging project, with the banner
        STAGING_FILE.write_text("export const STAGING_SUPABASE_URL = 'https://stagingfake0000.supabase.co';\n"
                                "export const STAGING_SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_test_not_a_real_key_000000';\n", encoding="utf-8")
        try:
            ctx, page, env, hosted, reqs, errs = open_page(browser, APP + "?env=staging")
            hosts = {host(u) for u in hosted}
            check("S2 with js/config.staging.js the page uses only the staging project (and never the production one)",
                  env == "staging" and hosts <= {"stagingfake0000.supabase.co"} and urlparse(PROD_URL).hostname not in hosts
                  and not [u for u in reqs if urlparse(u).port == 54321], (env, hosts))
            check("S3 ... and shows the STAGING banner and title", page.locator(".env-banner").is_visible()
                  and page.title().startswith("STAGING"), page.title())
            ctx.close()
        finally:
            STAGING_FILE.unlink()
        check("S4 the temporary staging file is gone again", not STAGING_FILE.exists())

        # K3: privileged or unknown keys are refused before any request (fed through the git-ignored staging file)
        import base64
        fake_service = "eyJhbGciOiJIUzI1NiJ9." + base64.urlsafe_b64encode(b'{"role":"service_role","iss":"test"}').decode().rstrip("=") + ".x"
        refused = {}
        for label, k in (("service_role JWT", fake_service), ("sb_secret_", "sb_secret_test_not_a_real_key_000000"),
                         ("unknown token", "sbp_test_not_a_real_access_token_00000000000")):
            STAGING_FILE.write_text("export const STAGING_SUPABASE_URL = 'https://stagingfake0000.supabase.co';\n"
                                    f"export const STAGING_SUPABASE_PUBLISHABLE_KEY = '{k}';\n", encoding="utf-8")
            try:
                ctx, page, env, hosted, reqs, errs = open_page(browser, APP + "?env=staging")
                refused[label] = (not [u for u in hosted if not u.startswith("configured:")] and any("key" in e.lower() for e in errs), errs[:1])
                ctx.close()
            finally:
                STAGING_FILE.unlink()
        check("K3 a service_role JWT, an sb_secret_ key and an unknown token are refused at start-up, before any request",
              all(v[0] for v in refused.values()) and not STAGING_FILE.exists(), refused)

        # P: the production host uses js/config.js only
        prod = "https://alexandrajuscak.github.io/tavern_ledger/"
        ctx, page, env, hosted, reqs, errs = open_page(browser, prod, prod)
        hosts = {host(u) for u in hosted}
        if PLACEHOLDER:   # before the release values are set: the setup screen, and no connection at all
            check("P1 the production host selects 'production'; with placeholder values it shows 'Almost there' and connects to nothing",
                  env == "production" and not hosted and "Almost there" in page.locator("body").inner_text(), (env, hosts))
        else:
            check("P1 the production host selects 'production' and only the project in js/config.js",
                  env == "production" and hosts == {urlparse(PROD_URL).hostname}, (env, hosts))
        check("P2 ... no request to localhost, the local stack or a staging project",
              not [u for u in reqs if urlparse(u).hostname in ("127.0.0.1", "localhost")], [u for u in reqs if "127.0.0.1" in u][:3])
        ctx.close()
        ctx, page, env, hosted, reqs, errs = open_page(browser, prod + "?env=staging", prod)
        check("P3 ?env=staging is ignored on the production host (still production)", env == "production"
              and ({host(u) for u in hosted} == ({urlparse(PROD_URL).hostname} if not PLACEHOLDER else set())), env)
        ctx.close()

        # U: an unknown host connects to nothing
        other = "https://mirror.example.org/tavern_ledger/"
        ctx, page, env, hosted, reqs, errs = open_page(browser, other, other)
        check("U1 an unknown host selects nothing: 'Unknown address', no hosted or local request",
              env == "unknown-host" and "Unknown address" in page.locator("body").inner_text() and not hosted
              and not [u for u in reqs if urlparse(u).port == 54321], (env, hosted[:2]))
        ctx.close()
        browser.close()
    report()


main()
