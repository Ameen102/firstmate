#!/usr/bin/env bash
# Portable OMP Calm presentation and settings restoration checks; no model or OMP install.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-calm-omp-extension)
trap fm_test_cleanup EXIT
command -v node >/dev/null 2>&1 || { echo "skip: node not found for OMP Calm checks"; exit 0; }

prepare_fixture() {
  local repo="$TMP_ROOT/repo" package
  package="$repo/node_modules/@oh-my-pi/pi-coding-agent"
  mkdir -p "$repo/.omp/extensions" "$repo/.pi/extensions/lib" "$repo/.claude/mods/firstmate-calm/lib" "$package/config"
  cp "$ROOT/.omp/extensions/fm-calm.ts" "$repo/.omp/extensions/" || fail "OMP Calm extension is missing"
  cp "$ROOT/.claude/mods/firstmate-calm/lib/fm-calm-preservation.ts" "$repo/.claude/mods/firstmate-calm/lib/"
  cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$repo/.pi/extensions/lib/"
  cp "$ROOT/.claude/mods/firstmate-calm/lib/fm-calm-working-ship-sprite.ts" "$repo/.pi/extensions/lib/"
  printf '{"type":"module","exports":{"./config/*":"./config/*.mjs"}}\n' >"$package/package.json"
  # Layered settings double at the vendor boundary: the extension under test owns
  # all presentation decisions and snapshot/restore logic, not this fixture.
  cat >"$package/config/settings.mjs" <<'JS'
export class Settings {
  values = new Map();
  overrides = new Map();
  hasRuntimeOverride(setting) { return this.overrides.has(setting.id); }
}
export let current;
export function use(settings) { current = settings; }
export function findScopedSettings() { return current; }
JS
  cat >"$package/config/registry.mjs" <<'JS'
const ids = ["display.hideToolActivity", "hideThinkingBlock", "extensionRenderers.assistantText"];
const settings = new Map(ids.map(id => [id, {
  id, type: "boolean",
  get(s) { return s.overrides.has(id) ? s.overrides.get(id) : (s.values.get(id) ?? false); },
  override(s, value) { s.overrides.set(id, value); },
  clearOverride(s) { s.overrides.delete(id); },
}]));
export function lookup(id) { return settings.get(id); }
JS
}

