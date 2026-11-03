"use strict";
/**
 * The assistant's names.
 *
 * It is shown and addressed as HH AI (renamed from HH AI on 2026-09-29,
 * and from HH Bot before that). Internal identifiers keep the old spelling:
 * the `hhos-ai` service, socket, MCP server, actor and the "hhos-ai" step /
 * order target. During the transition other sessions, notes and people may
 * still use an old name, so every check that asks "is this name us?" accepts
 * all of them.
 */

const DISPLAY_NAME = "HH AI";
const OLD_NAMES = ["HH AI", "HH Bot"];

// Compared after normalising: lower case, the " [ref]" suffix ListAgents adds
// dropped, and spaces / dashes / underscores folded to one space -- so the
// internal id "hhos-ai" matches too.
const SELF_KEYS = new Set(["hh ai", "hh bot", "hhos ai", "hhos bot"]);

function norm(name) {
  return String(name == null ? "" : name)
    .replace(/\s*\[[0-9a-f]{4,12}\]\s*$/i, "")
    .trim()
    .toLowerCase()
    .replace(/[\s_-]+/g, " ");
}

/** Is this session / target name the assistant itself (new or old name, or its id)? */
function isSelfName(name) {
  return SELF_KEYS.has(norm(name));
}

module.exports = { DISPLAY_NAME, OLD_NAMES, isSelfName };
