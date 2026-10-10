#!/usr/bin/env node
// Which turbo tasks the warm runs when the root names none: every task the
// repository's turbo.json declares that a pull-request job could read from the
// pool. Prints the task names, space-separated, on stdout; explains itself on
// stderr. Exits non-zero, with the reason, when there is nothing it can stand
// behind — never "build" as a guess.
//
//   usage: derive-turbo-tasks.cjs <turbo.json> [exclude-glob ...]
//
// WHAT IS LEFT OUT, AND WHY EACH IS SAFE TO LEAVE OUT
//   cache: false        never published, so warming it buys nothing.
//   persistent: true    a dev server or watcher: it does not exit, and a warm
//                       that runs one sits there until the build timeout.
//   an exclude glob     `turbo_tasks_exclude`, matched against the task NAME
//                       (the part after `#`). By default `test*` and `e2e*`:
//                       a test task that needs a database or a browser fails on
//                       every warm (and is not cached), and a slow one can push
//                       a shared warm past its timeout.
//   an unsafe name      anything outside the character set turbo_tasks itself
//                       is validated to. The names reach a shell command line.
//
// A NAME, NOT A KEY. `pkg#build` and `build` are both run by `turbo run build`;
// the warm runs names. A name is left out if ANY of its keys is persistent (one
// watcher is enough to hang the build) and kept if ANY of its keys is cached.
//
// WHAT IT CANNOT SEE: a task declared only in a package-level turbo.json (with
// `extends`), and anything a pull-request job runs outside turbo. Name those in
// `turbo_tasks` explicitly; an explicit list overrides all of this.
//
// WHY .cjs: it is staged under /workspace, beside the checkout, so a plain .js
// takes its module type from the repository's own package.json. A repository
// with "type": "module" would make every `require` here a ReferenceError.
"use strict";
const fs = require("fs");

const [file, ...excludes] = process.argv.slice(2);
const say = (m) => process.stderr.write("[warm] " + m + "\n");

let src;
try {
  src = fs.readFileSync(file, "utf8");
} catch (e) {
  say("no " + file + " at the repository root, so there are no declared tasks to warm. Set turbo_tasks, or build_command = \"true\" for a repository with no turbo pipeline.");
  process.exit(2);
}

// turbo.json is JSONC: comments and trailing commas are legal. Stripped by a
// scanner that knows where strings are, because `"$schema": "https://..."` and
// a root task key `"//#lint"` both hold `//` that is not a comment.
function stripJsonc(s) {
  let out = "";
  let inStr = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (inStr) {
      out += c;
      if (c === "\\") { out += s[i + 1] || ""; i++; }
      else if (c === "\"") inStr = false;
    } else if (c === "\"") {
      inStr = true; out += c;
    } else if (c === "," && /^(\s|\/\/[^\n]*\n|\/\*[\s\S]*?\*\/)*[}\]]/.test(s.slice(i + 1))) {
      // A trailing comma (whitespace and comments may sit between it and the
      // bracket). Dropped here, outside strings, so a value holding ",}" is
      // left alone.
    } else if (c === "/" && s[i + 1] === "/") {
      while (i < s.length && s[i] !== "\n") i++;
      out += "\n";
    } else if (c === "/" && s[i + 1] === "*") {
      i += 2;
      while (i < s.length && !(s[i] === "*" && s[i + 1] === "/")) i++;
      i++;
    } else {
      out += c;
    }
  }
  return out;
}

let cfg;
try {
  cfg = JSON.parse(stripJsonc(src));
} catch (e) {
  say(file + " does not parse (" + e.message + "). Fix it, or set turbo_tasks explicitly.");
  process.exit(3);
}

// turbo 2 says `tasks`, turbo 1 said `pipeline`.
const declared = cfg.tasks || cfg.pipeline;
if (!declared || typeof declared !== "object" || Array.isArray(declared)) {
  say(file + " declares no `tasks` (or `pipeline`). Set turbo_tasks explicitly.");
  process.exit(4);
}

const SAFE = /^[A-Za-z0-9][A-Za-z0-9:#@._\/-]{0,127}$/;
const globRe = (g) => new RegExp("^" + g.replace(/[.+^$()|[\]{}\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$");
const globs = excludes.map((g) => [g, globRe(g)]);

// name -> { cached: bool, persistent: bool }
const byName = new Map();
for (const [key, def] of Object.entries(declared)) {
  const name = key.includes("#") ? key.slice(key.lastIndexOf("#") + 1) : key;
  const d = def && typeof def === "object" ? def : {};
  const cur = byName.get(name) || { cached: false, persistent: false };
  if (d.cache !== false) cur.cached = true;
  if (d.persistent === true) cur.persistent = true;
  byName.set(name, cur);
}

const included = [];
const excluded = [];
for (const [name, info] of byName) {
  let why = null;
  if (info.persistent) why = "persistent";
  else if (!info.cached) why = "cache: false";
  else if (!SAFE.test(name)) why = "not a safe task name";
  else {
    const hit = globs.find(([, re]) => re.test(name));
    if (hit) why = "turbo_tasks_exclude " + hit[0];
  }
  if (why) excluded.push(name + " (" + why + ")");
  else included.push(name);
}

say("tasks derived from " + file + ": " + (included.length ? included.join(" ") : "(none)"));
say("excluded: " + (excluded.length ? excluded.join(", ") : "(none)"));
if (!included.length) {
  say("nothing left to warm. Set turbo_tasks explicitly, or narrow turbo_tasks_exclude.");
  process.exit(5);
}
process.stdout.write(included.join(" ") + "\n");