test_calm_rendering_and_restore() {
  prepare_fixture
  local out
  out=$(REPO="$TMP_ROOT/repo" node --input-type=module 2>&1 <<'JS'
import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { pathToFileURL } from "node:url";
const repo = process.env.REPO;
const { Settings, use } = await import(pathToFileURL(`${repo}/node_modules/@oh-my-pi/pi-coding-agent/config/settings.mjs`));
const { lookup } = await import(pathToFileURL(`${repo}/node_modules/@oh-my-pi/pi-coding-agent/config/registry.mjs`));
const { default: calm } = await import(pathToFileURL(`${repo}/.omp/extensions/fm-calm.ts`));
const ids = ["display.hideToolActivity", "hideThinkingBlock", "extensionRenderers.assistantText"];
let sequence = 0;
function fixture({ home = `${repo}/home-${++sequence}`, preference = "off", baseline = [false, false, false], overrides = [] } = {}) {
  process.env.FM_HOME = home;
  delete process.env.FM_ROOT_OVERRIDE;
  delete process.env.FM_CONFIG_OVERRIDE;
  mkdirSync(`${home}/config`, { recursive: true });
  writeFileSync(`${home}/config/calm`, `${preference}\n`);
  const settings = new Settings();
  ids.forEach((id, i) => settings.values.set(id, baseline[i]));
  overrides.forEach(([i, value]) => lookup(ids[i]).override(settings, value));
  use(settings);
  const handlers = new Map(), notices = [], rerenders = [], branch = [];
  let render, command;
  calm({
    on: (name, handler) => handlers.set(name, handler),
    registerAssistantTextRenderer: handler => { render = handler; },
    registerCommand: (name, value) => { if (name === "calm") command = value.handler; },
  });
  const ctx = {
    mode: "tui", agent: { kind: "main" }, cwd: repo,
    sessionManager: { getBranch: () => branch },
    ui: { notify: (...args) => notices.push(args), rerenderMessage: id => rerenders.push(id) },
  };
  const start = () => { use(settings); handlers.get("session_start")({}, ctx); };
  const toggle = (context = ctx) => command("", context);
  const values = () => ids.map(id => lookup(id).get(settings));
  return { home, settings, handlers, notices, rerenders, branch, ctx, start, toggle, values, render: value => render(value) };
}
function message(timestamp, stopReason = "toolUse", content = [{ type: "text", text: "Working" }, { type: "toolCall", name: "bash" }]) {
  return { role: "assistant", timestamp, stopReason, content };
}
const f = fixture();
const original = message(100);
f.branch.push({ type: "message", message: original });
const stored = JSON.stringify(f.branch);
f.start();
await f.toggle();
assert.equal(readFileSync(`${f.home}/config/calm`, "utf8"), "on\n");
assert.deepEqual(f.values(), [true, true, true]);
const segment = message(100, "stop", [{ type: "text", text: "Working" }]);
for (const text of ["Working", "x".repeat(239), `  ${"x".repeat(239)}  `, ""]) {
  assert.equal(f.render({ message: segment, text, streaming: false }), "", `short segmented narration: ${JSON.stringify(text)}`);
}
for (const text of ["x".repeat(240), `  ${"x".repeat(240)}  `, "a\nb", "\nWorking", "Working\n"]) {
  assert.equal(f.render({ message: segment, text, streaming: false }), undefined, `substantive block: ${JSON.stringify(text)}`);
}
assert.equal(f.render({ message: segment, text: "Working", streaming: true }), undefined, "streaming stays visible");
for (const stopReason of ["stop", "error", "aborted", "length"]) {
  const final = message(200, stopReason, [{ type: "text", text: "Final" }]);
  assert.equal(f.render({ message: final, text: "Final", streaming: false }), undefined, `${stopReason} reply preserved`);
}
const limited = message(300, "length");
f.handlers.get("message_end")({ message: limited }, f.ctx);
assert.equal(f.render({ message: { ...segment, timestamp: 300 }, text: "Working", streaming: false }), "", "token limit with tools classified before display segmentation");
assert.ok(f.rerenders.includes(100) && f.rerenders.includes(300), "existing and newly settled messages redraw");
assert.equal(JSON.stringify(f.branch), stored, "rendering must not mutate session data");
await f.toggle();
assert.equal(f.render({ message: segment, text: "Working", streaming: false }), undefined, "off restores narration");
assert.deepEqual(f.values(), [false, false, false]);
assert.equal(f.settings.overrides.size, 0, "off removes only its own runtime overrides");
assert.equal(readFileSync(`${f.home}/config/calm`, "utf8"), "off\n");

// Preserve both effective values and pre-existing runtime override ownership.
const mixed = fixture({ baseline: [true, true, false], overrides: [[1, false], [2, true]] });
mixed.start();
await mixed.toggle();
await mixed.toggle();
assert.deepEqual(mixed.values(), [true, false, true]);
assert.equal(mixed.settings.hasRuntimeOverride(lookup(ids[0])), false);
assert.equal(mixed.settings.hasRuntimeOverride(lookup(ids[1])), true);
assert.equal(mixed.settings.hasRuntimeOverride(lookup(ids[2])), true);
// Native keys may change a persisted lower layer during Calm; off still restores
// the exact pre-Calm effective value for this session.
await mixed.toggle();
mixed.settings.values.set(ids[0], false);
await mixed.toggle();
assert.deepEqual(mixed.values(), [true, false, true]);

const restart = fixture({ preference: "max", baseline: [true, false, false] });
restart.start();
assert.deepEqual(restart.values(), [true, true, true], "legacy on preference activates on startup");
restart.handlers.get("session_shutdown")({}, restart.ctx);
assert.deepEqual(restart.values(), [true, false, false], "shutdown restores baseline");
restart.start();
assert.deepEqual(restart.values(), [true, true, true], "same-process replacement reloads preference");
restart.handlers.get("session_shutdown")({}, restart.ctx);

const failure = fixture();
failure.start();
// A directory at the destination makes the atomic rename fail portably.
const { rmSync } = await import("node:fs");
rmSync(`${failure.home}/config/calm`);
mkdirSync(`${failure.home}/config/calm`);
await failure.toggle();
assert.deepEqual(failure.values(), [false, false, false], "failed save leaves presentation unchanged");
assert.equal(failure.notices.at(-1)[1], "error");

for (const ctx of [{ ...f.ctx, mode: "rpc" }, { ...f.ctx, agent: { kind: "subagent" } }]) {
  const before = readFileSync(`${f.home}/config/calm`, "utf8");
  // The command remains scoped to the interactive main agent.
  f.handlers.get("session_start")({}, ctx);
  await f.toggle(ctx);
  assert.equal(readFileSync(`${f.home}/config/calm`, "utf8"), before);
  assert.deepEqual(f.values(), [false, false, false], "noninteractive and subagent contexts cannot activate Calm");
}

// Resolve paths from the extension, never cwd; every destination is scratch.
for (const choice of ["home", "root", "code", "config"]) {
  const t = fixture();
  delete process.env.FM_HOME;
  process.env.FM_ROOT_OVERRIDE = `${repo}/root-override`;
  let target = `${process.env.FM_ROOT_OVERRIDE}/config/calm`;
  if (choice === "home") { process.env.FM_HOME = t.home; target = `${t.home}/config/calm`; }
  if (choice === "code") { delete process.env.FM_ROOT_OVERRIDE; target = `${repo}/config/calm`; }
  if (choice === "config") { process.env.FM_HOME = t.home; process.env.FM_CONFIG_OVERRIDE = `${repo}/config-override`; target = `${process.env.FM_CONFIG_OVERRIDE}/calm`; }
  // The home is captured at extension construction.
  const h = new Map();
  let command;
  calm({ on: (name, handler) => h.set(name, handler), registerAssistantTextRenderer() {}, registerCommand: (_name, value) => { command = value.handler; } });
  use(t.settings);
  h.get("session_start")({}, t.ctx);
  await command("", t.ctx);
  assert.equal(existsSync(target), true, `${choice} preference target`);
  assert.equal(readFileSync(target, "utf8"), "on\n", `${choice} preference saved`);
}
console.log("presentation-and-restore-ok");
JS
) || fail "OMP Calm regression: $out"
  assert_contains "$out" "presentation-and-restore-ok" "OMP Calm checks did not complete"
  pass "OMP Calm preserves substantive/final/streaming text and restores layered settings and home-scoped preference"
}

