/**
 * pi-talk - Text-to-speech extension for Pi
 *
 * Adds text-to-speech capabilities to Pi using <voice> tags.
 * Speaks only <voice> tagged content from assistant responses.
 *
 * Requires Loqui.app (TTS server at localhost:18080).
 * Install with: brew install swairshah/tap/loqui
 *
 * Commands:
 *   /tts        - Toggle TTS on/off
 *   /tts-mute   - Mute audio (keeps voice tags in responses)
 *   /tts-style  - Toggle voice style (succinct/verbose)
 *   /tts-voice  - Change TTS voice
 *   /tts-say    - Speak arbitrary text
 *   /tts-stop   - Stop current speech
 *   /tts-status - Show status
 *
 * Global shortcut (via Loqui.app): Cmd+. to stop speech
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import net from "node:net";
import process from "node:process";

// Configuration - matches Loqui defaults
const TTS_PORT = 18080;
const TTS_HOST = "127.0.0.1";
const BROKER_PORT = 18081;
const AVAILABLE_VOICES = ["auto", "alba", "marius", "javert", "fantine", "cosette", "eponine", "azelma"];

// System prompt injection for voice tags - succinct style
const VOICE_PROMPT_SUCCINCT = `
## Voice Output

You have text-to-speech capabilities. When responding, include natural spoken summaries using <voice> tags.

Guidelines for <voice> content:
- Keep it brief and conversational (1-3 sentences)
- Summarize what you're doing or found, don't read code/details verbatim
- Use natural speech patterns, contractions, casual tone
- Place <voice> tags at natural pause points in your response
- Use ONLY <voice>...</voice> tags for speech
- Never use other tags anywhere (no <emphasis>, <strong>, SSML, XML, or HTML tags)
- Never nest tags inside <voice>; keep voice text plain
- For code: describe what it does, don't read the code itself
- For errors: summarize the issue conversationally
- For confirmations: keep it simple like "Done!" or "Got it, working on that."

Examples:
- Starting work: <voice>Okay, let me look into that for you.</voice>
- Found something: <voice>Found the issue. Looks like there's a typo in the config file.</voice>
- Completed task: <voice>All done! Created the new component with the props you asked for.</voice>
- Explaining code: <voice>This function takes a list of users and filters out the inactive ones.</voice>

The text outside <voice> tags shows normally in the terminal. Only <voice> content is spoken.
`;

// System prompt injection for voice tags - verbose/conversational style
const VOICE_PROMPT_VERBOSE = `
## Voice Output

You have text-to-speech capabilities. When responding, use <voice> tags liberally to speak conversationally with the user.

Guidelines for <voice> content:
- Speak most of your conversational responses - questions, comments, reactions, explanations
- Use natural speech patterns, contractions, casual tone
- Multiple <voice> tags per response is encouraged
- Speak your thinking process, questions, and follow-ups
- Use ONLY <voice>...</voice> tags for speech
- Never use other tags anywhere (no <emphasis>, <strong>, SSML, XML, or HTML tags)
- Never nest tags inside <voice>; keep voice text plain
- For code: describe what it does (don't read the code itself)
- For file contents and technical details: summarize rather than read verbatim
- For errors: explain what went wrong conversationally
- For questions to the user: always speak them

Examples:
- Starting work: <voice>Okay, let me look into that for you.</voice>
- Thinking aloud: <voice>Hmm, this looks like it might be a permissions issue. Let me check the file ownership.</voice>
- Asking questions: <voice>Do you want me to fix this automatically, or would you rather review it first?</voice>
- Casual remarks: <voice>Nice! That test is passing now.</voice>
- Explaining findings: <voice>So I found the bug. Basically the loop was off by one, so it was skipping the last item in the array. Pretty common mistake actually.</voice>
- Follow-ups: <voice>That should do it! Let me know if you want me to add any tests for this.</voice>

The text outside <voice> tags shows normally in the terminal. Only <voice> content is spoken.
Speak freely and conversationally - the user prefers hearing your responses.
`;

type BrokerRequest = {
  type: "health" | "speak" | "stop";
  text?: string;
  voice?: string;
  sourceApp?: string;
  sessionId?: string;
  pid?: number;
};

type BrokerResponse = {
  ok?: boolean;
  error?: string;
  queued?: number;
  pending?: number;
  playing?: boolean;
};

export default function (pi: ExtensionAPI) {
  let ttsEnabled = true;       // Master switch - controls everything
  let ttsMuted = false;        // Just mute audio, keep voice tags
  let serverReady = false;
  let serverWarningShown = false;  // Only show server warning once per session
  let voiceStyle: "succinct" | "verbose" = "verbose";  // Voice prompt style
  let currentVoice = "auto";  // Current TTS voice ("auto" = let Loqui assign per-session)
  let currentSessionId: string | undefined;

  // Streaming state
  let voiceBuffer = "";
  let processedUpTo = 0;

  function sendBrokerCommand(command: BrokerRequest, timeoutMs = 2500): Promise<BrokerResponse> {
    return new Promise((resolve, reject) => {
      const socket = net.createConnection({ host: TTS_HOST, port: BROKER_PORT });
      socket.setEncoding("utf8");

      let settled = false;
      let buffer = "";

      const finish = (fn: () => void) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        fn();
      };

      const timeout = setTimeout(() => {
        finish(() => {
          socket.destroy();
          reject(new Error("Loqui broker timeout"));
        });
      }, timeoutMs);

      socket.on("connect", () => {
        socket.write(`${JSON.stringify(command)}\n`);
        socket.end();
      });

      socket.on("data", (chunk) => {
        buffer += chunk;
        const idx = buffer.indexOf("\n");
        if (idx === -1) return;

        const line = buffer.slice(0, idx).trim();
        finish(() => {
          socket.destroy();
          if (!line) {
            reject(new Error("Empty broker response"));
            return;
          }
          try {
            resolve(JSON.parse(line) as BrokerResponse);
          } catch {
            reject(new Error("Invalid broker response"));
          }
        });
      });

      socket.on("error", (err) => {
        finish(() => reject(err));
      });

      socket.on("end", () => {
        if (settled) return;
        const line = buffer.trim();
        finish(() => {
          if (!line) {
            reject(new Error("No broker response"));
            return;
          }
          try {
            resolve(JSON.parse(line) as BrokerResponse);
          } catch {
            reject(new Error("Invalid broker response"));
          }
        });
      });
    });
  }

  // Check if Loqui server + broker are running
  async function checkServer(): Promise<boolean> {
    try {
      const res = await fetch(`http://${TTS_HOST}:${TTS_PORT}/health`);
      if (!res.ok) {
        serverReady = false;
        return false;
      }

      const broker = await sendBrokerCommand({ type: "health" });
      serverReady = broker.ok === true;
      return serverReady;
    } catch {
      serverReady = false;
      return false;
    }
  }

  // Extract <voice> tags from text
  function extractVoiceTags(text: string, fromIndex: number): { content: string; endIndex: number }[] {
    const results: { content: string; endIndex: number }[] = [];
    const regex = /<voice>([\s\S]*?)<\/voice>/g;
    regex.lastIndex = fromIndex;

    let match;
    while ((match = regex.exec(text)) !== null) {
      results.push({
        content: match[1].trim(),
        endIndex: match.index + match[0].length,
      });
    }

    return results;
  }

  // Strip any accidental nested markup from voice content (e.g. <emphasis>)
  function sanitizeVoiceContent(text: string): string {
    return text.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
  }

  async function enqueueSpeech(text: string) {
    if (!text.trim()) return;

    try {
      const response = await sendBrokerCommand({
        type: "speak",
        text,
        voice: currentVoice === "auto" ? undefined : currentVoice,
        sourceApp: "pi",
        sessionId: currentSessionId,
        pid: process.pid,
      });

      if (!response.ok) {
        console.log("[TTS] Broker rejected speech:", response.error ?? "unknown error");
      }
    } catch (err) {
      console.log("[TTS] Broker error:", err);
      serverReady = false;
    }
  }

  // Process streaming text for voice tags
  async function processStreamingText(fullText: string) {
    if (!ttsEnabled) return;

    // Retry server check if not ready
    if (!serverReady) {
      await checkServer();
      if (!serverReady) return;
    }

    voiceBuffer = fullText;

    // Find complete <voice> tags we haven't processed yet
    const voiceTags = extractVoiceTags(voiceBuffer, processedUpTo);

    for (const tag of voiceTags) {
      const clean = sanitizeVoiceContent(tag.content);
      if (clean) {
        // Fire-and-forget to avoid blocking token stream updates
        void enqueueSpeech(clean);
      }
      processedUpTo = tag.endIndex;
    }
  }

  function resetStreamingState() {
    voiceBuffer = "";
    processedUpTo = 0;
  }

  // Inject voice prompt into system prompt (only if TTS enabled)
  pi.on("before_agent_start", async (event) => {
    if (!ttsEnabled) return; // Don't inject voice prompt if disabled
    const prompt = voiceStyle === "verbose" ? VOICE_PROMPT_VERBOSE : VOICE_PROMPT_SUCCINCT;
    return {
      systemPrompt: event.systemPrompt + "\n" + prompt,
    };
  });

  // Check server on session start
  pi.on("session_start", async (_event, ctx) => {
    currentSessionId = ctx.sessionManager.getSessionId();
    serverWarningShown = false;  // Reset for new session

    // Show PID in status bar (used by PiTalk jump handler to identify panes)
    ctx.ui.setStatus("pid", `↓${process.pid}`);

    const ready = await checkServer();
    if (ttsEnabled) {
      if (ready) {
        ctx.ui.notify("🔊 TTS connected", "info");
        ctx.ui.setStatus("tts", "🔊");
      } else {
        if (!serverWarningShown) {
          ctx.ui.notify(
            "⚠️ Loqui broker not running. Start/update Loqui.app (or install with: brew install swairshah/tap/loqui)",
            "warning"
          );
          serverWarningShown = true;
        }
        ctx.ui.setStatus("tts", "⚠️");
      }
    } else {
      ctx.ui.setStatus("tts", "🔇 off");
    }
  });

  pi.on("session_switch", async (_event, ctx) => {
    currentSessionId = ctx.sessionManager.getSessionId();
  });

  pi.on("message_start", async (event) => {
    if (event.message.role === "assistant") {
      resetStreamingState();
      // Re-check server in case it was started/stopped
      await checkServer();
    }
  });

  pi.on("message_update", async (event) => {
    if (!ttsEnabled || ttsMuted) return;

    const msg = event.message;
    if (msg.role !== "assistant") return;

    const textParts = msg.content
      .filter((c): c is { type: "text"; text: string } => c.type === "text")
      .map((c) => c.text);

    const fullText = textParts.join(" ");
    void processStreamingText(fullText);
  });

  pi.on("message_end", async (event) => {
    if (event.message.role === "assistant") {
      resetStreamingState();
    }
  });

  // Helper to update status display
  function updateStatus(ctx: { ui: { setStatus: (id: string, text: string) => void } }) {
    if (!ttsEnabled) {
      ctx.ui.setStatus("tts", "🔇 off");
    } else if (ttsMuted) {
      ctx.ui.setStatus("tts", "🔇");
    } else if (serverReady) {
      ctx.ui.setStatus("tts", voiceStyle === "verbose" ? "🔊+" : "🔊");
    } else {
      ctx.ui.setStatus("tts", "⚠️");
    }
  }

  // Commands
  pi.registerCommand("tts", {
    description: "Toggle TTS completely on/off (includes voice prompt injection)",
    handler: async (_args, ctx) => {
      ttsEnabled = !ttsEnabled;
      ttsMuted = false; // Reset mute when toggling master
      ctx.ui.notify(
        ttsEnabled
          ? "🔊 TTS enabled - I'll include voice summaries"
          : "🔇 TTS disabled - normal text responses",
        "info"
      );
      updateStatus(ctx);
    },
  });

  pi.registerCommand("tts-mute", {
    description: "Mute/unmute TTS audio (keeps voice tags in responses)",
    handler: async (_args, ctx) => {
      if (!ttsEnabled) {
        ctx.ui.notify("TTS is disabled. Use /tts to enable first.", "warning");
        return;
      }
      ttsMuted = !ttsMuted;
      ctx.ui.notify(ttsMuted ? "🔇 TTS muted" : "🔊 TTS unmuted", "info");
      updateStatus(ctx);
    },
  });

  pi.registerCommand("tts-style", {
    description: "Toggle voice style: succinct (brief summaries) or verbose (more conversational)",
    handler: async (_args, ctx) => {
      voiceStyle = voiceStyle === "verbose" ? "succinct" : "verbose";
      ctx.ui.notify(
        voiceStyle === "verbose"
          ? "🔊+ Voice style: verbose (more conversational)"
          : "🔊 Voice style: succinct (brief summaries)",
        "info"
      );
      updateStatus(ctx);
    },
  });

  pi.registerCommand("tts-voice", {
    description: `Change TTS voice (${AVAILABLE_VOICES.join(", ")})`,
    handler: async (args, ctx) => {
      if (!args) {
        const voiceDisplay = currentVoice === "auto" ? "auto (Loqui assigns per-session)" : currentVoice;
        ctx.ui.notify(`Current voice: ${voiceDisplay}\nAvailable: ${AVAILABLE_VOICES.join(", ")}`, "info");
        return;
      }
      const voice = args.trim().toLowerCase();
      if (!AVAILABLE_VOICES.includes(voice)) {
        ctx.ui.notify(`Unknown voice: ${voice}\nAvailable: ${AVAILABLE_VOICES.join(", ")}`, "warning");
        return;
      }
      currentVoice = voice;
      const msg = voice === "auto" 
        ? "🎤 Voice: auto (Loqui will assign different voices per session)"
        : `🎤 Voice changed to: ${voice}`;
      ctx.ui.notify(msg, "info");
    },
  });

  pi.registerCommand("tts-say", {
    description: "Speak arbitrary text",
    handler: async (args, ctx) => {
      if (!args) {
        ctx.ui.notify("Usage: /tts-say <text>", "warning");
        return;
      }
      if (!serverReady) {
        const ready = await checkServer();
        if (!ready) {
          ctx.ui.notify("Loqui broker not running", "error");
          return;
        }
      }
      await enqueueSpeech(args);
    },
  });

  pi.registerCommand("tts-stop", {
    description: "Stop current speech",
    handler: async (_args, ctx) => {
      try {
        await sendBrokerCommand({ type: "stop" });
        ctx.ui.notify("Speech stopped", "info");
      } catch {
        ctx.ui.notify("Could not reach Loqui broker", "warning");
      }
    },
  });

  pi.registerCommand("tts-status", {
    description: "Show TTS status",
    handler: async (_args, ctx) => {
      const ready = await checkServer();
      const voiceDisplay = currentVoice === "auto" ? "auto (per-session)" : currentVoice;
      const status = [
        `Server: ${ready ? "running ✓" : "not running ✗"}`,
        `TTS: ${ttsEnabled ? "enabled" : "disabled"}`,
        `Audio: ${ttsMuted ? "muted" : "on"}`,
        `Voice: ${voiceDisplay}`,
        `Style: ${voiceStyle}`,
        `Session: ${currentSessionId ?? "unknown"}`,
      ].join(" | ");
      ctx.ui.notify(status, "info");
      updateStatus(ctx);
    },
  });
}
