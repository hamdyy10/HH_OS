/**
 * The Command Center's URL moved from /hhos-ai to /hh-ai (the HH rename).
 *
 *     NODE_PATH=/opt/hhos-dashboard/node_modules node dashboard/tools/test-hh-url.cjs
 *
 * Boots the real server.js on a scratch port with a scratch data dir (no
 * supervisor socket, so HH AI calls answer "offline") and checks over HTTP:
 *
 *  - /hh-ai is the page and /hh-ai/api/* the API;
 *  - GET /hhos-ai and any page path under it 301 to /hh-ai, query kept;
 *  - /hhos-ai/api/* is an alias served by the same handlers, with the same
 *    401 (no session), 403 (no hhosai.use), 403 (no CSRF) answers -- never a
 *    redirect, which would break POST, SSE and CSRF'd fetches;
 *  - no client code still names the old URL: only the alias layer in server.js.
 *
 * .cjs because it uses require, and some directories it may be run from declare
 * "type": "module".
 */
const fs = require("fs");
const os = require("os");
const path = require("path");
const http = require("http");
const { spawn } = require("child_process");

const ROOT = path.join(__dirname, "..");
const DATA = fs.mkdtempSync(path.join(os.tmpdir(), "hh-url-"));
const LOGS = path.join(DATA, "log");
fs.mkdirSync(LOGS);
process.env.HHOS_DATA_DIR = DATA;
process.env.HHOS_LOG_DIR = LOGS;
const PORT = 3900 + Math.floor(Math.random() * 90);

let failures = 0;
let passes = 0;
function check(name, ok, detail) {
  if (ok) {
    passes++;
    return console.log("ok   " + name);
  }
  failures++;
  console.log("FAIL " + name + (detail !== undefined ? "  (" + String(detail).slice(0, 300) + ")" : ""));
}

/* ------------------------------------------------------- static checks --- */