test_calm_controls_and_boat() {
  prepare_fixture
  local out
  out=$(REPO="$TMP_ROOT/repo" node --input-type=module 2>&1 <<'JS'
import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const repo = process.env.REPO;
process.env.FM_HOME = `${repo}/boat-home`;
mkdirSync(`${process.env.FM_HOME}/config`, { recursive: true });
writeFileSync(`${process.env.FM_HOME}/config/calm`, "off\n");
const { Settings, use } = await import(pathToFileURL(`${repo}/node_modules/@oh-my-pi/pi-coding-agent/config/settings.mjs`));
const { default: calm } = await import(pathToFileURL(`${repo}/.omp/extensions/fm-calm.ts`));
use(new Settings());
const intervals = new Map();
let intervalId = 0;
const originalSet = globalThis.setInterval, originalClear = globalThis.clearInterval;
globalThis.setInterval = (callback, ms) => { const id = { id: ++intervalId, unref() {} }; intervals.set(id, { callback, ms }); return id; };
globalThis.clearInterval = id => intervals.delete(id);
try {
  const handlers = new Map(), widgets = new Map(), notices = [];
  let command;
  const tui = { requestRender() {} };
  const ctx = { mode: "tui", agent: { kind: "main" }, cwd: repo,
    sessionManager: { getBranch: () => [] },
    ui: {
      notify: (...args) => notices.push(args), rerenderMessage() {}, setWorkingMessage() {},
      setWidget(key, factory) {
        widgets.get(key)?.dispose();
        widgets.delete(key);
        if (factory) widgets.set(key, factory(tui));
      },
    },
  };
  calm({ on: (name, handler) => handlers.set(name, handler), registerAssistantTextRenderer() {}, registerCommand: (_name, value) => { command = value.handler; } });
  const preference = () => readFileSync(`${process.env.FM_HOME}/config/calm`, "utf8");
  const boat = () => widgets.get("calm-working-ship");
  const strip = value => value.replace(/\x1b\[[0-9;]*m/g, "");
  const tick = () => { for (const timer of [...intervals.values()]) timer.callback(); };
  handlers.get("session_start")({}, ctx);
  await command("off", ctx);
  assert.equal(preference(), "off\n", "explicit off must not toggle on");
  assert.deepEqual(notices.at(-1), ["Calm off", "info"]);
  await command("on", ctx);
  await command("on", ctx);
  assert.equal(preference(), "on\n", "repeated on stays on");
  assert.deepEqual(notices.at(-1), ["Calm on", "info"]);
  assert.equal(widgets.size, 0, "idle Calm never animates");
  handlers.get("agent_start")({}, ctx);
  assert.equal(intervals.size, 1, "one live scheduler");
  assert.equal([...intervals.values()][0].ms, 220);
  let rows = boat().render(40);
  assert.equal(rows.length, 2);
  assert.ok(strip(rows[0]).length <= 40);
  assert.equal(strip(rows[1]).length, 40);
  assert.ok(rows[0].includes("\x1b[33m◿│◣"), "yellow sail");
  assert.ok(rows[1].includes("\x1b[34m"), "blue sea");
  const initial = rows.map(strip);
  tick();
  rows = boat().render(40).map(strip);
  assert.equal(rows[0].indexOf("◿"), initial[0].indexOf("◿"), "wave tick does not move boat");
  assert.notEqual(rows[1], initial[1], "wave changes at 220ms");
  tick(); tick(); tick();
  rows = boat().render(40).map(strip);
  assert.equal(rows[0].indexOf("◿"), initial[0].indexOf("◿") + 1, "boat moves at 880ms");
  for (let i = 0; i < 200; i++) tick();
  rows = boat().render(7).map(strip);
  assert.ok(rows[0].length <= 7);
  assert.equal(rows[1].length, 7, "resize clamps geometry");
  assert.ok(rows[1].indexOf("╲") >= 0 && rows[1].indexOf("╱") < 7);
  handlers.get("agent_start")({}, ctx);
  assert.equal(intervals.size, 1, "duplicate starts cannot duplicate schedulers");
  await command("off", ctx);
  assert.equal(widgets.size, 0);
  assert.equal(intervals.size, 0, "off clears animation");
  await command("on", ctx);
  assert.equal(widgets.size, 1, "on during run resumes boat");
  handlers.get("agent_end")({ messages: [] }, ctx);
  assert.equal(widgets.size, 0, "run end removes boat");
  assert.equal(intervals.size, 0);
  for (const stopReason of ["aborted", "error"]) {
    handlers.get("agent_start")({}, ctx);
    assert.equal(widgets.size, 1);
    handlers.get("agent_end")({ messages: [{ role: "assistant", stopReason }] }, ctx);
    assert.equal(widgets.size, 0, `${stopReason} clears boat`);
    assert.equal(intervals.size, 0);
  }
  handlers.get("agent_start")({}, ctx);
  handlers.get("session_shutdown")({}, ctx);
  assert.equal(widgets.size, 0, "shutdown clears boat");
  assert.equal(intervals.size, 0, "shutdown disposes scheduler");
  handlers.get("session_start")({}, ctx);
  await command("", ctx);
  assert.equal(preference(), "off\n", "bare command still toggles");
} finally {
  globalThis.setInterval = originalSet;
  globalThis.clearInterval = originalClear;
}
console.log("controls-and-boat-ok");
JS
) || fail "OMP Calm controls and boat: $out"
  assert_contains "$out" "controls-and-boat-ok" "OMP Calm controls and boat checks did not complete"
  pass "explicit Calm controls and active-only shared boat preserve cadence, resize bounds and cleanup"
}

fm_test_run test_calm_rendering_and_restore test_calm_controls_and_boat
