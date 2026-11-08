// Display-only Firstmate Calm using OMP's supported settings and text-renderer hooks.
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import { findScopedSettings, type Settings } from "@oh-my-pi/pi-coding-agent/config/settings";
import { lookup, type AnySetting } from "@oh-my-pi/pi-coding-agent/config/registry";
import { calmTextIsSubstantive } from "../../.claude/mods/firstmate-calm/lib/fm-calm-preservation.ts";

export default function (pi: ExtensionAPI): void {
  const codeRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
  const home = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || codeRoot;
  const preferencePath = resolve(process.env.FM_CONFIG_OVERRIDE || resolve(home, "config"), "calm");
  let active = false;
  let settings: Settings | undefined;
  let previous: { setting: AnySetting; value: boolean; runtime: boolean }[] = [];
  // OMP's display segments rewrite stopReason to "stop" and omit tool calls.
  // Keep only classification metadata from the original messages, never change them.
  const midTurnMessages = new Set<number>();

  function rememberStep(message: {
    timestamp: number; stopReason: string; content: readonly { type: string }[];
  }): void {
    if (message.stopReason === "toolUse" || (
      message.stopReason === "length" && message.content.some(block => block.type === "toolCall")
    )) midTurnMessages.add(message.timestamp);
    else midTurnMessages.delete(message.timestamp);
  }

  function loadPreference(): boolean {
    try {
      const value = readFileSync(preferencePath, "utf8").trim();
      return value === "on" || value === "max";
    } catch {
      return false;
    }
  }

  function persistPreference(enabled: boolean): void {
    mkdirSync(dirname(preferencePath), { recursive: true });
    const temporaryPath = `${preferencePath}.${process.pid}.${randomUUID()}.tmp`;
    try {
      writeFileSync(temporaryPath, enabled ? "on\n" : "off\n", {
        encoding: "utf8", flag: "wx", mode: 0o600,
      });
      renameSync(temporaryPath, preferencePath);
    } finally {
      rmSync(temporaryPath, { force: true });
    }
  }

  function apply(enabled: boolean, ctx: ExtensionContext): void {
    if (active === enabled) return;
    if (!settings) throw new Error("OMP's live settings are unavailable");
    if (enabled) {
      const snapshot = [
        "display.hideToolActivity", "hideThinkingBlock", "extensionRenderers.assistantText",
      ].map(id => {
        const setting = lookup(id);
        if (!setting || setting.type !== "boolean") throw new Error(`OMP setting unavailable: ${id}`);
        const value = setting.get(settings!);
        if (typeof value !== "boolean") throw new Error(`OMP setting is not boolean: ${id}`);
        return { setting, value, runtime: settings!.hasRuntimeOverride(setting) };
      });
      previous = snapshot;
      active = true;
      for (const { setting } of previous) setting.override(settings, true);
    } else {
      active = false;
      for (const { setting, value, runtime } of previous) {
        if (runtime) setting.override(settings, value);
        else {
          setting.clearOverride(settings);
          // Built-in visibility keys persist their own choice even during Calm.
          // Still restore the exact pre-Calm value in this session.
          if (setting.get(settings) !== value) setting.override(settings, value);
        }
      }
      previous = [];
    }
    // OMP observes setting changes and rebuilds tool/thinking visibility itself.
    // Explicitly rerun text transforms as well when the renderer gate was already on.
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "message" && entry.message.role === "assistant") {
        ctx.ui.rerenderMessage(entry.message.timestamp);
      }
    }
  }

  pi.registerAssistantTextRenderer(({ message, text, streaming }) => {
    if (!active || streaming || calmTextIsSubstantive(text)) return undefined;
    const midTurn = midTurnMessages.has(message.timestamp) || message.stopReason === "toolUse" || (
      message.stopReason === "length" && message.content.some(block => block.type === "toolCall")
    );
    return midTurn ? "" : undefined;
  });

  pi.on("session_start", (_event, ctx) => {
    if (ctx.mode !== "tui" || ctx.agent.kind !== "main") return;
    settings = findScopedSettings(ctx.cwd);
    midTurnMessages.clear();
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "message" && entry.message.role === "assistant") rememberStep(entry.message);
    }
    apply(loadPreference(), ctx);
    // OMP 18.18 attaches its live UI-settings listener AFTER session_start.
    // Startup changes reach settings/renderers, but its cached visibility flags
    // can still reflect the pre-Calm values. Do not patch OMP or synthesize keys.
    if (active) {
      const keys = previous.filter(({ setting, value }) => !value && setting.id !== "extensionRenderers.assistantText")
        .map(({ setting }) => setting.id === "hideThinkingBlock" ? "Ctrl+T (thinking)" : "Ctrl+Shift+O (tools)");
      if (keys.length) ctx.ui.notify(`Calm on; if startup rows remain, run /calm twice, or press ${keys.join(" and ")}.`, "info");
    }
  });

  pi.on("message_end", (event, ctx) => {
    if (ctx.mode !== "tui" || ctx.agent.kind !== "main" || event.message.role !== "assistant") return;
    rememberStep(event.message);
    if (active) ctx.ui.rerenderMessage(event.message.timestamp);
  });

  pi.on("session_shutdown", (_event, ctx) => {
    if (ctx.mode === "tui" && ctx.agent.kind === "main") apply(false, ctx);
  });

  pi.registerCommand("calm", {
    description: "Toggle Firstmate Calm (display only; persists across restarts).",
    handler: async (_args, ctx) => {
      if (ctx.mode !== "tui" || ctx.agent.kind !== "main") return;
      const enabled = !active;
      try {
        persistPreference(enabled);
      } catch (error) {
        ctx.ui.notify(`Calm unchanged: could not save preference: ${String(error)}`, "error");
        return;
      }
      apply(enabled, ctx);
      ctx.ui.notify(`Calm ${enabled ? "on" : "off"}`, "info");
    },
  });
}