const server = fs.readFileSync(path.join(ROOT, "server.js"), "utf8");
check("no route is registered under /hhos-ai", !/app\.(get|post|put|patch|delete|all|use)\(\s*["'`]\/hhos-ai/.test(server));
check("the page route is /hh-ai", /app\.get\("\/hh-ai", requireAuth,/.test(server));
check("the API routes are under /hh-ai/api", (server.match(/app\.(get|post)\("\/hh-ai\/api\//g) || []).length >= 39); // every one of the 39 that lived under /hhos-ai/api
{
  // Outside the alias block, server.js names the old URL nowhere.
  const i = server.indexOf("const LEGACY_CC");
  const rest = server.slice(0, i - 800) + server.slice(i + 600);
  check("the alias layer exists and is the one place that names the /hhos-ai URL", i > 0 && !/["'`\s(]\/hhos-ai[\/"'`\s)]/.test(rest));
}
{
  // Client code: every public script, every view, the guide, the READMEs.
  const files = [
    ...fs.readdirSync(path.join(ROOT, "public")).filter((f) => f.endsWith(".js") || f.endsWith(".css")).map((f) => path.join(ROOT, "public", f)),
    ...fs.readdirSync(path.join(ROOT, "lib")).filter((f) => f.endsWith(".js")).map((f) => path.join(ROOT, "lib", f)),
    path.join(ROOT, "README.md"),
    path.join(ROOT, "..", "hhos-ai", "README.md"),
  ];
  // A URL, not a path on disk (/root/hhos-ai, /etc/hhos-ai, ...) nor a file
  // name (public/hhos-ai.js) nor an id (the hhos-ai unit, hhos-ai-ctl).
  const URL_RE = /(^|[\s"'`(=])\/hhos-ai(?=[\/"'`)\s?]|$)(?!\/(lib|home|hooks|tools|bin|supervisor))/m;
  const hits = [];
  for (const f of files) {
    fs.readFileSync(f, "utf8").split("\n").forEach((line, i) => {
      if (URL_RE.test(line)) hits.push(path.relative(ROOT, f) + ":" + (i + 1) + ": " + line.trim().slice(0, 80));
    });
  }
  check("no client code, view or README references the /hhos-ai URL", hits.length === 0, hits.join(" | "));
  const ui = require(path.join(ROOT, "lib", "ui.js"));
  check("the sidebar's Command Center item points at /hh-ai", ui.NAV[0].items[0].key === "hhos-ai" && ui.NAV[0].items[0].href === "/hh-ai");
  const js = fs.readFileSync(path.join(ROOT, "public", "hhos-ai.js"), "utf8");
  check("the page's API base, event stream and speech are under /hh-ai", /fetch\("\/hh-ai\/api\/" \+ path/.test(js) && /new EventSource\("\/hh-ai\/api\/events[?"]/.test(js) && /fetch\("\/hh-ai\/api\/speak"/.test(js));
}

/* ------------------------------------------------------------- over HTTP --- */

function req(method, p, { cookie, headers, body } = {}) {
  return new Promise((resolve, reject) => {
    const h = Object.assign({ "X-Forwarded-Proto": "https" }, headers || {});
    if (cookie) h.Cookie = cookie;
    let data = null;
    if (body !== undefined) {
      data = typeof body === "string" ? body : JSON.stringify(body);
      if (!h["Content-Type"]) h["Content-Type"] = typeof body === "string" ? "application/x-www-form-urlencoded" : "application/json";
      h["Content-Length"] = Buffer.byteLength(data);
    }
    const r = http.request({ host: "127.0.0.1", port: PORT, method, path: p, headers: h }, (res) => {
      let buf = "";
      res.setEncoding("utf8");
      res.on("data", (c) => {
        buf += c;
        // SSE never ends: the headers are the answer.
        if (/text\/event-stream/.test(res.headers["content-type"] || "")) {
          r.destroy();
          resolve({ status: res.statusCode, headers: res.headers, body: buf });
        }
      });
      res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, body: buf }));
      res.on("error", () => resolve({ status: res.statusCode, headers: res.headers, body: buf }));
    });
    r.on("error", reject);
    r.setTimeout(8000, () => r.destroy(new Error("timeout " + method + " " + p)));
    if (data) r.write(data);
    r.end();
  });
}

function cookieOf(res, prev) {
  const set = res.headers["set-cookie"];
  if (!set) return prev;
  return set.map((c) => c.split(";")[0]).join("; ");
}

async function signIn(username, password, secret) {
  const { authenticator } = require("otplib");
  const g = await req("GET", "/login");
  let cookie = cookieOf(g);
  const csrf = (g.body.match(/name="_csrf" value="([^"]+)"/) || [])[1];
  const form = new URLSearchParams({ _csrf: csrf, username, password, token: authenticator.generate(secret) }).toString();
  const p = await req("POST", "/login", { cookie, body: form });
  cookie = cookieOf(p, cookie);
  if (p.status !== 302 || /\/login/.test(p.headers.location || "")) throw new Error("sign-in failed: " + p.status + " " + p.headers.location);
  const page = await req("GET", "/hh-ai", { cookie });
  const pageCsrf = (page.body.match(/data-csrf="([^"]+)"/) || [])[1];
  return { cookie, csrf: pageCsrf, page };
}

async function makeUser(username, roleName) {
  const db = require(path.join(ROOT, "lib", "db.js"));
  const argon2 = require("argon2");
  const { authenticator } = require("otplib");
  const pw = "pw-" + Math.random().toString(36).slice(2);
  const secret = authenticator.generateSecret();
  const role = db.getRoleByName(roleName);
  db.createUser({ username, displayName: username, email: username + "@example.invalid", passwordHash: await argon2.hash(pw, { type: argon2.argon2id }), totpSecret: secret, roleId: role.id, createdBy: "test" });
  db.confirmUserTotp(db.getUserByName(username).id);
  return { pw, secret };
}

(async () => {
  const admin = await makeUser("urladmin", "administrator");
  const viewer = await makeUser("urlviewer", "viewer");

  const child = spawn(process.execPath, [path.join(ROOT, "server.js")], {
    env: Object.assign({}, process.env, {
      HHOS_PORT: String(PORT),
      HHOS_BIND: "127.0.0.1",
      HHOS_AI_SOCKET: path.join(DATA, "no-such.sock"),
      NODE_ENV: "production",
    }),
    stdio: ["ignore", "pipe", "pipe"],
  });
  let out = "";
  child.stdout.on("data", (d) => (out += d));
  child.stderr.on("data", (d) => (out += d));
  const done = () => {
    child.kill();
    fs.rmSync(DATA, { recursive: true, force: true });
  };
  try {
    for (let i = 0; i < 60 && !/listening/.test(out); i++) await new Promise((r) => setTimeout(r, 200));
    if (!/listening/.test(out)) throw new Error("server did not start: " + out);

    /* signed out */
    let r = await req("GET", "/hh-ai");
    check("GET /hh-ai signed out -> 302 /login", r.status === 302 && r.headers.location === "/login", r.status + " " + r.headers.location);
    r = await req("GET", "/hhos-ai");
    check("GET /hhos-ai -> 301 /hh-ai", r.status === 301 && r.headers.location === "/hh-ai", r.status + " " + r.headers.location);
    r = await req("HEAD", "/hhos-ai");
    check("HEAD /hhos-ai -> 301 /hh-ai", r.status === 301 && r.headers.location === "/hh-ai", r.status + " " + r.headers.location);
    r = await req("GET", "/hhos-ai?x=1&y=two");
    check("GET /hhos-ai?query keeps the query", r.status === 301 && r.headers.location === "/hh-ai?x=1&y=two", r.headers.location);
    r = await req("GET", "/hhos-ai/some/deep/link?tab=rules");
    check("a sub-path 301s to the same path under /hh-ai, query kept", r.status === 301 && r.headers.location === "/hh-ai/some/deep/link?tab=rules", r.headers.location);
    r = await req("GET", "/HHOS-AI/");
    check("the old prefix redirects whatever its case", r.status === 301 && r.headers.location === "/hh-ai/", r.headers.location);
    r = await req("GET", "/hhos-aix");
    check("a path that merely starts with hhos-ai is not touched", r.status !== 301, r.status);
    for (const pfx of ["/hh-ai", "/hhos-ai"]) {
      r = await req("GET", pfx + "/api/status");
      check(`GET ${pfx}/api/status signed out -> 401 JSON`, r.status === 401 && /Sign in first/.test(r.body), r.status + " " + r.body);
      r = await req("POST", pfx + "/api/send", { body: { text: "hi" } });
      check(`POST ${pfx}/api/send signed out -> 401`, r.status === 401, r.status);
      r = await req("GET", pfx + "/api/events");
      check(`GET ${pfx}/api/events signed out -> 401, not a redirect`, r.status === 401, r.status);
    }

    /* signed in, administrator */
    const a = await signIn("urladmin", admin.pw, admin.secret);
    check("GET /hh-ai signed in -> 200 Command Center", a.page.status === 200 && /id="cc"/.test(a.page.body) && !!a.csrf, a.page.status);
    check("the page's own sidebar item (the drawer) is /hh-ai and current", /<a href="\/hh-ai" class="side-item on" aria-current="page"/.test(a.page.body));
    r = await req("GET", "/hhos-ai", { cookie: a.cookie });
    check("signed in, the old URL still 301s to /hh-ai", r.status === 301 && r.headers.location === "/hh-ai", r.status);
    const st = { new: await req("GET", "/hh-ai/api/status", { cookie: a.cookie }), old: await req("GET", "/hhos-ai/api/status", { cookie: a.cookie }) };
    check("status answers the same on both prefixes (offline supervisor -> 503)", st.new.status === 503 && st.old.status === 503 && st.new.body === st.old.body, st.new.status + " " + st.old.status);
    for (const pfx of ["/hh-ai", "/hhos-ai"]) {
      r = await req("POST", pfx + "/api/send", { cookie: a.cookie, body: { text: "hi" } });
      check(`POST ${pfx}/api/send without CSRF -> 403`, r.status === 403 && /CSRF/.test(r.body), r.status + " " + r.body);
      r = await req("POST", pfx + "/api/send", { cookie: a.cookie, headers: { "X-CSRF-Token": a.csrf }, body: { text: "hi" } });
      check(`POST ${pfx}/api/send with CSRF reaches the handler (offline -> 503)`, r.status === 503, r.status + " " + r.body);
      r = await req("POST", pfx + "/api/speak", { cookie: a.cookie, body: { text: "x" } });
      check(`POST ${pfx}/api/speak without CSRF -> 403`, r.status === 403, r.status);
      r = await req("GET", pfx + "/api/voice/usage", { cookie: a.cookie });
      check(`GET ${pfx}/api/voice/usage -> 200 JSON`, r.status === 200 && /^\{/.test(r.body), r.status + " " + r.body);
      r = await req("POST", pfx + "/api/transcribe", { cookie: a.cookie, headers: { "X-CSRF-Token": a.csrf }, body: { data: "x" } });
      check(`POST ${pfx}/api/transcribe is gone (push to talk went with it)`, r.status === 404, r.status + " " + r.body.slice(0, 80));
      r = await req("GET", pfx + "/api/events", { cookie: a.cookie });
      check(`GET ${pfx}/api/events streams (SSE, no redirect)`, r.status === 200 && /text\/event-stream/.test(r.headers["content-type"] || ""), r.status + " " + r.headers["content-type"]);
    }

    /* signed in, a role without hhosai.use */
    const v = await signIn("urlviewer", viewer.pw, viewer.secret);
    for (const pfx of ["/hh-ai", "/hhos-ai"]) {
      r = await req("GET", pfx + "/api/status", { cookie: v.cookie });
      check(`GET ${pfx}/api/status without hhosai.use -> 403`, r.status === 403 && /HH AI/.test(r.body), r.status + " " + r.body);
      r = await req("POST", pfx + "/api/send", { cookie: v.cookie, headers: { "X-CSRF-Token": "x" }, body: { text: "hi" } });
      check(`POST ${pfx}/api/send without hhosai.use -> 403`, r.status === 403, r.status);
    }
    r = await req("GET", "/hh-ai", { cookie: v.cookie });
    check("the page itself refuses a role without hhosai.use", r.status === 403, r.status);

    /* the rest is unchanged */
    // The classic chat is hidden (its data kept): every /console URL goes to the Command Center.
    r = await req("GET", "/console", { cookie: a.cookie });
    check("/console -> 302 /hh-ai", r.status === 302 && r.headers.location === "/hh-ai", r.status + " " + r.headers.location);
    r = await req("GET", "/console/s/1", { cookie: a.cookie });
    check("/console/<anything> -> 302 /hh-ai too", r.status === 302 && r.headers.location === "/hh-ai", r.status + " " + r.headers.location);
    check("the Command Center's noscript no longer links /console", !/href="\/console/.test(a.page.body));
  } catch (e) {
    check("the HTTP run completed", false, e.stack + "\n" + out);
  } finally {
    done();
  }
  console.log(`\n${passes} passed, ${failures} failed`);
  process.exit(failures ? 1 : 0);
})();
