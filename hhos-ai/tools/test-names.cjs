/**
 * The assistant's names (lib/names.js): shown as HH AI, and during the
 * transition every "is this name us?" check accepts the old HH AI (and
 * HH Bot) too, as well as the internal id hhos-ai. Also: a mission step
 * given to the assistant by any of its names is stored as "hhos-ai".
 *
 *     node hhos-ai/tools/test-names.cjs
 */
const fs = require("fs");
const os = require("os");
const path = require("path");
const names = require(path.join(__dirname, "..", "lib", "names.js"));
const { Ledger } = require(path.join(__dirname, "..", "lib", "ledger.js"));
const { Missions } = require(path.join(__dirname, "..", "lib", "missions.js"));

let failures = 0;
let passes = 0;
function check(name, ok, detail) {
  if (ok) {
    passes++;
    return console.log("ok   " + name);
  }
  failures++;
  console.log("FAIL " + name + (detail ? "  (" + detail + ")" : ""));
}

check("the display name is HH AI", names.DISPLAY_NAME === "HH AI");
check("the old names are HH AI and HH Bot", names.OLD_NAMES.includes("HH AI") && names.OLD_NAMES.includes("HH Bot"));
for (const n of ["HH AI", "HH AI", "hh ai", "HH Ai", "hhos-ai", "hh-ai", "HH AI [a1b2c3]", "  HH AI  ", "HH Bot", "hhos_bot"])
  check(`"${n}" is the assistant`, names.isSelfName(n) === true);
for (const n of ["HH Agent OS", "Odoo 19 VPS setup", "hh", "hhos", "HH AI helper", "", null, undefined])
  check(`"${n}" is not the assistant`, names.isSelfName(n) === false);

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "hhos-names-"));
const M = new Missions(new Ledger(path.join(tmp, "ledger.db")));
const m = M.create({
  title: "Rename",
  goal: "g",
  steps: [{ title: "a", target: "HH AI" }, { title: "b", target: "HH AI" }, { title: "c", target: "hhos-ai" }, { title: "d", target: "HH Agent OS" }],
  actor: "hhos-ai",
});
check("steps given to HH AI / HH AI are stored as hhos-ai", m.steps.map((s) => s.target).join("|") === "hhos-ai|hhos-ai|hhos-ai|HH Agent OS", m.steps.map((s) => s.target).join("|"));
const upd = M.updateStep(m.id, 4, { target: "HH AI" });
check("re-targeting a step to HH AI stores hhos-ai", upd.steps[3].target === "hhos-ai", upd.steps[3].target);

console.log(`\n${passes} passed, ${failures} failed`);
process.exit(failures ? 1 : 0);
