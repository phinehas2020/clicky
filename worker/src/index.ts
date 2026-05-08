/**
 * Clicky Proxy Worker
 *
 * Proxies requests to AI/audio APIs so the app never
 * ships with raw API keys. Keys are stored as Cloudflare secrets.
 *
 * Routes:
 *   POST /chat  → Anthropic Messages API (streaming)
 *   POST /tts   → ElevenLabs TTS API
 *   POST /realtime-client-secret → OpenAI Realtime client secret
 *   POST /xai-realtime-client-secret → xAI Voice Agent client secret
 */

interface Env {
  ANTHROPIC_API_KEY: string;
  OPENAI_API_KEY: string;
  XAI_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;
  [key: string]: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }

      if (url.pathname === "/tts") {
        return await handleTTS(request, env);
      }

      if (url.pathname === "/transcribe-token") {
        return await handleTranscribeToken(env);
      }

      if (url.pathname === "/realtime-client-secret") {
        return await handleRealtimeClientSecret(env);
      }

      if (url.pathname === "/xai-realtime-client-secret") {
        return await handleXAIRealtimeClientSecret(env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleChat(request: Request, env: Env): Promise<Response> {
  const body = await request.text();

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body,
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] Anthropic API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

async function handleXAIRealtimeClientSecret(env: Env): Promise<Response> {
  if (!env.XAI_API_KEY) {
    console.error("[/xai-realtime-client-secret] No xAI API key binding found");
    return new Response(
      JSON.stringify({ error: "XAI_API_KEY secret is not configured." }),
      { status: 500, headers: { "content-type": "application/json" } }
    );
  }

  console.log("[/xai-realtime-client-secret] Minting xAI Realtime client secret");
  const startedAt = Date.now();

  const response = await fetch("https://api.x.ai/v1/realtime/client_secrets", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.XAI_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      expires_after: {
        seconds: 300,
      },
    }),
  });

  const body = await response.text();
  const durationMs = Date.now() - startedAt;

  if (!response.ok) {
    console.error(`[/xai-realtime-client-secret] xAI API error ${response.status} in ${durationMs}ms: ${body}`);
    return new Response(body, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  console.log(`[/xai-realtime-client-secret] xAI returned ${response.status} in ${durationMs}ms (${body.length} bytes)`);

  return new Response(body, {
    status: 200,
    headers: { "content-type": response.headers.get("content-type") || "application/json" },
  });
}

async function handleRealtimeClientSecret(env: Env): Promise<Response> {
  const openAIAPIKey = resolveOpenAIAPIKey(env);
  if (!openAIAPIKey) {
    console.error("[/realtime-client-secret] No OpenAI API key binding found");
    return new Response(
      JSON.stringify({ error: "OPENAI_API_KEY secret is not configured." }),
      { status: 500, headers: { "content-type": "application/json" } }
    );
  }

  const secretSource = env.OPENAI_API_KEY ? "OPENAI_API_KEY" : "sk-prefixed binding";
  console.log(`[/realtime-client-secret] Minting OpenAI Realtime client secret using ${secretSource}`);
  const startedAt = Date.now();

  const response = await fetch("https://api.openai.com/v1/realtime/client_secrets", {
    method: "POST",
    headers: {
      authorization: `Bearer ${openAIAPIKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      session: {
        type: "realtime",
        model: "gpt-realtime-2",
        output_modalities: ["audio"],
        audio: {
          output: {
            voice: "marin",
          },
        },
      },
    }),
  });

  const body = await response.text();
  const durationMs = Date.now() - startedAt;

  if (!response.ok) {
    console.error(`[/realtime-client-secret] OpenAI API error ${response.status} in ${durationMs}ms: ${body}`);
    return new Response(body, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  console.log(`[/realtime-client-secret] OpenAI returned ${response.status} in ${durationMs}ms (${body.length} bytes)`);

  return new Response(body, {
    status: 200,
    headers: { "content-type": response.headers.get("content-type") || "application/json" },
  });
}

function resolveOpenAIAPIKey(env: Env): string | undefined {
  if (env.OPENAI_API_KEY) {
    return env.OPENAI_API_KEY;
  }

  const secretNamedAfterKey = Object.keys(env).find((key) => key.startsWith("sk-"));
  return secretNamedAfterKey ? env[secretNamedAfterKey] : undefined;
}

async function handleTranscribeToken(env: Env): Promise<Response> {
  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY,
      },
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-token] AssemblyAI token error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  const data = await response.text();
  return new Response(data, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function handleTTS(request: Request, env: Env): Promise<Response> {
  const body = await request.text();
  const voiceId = env.ELEVENLABS_VOICE_ID;

  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body,
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] ElevenLabs API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg",
    },
  });
}
