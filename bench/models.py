"""Model API adapters for OpenRouter and local models."""

import json
import os
import time
from collections.abc import Iterator

import requests


# ---------------------------------------------------------------------------
# Context-window registry
# ---------------------------------------------------------------------------
# Claude Code's agent pattern keeps the full transcript in context until the
# window is about to overflow, at which point ONE compaction call collapses
# old turns. To do that we need to know each model's window. Static entries
# here cover the common benchmark targets; unknown models fall back to
# OpenRouter's /api/v1/models endpoint, cached per-process. If even that
# fails we assume 128k — conservative for modern models, still big enough
# for a typical Balatro run before compaction kicks in.
STATIC_CONTEXT_WINDOWS: dict[str, int] = {
    # DeepSeek
    "deepseek/deepseek-v3.2": 163_840,
    "deepseek/deepseek-v3": 163_840,
    "deepseek/deepseek-chat": 163_840,
    "deepseek/deepseek-r1": 163_840,

    # Anthropic. Current as of April 2026: Opus 4.7 / Sonnet 4.6 / Haiku
    # 4.5 are the latest generation; Opus 4.7 + Sonnet 4.6 have 1M-token
    # windows, Haiku 4.5 has 200k. Legacy Opus 4.6 is also 1M; everything
    # older (Sonnet 4.5, Opus 4.5, Opus 4.1, the 4-20250514 pair) is
    # 200k. Source: platform.claude.com/docs/en/about-claude/models/overview
    # We also register the raw "claude-*" IDs (no `anthropic/` prefix)
    # because the native AnthropicAdapter passes the bare ID to the API.
    "claude-opus-4-7": 1_000_000,
    "claude-sonnet-4-6": 1_000_000,
    "claude-haiku-4-5": 200_000,
    "claude-haiku-4-5-20251001": 200_000,
    # Legacy / still-available
    "claude-opus-4-6": 1_000_000,
    "claude-sonnet-4-5": 200_000,
    "claude-sonnet-4-5-20250929": 200_000,
    "claude-opus-4-5": 200_000,
    "claude-opus-4-5-20251101": 200_000,
    "claude-opus-4-1": 200_000,
    "claude-opus-4-1-20250805": 200_000,
    # Deprecated (scheduled retirement 2026-06-15), kept for historical
    # result scoring so old runs don't fall off the leaderboard.
    "claude-sonnet-4-20250514": 200_000,
    "claude-opus-4-20250514": 200_000,
    "claude-3-haiku-20240307": 200_000,
    # OpenRouter-prefixed alternates (for users benchmarking Claude
    # through OpenRouter rather than direct Anthropic):
    "anthropic/claude-opus-4.7": 1_000_000,
    "anthropic/claude-sonnet-4.6": 1_000_000,
    "anthropic/claude-haiku-4.5": 200_000,
    "anthropic/claude-opus-4.6": 1_000_000,
    "anthropic/claude-sonnet-4.5": 200_000,
    "anthropic/claude-opus-4.5": 200_000,

    # OpenAI. As of April 2026 the GPT-5.4 family is current; GPT-5,
    # GPT-4.1, and GPT-4o remain API-available even though retired from
    # ChatGPT. The codex variants are specialized for agentic coding but
    # still accept general chat completions. GPT-5.4 family shares the
    # 400k context of the GPT-5 line. Source:
    # developers.openai.com/api/docs/models/all
    "gpt-5.4": 400_000,
    "gpt-5.4-pro": 400_000,
    "gpt-5.4-mini": 400_000,
    "gpt-5.4-nano": 400_000,
    "gpt-5": 400_000,
    "gpt-5-mini": 400_000,
    "gpt-5-nano": 400_000,
    # Coding-specialist snapshots (still chat-completions compatible)
    "gpt-5-codex": 400_000,
    "gpt-5.1-codex": 400_000,
    "gpt-5.1-codex-max": 400_000,
    "gpt-5.1-codex-mini": 400_000,
    "gpt-5.2-codex": 400_000,
    "gpt-5.3-codex": 400_000,
    # GPT-4.1 / 4o family (still API-available)
    "gpt-4.1": 1_047_576,
    "gpt-4.1-mini": 1_047_576,
    "gpt-4.1-nano": 1_047_576,
    "gpt-4o": 128_000,
    "gpt-4o-mini": 128_000,
    "gpt-3.5-turbo": 16_385,
    # OpenRouter-prefixed alternates
    "openai/gpt-5.4": 400_000,
    "openai/gpt-5.4-mini": 400_000,
    "openai/gpt-5.4-nano": 400_000,
    "openai/gpt-5": 400_000,
    "openai/gpt-5-mini": 400_000,
    "openai/gpt-4.1": 1_047_576,
    "openai/gpt-4o": 128_000,

    # Google Gemini. Current lineup (April 2026): the Gemini 3.1 Pro /
    # 3 Flash / 3.1 Flash-Lite previews are the latest generation, all
    # with 1M-token context. Gemini 2.5 family remains active for cost-
    # optimized use. gemini-3-pro-preview was SHUT DOWN on 2026-03-09
    # — we include it here only so old scored runs can still resolve.
    # Source: ai.google.dev/gemini-api/docs/models
    "gemini-3.1-pro-preview": 1_000_000,
    "gemini-3-flash-preview": 1_000_000,
    "gemini-3.1-flash-lite-preview": 1_000_000,
    "gemini-2.5-pro": 1_000_000,
    "gemini-2.5-flash": 1_000_000,
    "gemini-2.5-flash-lite": 1_000_000,
    # Deprecated / retired — kept for score backfill
    "gemini-3-pro-preview": 1_000_000,
    "gemini-2.0-flash": 1_000_000,
    "gemini-2.0-flash-lite": 1_000_000,
    "gemini-1.5-pro": 2_000_000,
    "gemini-1.5-flash": 1_000_000,
    # OpenRouter-prefixed alternates
    "google/gemini-3.1-pro-preview": 1_000_000,
    "google/gemini-3-flash-preview": 1_000_000,
    "google/gemini-3.1-flash-lite-preview": 1_000_000,
    "google/gemini-2.5-pro": 1_000_000,
    "google/gemini-2.5-flash": 1_000_000,

    # xAI
    "x-ai/grok-4": 256_000,
    "x-ai/grok-4.1": 256_000,
    "x-ai/grok-4.1-fast": 256_000,

    # Meta / Nvidia
    "meta-llama/llama-3.3-70b-instruct": 131_072,
    "meta-llama/llama-3.1-405b-instruct": 131_072,
    "nvidia/nemotron-70b": 131_072,

    # Mistral
    "mistralai/mistral-large": 128_000,
    "mistralai/mixtral-8x22b-instruct": 64_000,

    # Amazon
    "amazon/nova-2-lite-v1": 300_000,
    "amazon/nova-pro-v1": 300_000,

    # MiniMax / Arcee / Inception / Liquid (often benchmarked free tier)
    "minimax/minimax-m2": 196_000,
    "arcee-ai/trinity-large-preview": 64_000,
    "liquid/lfm-2.5-1.2b-thinking": 32_000,

    # Inception Labs — Mercury is their diffusion-based LLM family.
    # Native API IDs (no provider prefix) for the direct `inception`
    # provider; OpenRouter aliases kept separately. Context windows from
    # docs.inceptionlabs.ai.
    "mercury": 32_000,
    "mercury-coder": 32_000,
    "mercury-2": 128_000,
    "mercury-2-mini": 128_000,
    # OpenRouter-prefixed alternates
    "inception/mercury-2": 128_000,
    "inception/mercury-coder": 32_000,

    # Cerebras Inference. Runs open-weight models on wafer-scale chips —
    # the endpoint returns whichever models the account's tier entitles.
    # Confirmed live against api.cerebras.ai/v1/models (April 2026). The
    # context windows below are each model's native capacity; Cerebras
    # may throttle to a lower per-request limit on some tiers but that
    # affects request size, not the model's reasoning capacity.
    "gpt-oss-120b": 128_000,
    "zai-glm-4.7": 128_000,
    "qwen-3-235b-a22b-instruct-2507": 256_000,
    "llama3.1-8b": 128_000,
    # Other Cerebras-hosted models you may hit on different tiers:
    "llama-3.3-70b": 128_000,
    "llama-4-scout-17b-16e-instruct": 128_000,
    "qwen-3-32b": 128_000,
    "qwen-3-coder-480b": 128_000,

    # OpenCode gateway free tier (April 2026). These get routed through
    # `opencode serve` with no API key — billed against OpenCode's free
    # quota, not the underlying vendor. Context windows below are each
    # base model's nominal capacity; OpenCode itself burns ~9.5k tokens
    # of system prompt overhead per request, which the OpencodeAdapter
    # subtracts when reporting effective window to the runner.
    "opencode/gpt-5-nano": 400_000,
    "opencode/minimax-m2.5-free": 196_000,
    "opencode/nemotron-3-super-free": 128_000,
    "opencode/qwen3.6-plus-free": 256_000,
    "opencode/big-pickle": 128_000,  # unknown base model — conservative default
}

DEFAULT_CONTEXT_WINDOW = 128_000

# Cached lookups from OpenRouter's /models endpoint (one fetch per process).
_OR_MODELS_CACHE: dict[str, int] | None = None


def _fetch_openrouter_model_windows() -> dict[str, int]:
    """Pull context_length per model from OpenRouter's catalog. Best-effort:
    returns {} on any failure so callers just fall through to defaults."""
    global _OR_MODELS_CACHE
    if _OR_MODELS_CACHE is not None:
        return _OR_MODELS_CACHE
    try:
        r = requests.get("https://openrouter.ai/api/v1/models", timeout=10)
        r.raise_for_status()
        data = r.json()
        out: dict[str, int] = {}
        for m in data.get("data") or []:
            mid = m.get("id")
            ctx = m.get("context_length")
            if isinstance(mid, str) and isinstance(ctx, int) and ctx > 0:
                out[mid] = ctx
                # Strip `:free`, `:nitro`, etc. variant tags so users who
                # benchmark `deepseek/deepseek-v3.2:free` still hit the
                # same base entry.
                base = mid.split(":", 1)[0]
                out.setdefault(base, ctx)
        _OR_MODELS_CACHE = out
        return out
    except Exception:  # noqa: BLE001 — catalog is optional
        _OR_MODELS_CACHE = {}
        return _OR_MODELS_CACHE


# ---------------------------------------------------------------------------
# Reasoning-mode support detection
# ---------------------------------------------------------------------------
# Each model-family has its own way of expressing "think harder before you
# answer": OpenAI-style `reasoning_effort: "high"`, Anthropic-style
# `thinking.budget_tokens`, Gemini-style `thinkingConfig.thinkingBudget`.
# We always crank it to max where supported. For models that DON'T support
# reasoning (gpt-4o, mercury, llama-3.1), sending the param would either
# error (OpenAI strict) or be silently ignored (OpenRouter). So we only
# emit the param when we're confident the model supports it.
#
# REASONING_MAX_OUTPUT is the output-cap we bump to when reasoning is on.
# Reasoning tokens count against max_tokens on most providers; our normal
# 16k is too tight for a 32k thinking budget + final answer. 65k gives
# comfortable headroom without exceeding any modern model's per-request
# cap (Claude Sonnet 4.6 and Haiku 4.5 allow up to 64k output; Opus 4.7
# allows 128k; OpenAI reasoning models allow 100k+).
REASONING_MAX_OUTPUT = 65_536
# Thinking token budget for Anthropic/Gemini when we explicitly set one.
# Anthropic: must be < max_tokens, so 32k leaves ~32k headroom for answer.
# Gemini: we use -1 (dynamic/unlimited) instead of this value.
REASONING_THINKING_BUDGET = 32_000


# Patterns for known-safe reasoning models when talking DIRECTLY to a
# vendor's OpenAI-compatible endpoint (openai, cerebras). These are
# families where we've confirmed that `reasoning_effort: "high"` is
# accepted, not just silently ignored. Sending the param to a
# non-reasoning model on direct providers often returns HTTP 400 with
# "unrecognized parameter", so we're conservative here.
_DIRECT_REASONING_PATTERNS = (
    "gpt-5",      # gpt-5, gpt-5.4, gpt-5-codex, etc. (OpenAI)
    "o1",         # o1, o1-mini, o1-pro (OpenAI)
    "o3",         # o3, o3-mini (OpenAI)
    "o4",         # o4-mini (OpenAI)
    "gpt-oss",    # gpt-oss-120b/20b (OpenAI open-weights on Cerebras, etc.)
)

# Patterns we're willing to try via OpenRouter's unified reasoning spec.
# OpenRouter translates `reasoning: {effort: "high"}` to whatever the
# upstream expects and SILENTLY IGNORES it for non-reasoning models, so
# we can afford to match broadly here — false positives just result in
# the param being dropped.
_OPENROUTER_REASONING_PATTERNS = _DIRECT_REASONING_PATTERNS + (
    "claude-opus-4", "claude-sonnet-4", "claude-haiku-4",  # Anthropic thinking
    "claude-4", "claude-5",
    "gemini-2.5", "gemini-3",                              # Gemini thinking
    "qwen-3",                                              # Qwen thinking variants
    "glm-4.6", "glm-4.7", "zai-glm",                       # GLM reasoning
    "deepseek-r1", "deepseek-v3",                          # DeepSeek reasoning
    "kimi-k2",                                             # Kimi K2 thinking
    "minimax-m2",                                          # MiniMax M2 thinking
    "grok-4",                                              # Grok 4 reasoning
)


def supports_reasoning_effort(model_id: str, provider: str) -> bool:
    """Does this model/provider pair accept a reasoning-effort param?

    Direct providers (openai, cerebras) get a conservative whitelist —
    only models we're sure accept the param. OpenRouter gets a broader
    match because their API silently ignores unrecognized reasoning
    params rather than 400ing.

    Inception (Mercury) always returns False — diffusion models have no
    reasoning-effort knob.
    """
    if provider == "inception":
        return False
    if not model_id:
        return False
    mid = model_id.lower()
    patterns = (
        _OPENROUTER_REASONING_PATTERNS if provider == "openrouter"
        else _DIRECT_REASONING_PATTERNS
    )
    return any(pat in mid for pat in patterns)


def lookup_context_window(model_id: str, provider: str = "openrouter") -> int:
    """Resolve a model's context length. Order: static table → OpenRouter
    catalog (if provider=openrouter) → DEFAULT. Variant suffixes like `:free`
    are stripped for lookup."""
    if not model_id:
        return DEFAULT_CONTEXT_WINDOW
    # Try exact match, then base (strip ":free" / ":nitro" etc.)
    base = model_id.split(":", 1)[0]
    if model_id in STATIC_CONTEXT_WINDOWS:
        return STATIC_CONTEXT_WINDOWS[model_id]
    if base in STATIC_CONTEXT_WINDOWS:
        return STATIC_CONTEXT_WINDOWS[base]
    if provider == "openrouter":
        catalog = _fetch_openrouter_model_windows()
        if model_id in catalog:
            return catalog[model_id]
        if base in catalog:
            return catalog[base]
    return DEFAULT_CONTEXT_WINDOW


# ---------------------------------------------------------------------------
# Provider identifiers. The webapp and runner pass these strings around; the
# factory at the bottom of the file maps each to an adapter class.
# ---------------------------------------------------------------------------
PROVIDERS_OPENAI_COMPATIBLE = {"openrouter", "openai", "inception", "cerebras", "local", "custom"}
PROVIDER_ANTHROPIC = "anthropic"
PROVIDER_GOOGLE = "google"
# `opencode` and `codex` are CLI-driven wrappers — they shell out to a
# locally-installed CLI (opencode serve / codex exec) that handles its
# own auth. opencode uses the free opencode/* gateway with no key; codex
# uses the user's `~/.codex/auth.json` (typically ChatGPT subscription).
ALL_PROVIDERS = PROVIDERS_OPENAI_COMPATIBLE | {
    PROVIDER_ANTHROPIC, PROVIDER_GOOGLE, "opencode", "codex",
}


class ModelAdapter:
    """OpenAI-compatible chat completions adapter.

    Covers four providers that all speak the same /chat/completions wire
    format: OpenRouter (default), OpenAI directly, local Ollama / vLLM /
    llama.cpp, and "custom" (any OpenAI-compatible endpoint — xAI Grok's
    native API, Together, Groq, Fireworks, DeepSeek direct, etc.).

    Anthropic and Google use different wire formats and get their own
    adapter classes below; `make_adapter()` picks the right one.
    """

    def __init__(
        self,
        model: str,
        provider: str = "openrouter",
        endpoint: str | None = None,
        api_key: str | None = None,
        temperature: float = 0.3,
        max_tokens: int = 16384,
    ):
        # This is a benchmark: we never want to artificially cap the model's
        # reasoning. 16384 is high enough for any reasonable chain-of-thought
        # (GPT-4o caps around 16k, Claude 8k, DeepSeek-R1 32k). The provider
        # will clip to its own max if ours exceeds it. Short answers from
        # non-reasoning models don't cost more — billing is per OUTPUT token
        # emitted, not per max_tokens requested.
        self.model = model
        self.provider = provider
        self.temperature = temperature
        self.max_tokens = max_tokens

        # Resolve endpoint
        if endpoint:
            self.endpoint = endpoint.rstrip("/")
        elif provider == "openrouter":
            self.endpoint = "https://openrouter.ai/api/v1"
        elif provider == "openai":
            self.endpoint = "https://api.openai.com/v1"
        elif provider == "inception":
            # Inception Labs (Mercury diffusion models). Native OpenAI-
            # compatible surface at /v1/chat/completions with Bearer auth.
            self.endpoint = "https://api.inceptionlabs.ai/v1"
        elif provider == "cerebras":
            # Cerebras Inference — serves open-weights models (Llama, Qwen,
            # GPT-OSS, GLM) at ~1000+ tokens/sec on wafer-scale chips.
            # OpenAI-compatible chat completions at /v1/chat/completions
            # with Bearer auth.
            self.endpoint = "https://api.cerebras.ai/v1"
        elif provider == "local":
            self.endpoint = "http://localhost:11434/v1"  # Ollama default
        else:
            # "custom" or unknown: assume local OpenAI-compatible
            self.endpoint = "http://localhost:11434/v1"

        # Resolve API key. Each provider has a canonical env var, checked
        # only when the caller didn't pass an explicit api_key.
        if api_key:
            self.api_key = api_key
        elif provider == "openrouter":
            self.api_key = os.environ.get("OPENROUTER_API_KEY", "")
        elif provider == "openai":
            self.api_key = os.environ.get("OPENAI_API_KEY", "")
        elif provider == "inception":
            self.api_key = os.environ.get("INCEPTION_API_KEY", "")
        elif provider == "cerebras":
            self.api_key = os.environ.get("CEREBRAS_API_KEY", "")
        else:
            self.api_key = os.environ.get("MODEL_API_KEY", "")

        # Token tracking
        self.total_prompt_tokens = 0
        self.total_completion_tokens = 0
        self.total_requests = 0

        # Lazily-resolved context window. First access hits the static
        # table, then OpenRouter's catalog. Cached here so we don't refetch.
        self._context_window: int | None = None

    def get_context_window(self) -> int:
        """Return the model's max context (in tokens)."""
        if self._context_window is None:
            self._context_window = lookup_context_window(self.model, self.provider)
        return self._context_window

    def _build_payload(self, messages: list[dict]) -> dict:
        """Assemble the JSON body. Handles reasoning-param injection so
        reasoning models run at maximum effort wherever supported.

        - OpenAI direct (openai): `reasoning_effort: "high"` on known
          reasoning models (gpt-5*, o*, gpt-oss*).
        - OpenRouter: their unified `reasoning: {effort: "high"}` spec,
          which is translated by OpenRouter to whatever the routed
          upstream expects (reasoning_effort for OpenAI, thinking.budget
          for Anthropic, thinkingConfig for Gemini, etc.).
        - Cerebras: `reasoning_effort: "high"` — matches OpenAI's shape;
          gpt-oss-120b / qwen-3-* honor it, other models ignore it.
        - Inception (Mercury): no param — diffusion models don't have
          a reasoning-effort knob.

        When reasoning is enabled we also bump `max_tokens` to
        REASONING_MAX_OUTPUT so the thinking budget fits without
        starving the final answer.
        """
        payload: dict = {
            "model": self.model,
            "messages": messages,
            "temperature": self.temperature,
            "max_tokens": self.max_tokens,
        }

        reasoning_on = supports_reasoning_effort(self.model, self.provider)

        if reasoning_on:
            # Give the model room for chain-of-thought + final answer.
            payload["max_tokens"] = max(self.max_tokens, REASONING_MAX_OUTPUT)

            if self.provider == "openrouter":
                # OpenRouter's unified spec. Applies to all routed
                # reasoning models regardless of upstream vendor.
                payload["reasoning"] = {"effort": "high"}
            else:
                # OpenAI, Cerebras, local, custom — native
                # reasoning_effort parameter as per OpenAI's API.
                payload["reasoning_effort"] = "high"

        return payload

    def chat(self, messages: list[dict]) -> tuple[str, dict]:
        """Send a chat completion request.

        Args:
            messages: List of {"role": "...", "content": "..."} dicts

        Returns:
            Tuple of (response_text, usage_dict)
        """
        url = f"{self.endpoint}/chat/completions"

        headers = {
            "Content-Type": "application/json",
        }
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"

        # OpenRouter specific headers
        if self.provider == "openrouter":
            headers["HTTP-Referer"] = "https://github.com/BalatroBench"
            headers["X-Title"] = "BalatroBench"

        payload = self._build_payload(messages)

        start_time = time.time()

        try:
            response = requests.post(url, json=payload, headers=headers, timeout=300)
            response.raise_for_status()
        except requests.exceptions.Timeout:
            return "", {"error": "Request timed out"}
        except requests.exceptions.ConnectionError:
            return "", {"error": f"Cannot connect to {url}"}
        except requests.exceptions.HTTPError as e:
            error_body = ""
            try:
                error_body = response.json().get("error", {}).get("message", str(e))
            except Exception:
                error_body = str(e)
            return "", {"error": f"HTTP {response.status_code}: {error_body}"}

        elapsed = time.time() - start_time

        data = response.json()

        # Extract response text and finish_reason (so callers can tell
        # whether the model ran out of tokens vs. finished naturally).
        text = ""
        finish_reason = None
        if "choices" in data and len(data["choices"]) > 0:
            choice = data["choices"][0]
            if "message" in choice and "content" in choice["message"]:
                text = choice["message"]["content"]
            finish_reason = choice.get("finish_reason") or choice.get("native_finish_reason")

        # Extract usage
        usage = data.get("usage", {})
        prompt_tokens = usage.get("prompt_tokens", 0)
        completion_tokens = usage.get("completion_tokens", 0)

        self.total_prompt_tokens += prompt_tokens
        self.total_completion_tokens += completion_tokens
        self.total_requests += 1

        usage_info = {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": prompt_tokens + completion_tokens,
            "elapsed_seconds": elapsed,
            "finish_reason": finish_reason,  # "stop", "length", etc.
        }

        return text, usage_info

    def chat_stream(self, messages: list[dict]) -> Iterator[tuple[str, object]]:
        """Streaming chat completion. Yields:
            ("delta", text_chunk)            # zero or more
            ("done",  {"text": full, "usage": {...}})   # exactly once on success
            ("error", {"error": "..."})      # instead of "done" on failure
        """
        url = f"{self.endpoint}/chat/completions"

        headers = {"Content-Type": "application/json", "Accept": "text/event-stream"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        if self.provider == "openrouter":
            headers["HTTP-Referer"] = "https://github.com/BalatroBench"
            headers["X-Title"] = "BalatroBench"

        payload = self._build_payload(messages)
        payload["stream"] = True

        start_time = time.time()
        full_parts: list[str] = []
        prompt_tokens = 0
        completion_tokens = 0
        finish_reason = None

        try:
            response = requests.post(
                url, json=payload, headers=headers,
                stream=True, timeout=(10, 300),
            )
            response.raise_for_status()

            for raw_line in response.iter_lines(decode_unicode=True):
                if not raw_line:
                    continue
                line = raw_line.strip()
                # OpenRouter keepalive comments start with ':'
                if line.startswith(":"):
                    continue
                if not line.startswith("data:"):
                    continue
                data_str = line[5:].strip()
                if data_str == "[DONE]":
                    break
                try:
                    chunk = json.loads(data_str)
                except json.JSONDecodeError:
                    continue

                choices = chunk.get("choices") or []
                if choices:
                    choice = choices[0]
                    delta = choice.get("delta") or {}
                    # Reasoning channel (R1-style) + content channel. Emit in
                    # arrival order; the overlay doesn't need to distinguish.
                    piece = ""
                    reasoning = delta.get("reasoning")
                    if isinstance(reasoning, str) and reasoning:
                        piece += reasoning
                    content = delta.get("content")
                    if isinstance(content, str) and content:
                        piece += content
                    if piece:
                        full_parts.append(piece)
                        yield ("delta", piece)
                    fr = choice.get("finish_reason") or choice.get("native_finish_reason")
                    if fr:
                        finish_reason = fr

                usage = chunk.get("usage")
                if isinstance(usage, dict):
                    prompt_tokens = usage.get("prompt_tokens", prompt_tokens) or prompt_tokens
                    completion_tokens = usage.get("completion_tokens", completion_tokens) or completion_tokens

        except requests.exceptions.Timeout:
            yield ("error", {"error": "Request timed out"})
            return
        except requests.exceptions.ConnectionError:
            yield ("error", {"error": f"Cannot connect to {url}"})
            return
        except requests.exceptions.HTTPError as e:
            body = ""
            try:
                body = response.json().get("error", {}).get("message", str(e))
            except Exception:
                body = str(e)
            yield ("error", {"error": f"HTTP {response.status_code}: {body}"})
            return
        except Exception as e:  # noqa: BLE001 — network/parsing is varied
            yield ("error", {"error": f"Stream failed: {e}"})
            return

        elapsed = time.time() - start_time
        full_text = "".join(full_parts)
        self.total_prompt_tokens += prompt_tokens
        self.total_completion_tokens += completion_tokens
        self.total_requests += 1

        yield ("done", {
            "text": full_text,
            "usage": {
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
                "total_tokens": prompt_tokens + completion_tokens,
                "elapsed_seconds": elapsed,
                "finish_reason": finish_reason,
            },
        })

    def get_total_usage(self) -> dict:
        """Get cumulative token usage."""
        return {
            "prompt_tokens": self.total_prompt_tokens,
            "completion_tokens": self.total_completion_tokens,
            "total_tokens": self.total_prompt_tokens + self.total_completion_tokens,
            "total_requests": self.total_requests,
        }


# ---------------------------------------------------------------------------
# Anthropic adapter
# ---------------------------------------------------------------------------
# Uses Anthropic's native Messages API (https://docs.anthropic.com/en/api/messages).
# Key wire differences vs. OpenAI-compatible:
#   - Endpoint: POST https://api.anthropic.com/v1/messages
#   - Auth: x-api-key: <key> (NOT Bearer)
#   - Required: anthropic-version header
#   - System prompt is a TOP-LEVEL field, not a role in messages[]
#   - Response shape: {content: [{type:"text", text:"..."}, ...], usage:
#     {input_tokens, output_tokens}, stop_reason}
#   - Streaming events: content_block_start / content_block_delta with
#     delta.text / content_block_stop / message_delta (carries usage +
#     stop_reason in final event) / message_stop
# This adapter exposes the exact same chat() / chat_stream() /
# get_context_window() / get_total_usage() interface as ModelAdapter, so
# the runner doesn't need to branch on provider.


class AnthropicAdapter:
    """Adapter for Anthropic's Claude models via the native Messages API."""

    API_BASE = "https://api.anthropic.com/v1"
    API_VERSION = "2023-06-01"

    def __init__(
        self,
        model: str,
        api_key: str | None = None,
        temperature: float = 0.3,
        max_tokens: int = 16384,
        endpoint: str | None = None,
    ):
        self.model = model
        self.provider = "anthropic"
        self.temperature = temperature
        self.max_tokens = max_tokens
        self.endpoint = (endpoint or self.API_BASE).rstrip("/")
        self.api_key = api_key or os.environ.get("ANTHROPIC_API_KEY", "")

        self.total_prompt_tokens = 0
        self.total_completion_tokens = 0
        self.total_requests = 0
        self._context_window: int | None = None

    def get_context_window(self) -> int:
        if self._context_window is None:
            self._context_window = lookup_context_window(self.model, self.provider)
        return self._context_window

    @staticmethod
    def _split_messages(messages: list[dict]) -> tuple[str, list[dict]]:
        """Extract the system prompt and remap to Anthropic's messages shape.

        Anthropic doesn't take a 'system' role inside messages — it wants
        a separate top-level `system` string. We concatenate all leading
        system turns and strip them from the messages list. Remaining
        messages keep their user/assistant roles; content strings stay
        as-is (string content is accepted alongside the richer block form).
        """
        system_parts: list[str] = []
        remaining: list[dict] = []
        for m in messages:
            role = m.get("role")
            if role == "system":
                c = m.get("content", "")
                if isinstance(c, str) and c:
                    system_parts.append(c)
            else:
                remaining.append({"role": role, "content": m.get("content", "")})
        # If the conversation starts with assistant (shouldn't happen here
        # but defensive), drop leading assistants — Anthropic rejects this.
        while remaining and remaining[0].get("role") == "assistant":
            remaining.pop(0)
        return "\n\n".join(system_parts), remaining

    def _headers(self, streaming: bool) -> dict:
        h = {
            "Content-Type": "application/json",
            "anthropic-version": self.API_VERSION,
        }
        if self.api_key:
            h["x-api-key"] = self.api_key
        if streaming:
            h["Accept"] = "text/event-stream"
        return h

    @staticmethod
    def _supports_extended_thinking(model: str) -> bool:
        """Sonnet 4.x and Haiku 4.x support opt-in extended thinking via
        the `thinking` param. Opus 4.7 uses "adaptive thinking" which is
        always on and NOT configured via this param (setting it errors).
        Legacy Claude 3.x models have no thinking at all.
        """
        if not model:
            return False
        m = model.lower()
        # Opus 4.7 is adaptive — don't send thinking param
        if "opus-4-7" in m or "opus-4.7" in m:
            return False
        # Everything Sonnet 4.x / Haiku 4.x / Opus 4.5/4.6 supports
        # extended thinking. Claude 3.x doesn't.
        if "claude-opus-4" in m or "claude-sonnet-4" in m or "claude-haiku-4" in m:
            return True
        if "claude-4" in m or "claude-5" in m:
            return True
        return False

    def _build_payload(self, messages: list[dict]) -> dict:
        """Assemble the Messages API payload with max-effort thinking
        enabled where supported. Anthropic rejects `thinking` + a
        non-1.0 temperature, so we bump temperature to 1.0 and raise
        max_tokens above the thinking budget when thinking is on.
        """
        system, anth_messages = self._split_messages(messages)
        payload: dict = {
            "model": self.model,
            "messages": anth_messages,
            "temperature": self.temperature,
            "max_tokens": self.max_tokens,
        }
        if system:
            payload["system"] = system

        if self._supports_extended_thinking(self.model):
            # Extended thinking: budget_tokens must be < max_tokens, and
            # temperature must be exactly 1.0 (Anthropic API constraint).
            # Bump max_tokens so we have headroom for both thinking and
            # the final answer.
            budget = REASONING_THINKING_BUDGET
            payload["thinking"] = {"type": "enabled", "budget_tokens": budget}
            payload["temperature"] = 1.0
            payload["max_tokens"] = max(self.max_tokens, budget + 16_384)

        return payload

    def chat(self, messages: list[dict]) -> tuple[str, dict]:
        url = f"{self.endpoint}/messages"
        payload = self._build_payload(messages)

        start_time = time.time()
        try:
            response = requests.post(url, json=payload, headers=self._headers(False), timeout=300)
            response.raise_for_status()
        except requests.exceptions.Timeout:
            return "", {"error": "Request timed out"}
        except requests.exceptions.ConnectionError:
            return "", {"error": f"Cannot connect to {url}"}
        except requests.exceptions.HTTPError as e:
            body = ""
            try:
                err = response.json().get("error") or {}
                body = err.get("message") or str(e)
            except Exception:
                body = str(e)
            return "", {"error": f"HTTP {response.status_code}: {body}"}

        elapsed = time.time() - start_time
        data = response.json()

        # Flatten content blocks. For reasoning models (Claude thinking)
        # the response may include thinking + text blocks interleaved;
        # we join them in order so downstream JSON parsing still sees the
        # final JSON at the end.
        text_parts: list[str] = []
        for block in data.get("content") or []:
            btype = block.get("type")
            if btype == "text" and isinstance(block.get("text"), str):
                text_parts.append(block["text"])
            elif btype == "thinking" and isinstance(block.get("thinking"), str):
                text_parts.append(block["thinking"])
        text = "".join(text_parts)

        usage = data.get("usage") or {}
        prompt_tokens = int(usage.get("input_tokens") or 0)
        completion_tokens = int(usage.get("output_tokens") or 0)
        self.total_prompt_tokens += prompt_tokens
        self.total_completion_tokens += completion_tokens
        self.total_requests += 1

        return text, {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": prompt_tokens + completion_tokens,
            "elapsed_seconds": elapsed,
            "finish_reason": data.get("stop_reason"),
        }

    def chat_stream(self, messages: list[dict]) -> Iterator[tuple[str, object]]:
        url = f"{self.endpoint}/messages"
        payload = self._build_payload(messages)
        payload["stream"] = True

        start_time = time.time()
        full_parts: list[str] = []
        prompt_tokens = 0
        completion_tokens = 0
        stop_reason = None

        try:
            response = requests.post(url, json=payload, headers=self._headers(True),
                                     stream=True, timeout=(10, 300))
            response.raise_for_status()

            for raw_line in response.iter_lines(decode_unicode=True):
                if not raw_line:
                    continue
                line = raw_line.strip()
                if not line.startswith("data:"):
                    continue
                data_str = line[5:].strip()
                if not data_str:
                    continue
                try:
                    evt = json.loads(data_str)
                except json.JSONDecodeError:
                    continue

                etype = evt.get("type")
                # Every piece of text the model emits arrives via
                # content_block_delta with delta.type == "text_delta".
                # Reasoning models also emit "thinking_delta" for thinking
                # blocks — we surface those so they show up in the run
                # dashboard like any other chain-of-thought.
                if etype == "content_block_delta":
                    delta = evt.get("delta") or {}
                    dtype = delta.get("type")
                    piece = ""
                    if dtype == "text_delta" and isinstance(delta.get("text"), str):
                        piece = delta["text"]
                    elif dtype == "thinking_delta" and isinstance(delta.get("thinking"), str):
                        piece = delta["thinking"]
                    if piece:
                        full_parts.append(piece)
                        yield ("delta", piece)
                elif etype == "message_start":
                    m = (evt.get("message") or {}).get("usage") or {}
                    prompt_tokens = int(m.get("input_tokens") or prompt_tokens)
                elif etype == "message_delta":
                    u = evt.get("usage") or {}
                    completion_tokens = int(u.get("output_tokens") or completion_tokens)
                    stop_reason = (evt.get("delta") or {}).get("stop_reason") or stop_reason
                elif etype == "message_stop":
                    break

        except requests.exceptions.Timeout:
            yield ("error", {"error": "Request timed out"}); return
        except requests.exceptions.ConnectionError:
            yield ("error", {"error": f"Cannot connect to {url}"}); return
        except requests.exceptions.HTTPError as e:
            body = ""
            try:
                body = (response.json().get("error") or {}).get("message") or str(e)
            except Exception:
                body = str(e)
            yield ("error", {"error": f"HTTP {response.status_code}: {body}"}); return
        except Exception as e:  # noqa: BLE001
            yield ("error", {"error": f"Stream failed: {e}"}); return

        elapsed = time.time() - start_time
        full_text = "".join(full_parts)
        self.total_prompt_tokens += prompt_tokens
        self.total_completion_tokens += completion_tokens
        self.total_requests += 1

        yield ("done", {
            "text": full_text,
            "usage": {
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
                "total_tokens": prompt_tokens + completion_tokens,
                "elapsed_seconds": elapsed,
                "finish_reason": stop_reason,
            },
        })

    def get_total_usage(self) -> dict:
        return {
            "prompt_tokens": self.total_prompt_tokens,
            "completion_tokens": self.total_completion_tokens,
            "total_tokens": self.total_prompt_tokens + self.total_completion_tokens,
            "total_requests": self.total_requests,
        }


# ---------------------------------------------------------------------------
# Gemini adapter
# ---------------------------------------------------------------------------
# Google's Generative Language API (AI Studio). Wire format:
#   - Endpoint: POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={KEY}
#   - Auth: API key goes in the URL `?key=` query param (ugly but
#           documented — we strip it from any error messages before
#           surfacing them to the UI to avoid leaking the key).
#   - Request: {contents: [{role: "user"|"model", parts: [{text}]}...],
#              systemInstruction: {parts: [{text}]},
#              generationConfig: {temperature, maxOutputTokens}}
#   - Response: {candidates: [{content: {parts: [{text}]}, finishReason}],
#               usageMetadata: {promptTokenCount, candidatesTokenCount, totalTokenCount}}
#   - Streaming: same URL with `:streamGenerateContent?alt=sse` — SSE lines
#               containing the same JSON structure (partial candidates).
# Role mapping: OpenAI "assistant" → Gemini "model". System is separate.


class GeminiAdapter:
    """Adapter for Google's Gemini models via the AI Studio API."""

    API_BASE = "https://generativelanguage.googleapis.com/v1beta"

    def __init__(
        self,
        model: str,
        api_key: str | None = None,
        temperature: float = 0.3,
        max_tokens: int = 16384,
        endpoint: str | None = None,
    ):
        self.model = model
        self.provider = "google"
        self.temperature = temperature
        self.max_tokens = max_tokens
        self.endpoint = (endpoint or self.API_BASE).rstrip("/")
        self.api_key = api_key or os.environ.get("GOOGLE_API_KEY") or os.environ.get("GEMINI_API_KEY", "")

        self.total_prompt_tokens = 0
        self.total_completion_tokens = 0
        self.total_requests = 0
        self._context_window: int | None = None

    def get_context_window(self) -> int:
        if self._context_window is None:
            self._context_window = lookup_context_window(self.model, self.provider)
        return self._context_window

    @staticmethod
    def _supports_thinking(model: str) -> bool:
        """Gemini 2.5 and 3.x families support `thinkingConfig`. Older
        1.5/2.0 models reject it with a 400 if we try to send. Return
        True only for confirmed-supporting families."""
        if not model:
            return False
        m = model.lower()
        return (
            m.startswith("gemini-2.5")
            or m.startswith("gemini-3")
            or m.startswith("models/gemini-2.5")
            or m.startswith("models/gemini-3")
        )

    def _build_payload(self, messages: list[dict]) -> dict:
        """Convert OpenAI-style messages → Gemini contents + systemInstruction,
        and crank thinking to max on 2.5/3.x where it's supported.

        `thinkingBudget: -1` is Gemini's "dynamic / unlimited thinking"
        signal: let the model burn as many thinking tokens as it deems
        necessary. This is the most-effort setting available. We also
        raise maxOutputTokens to REASONING_MAX_OUTPUT so the model isn't
        starved for final-answer tokens after a long think.
        """
        system_parts: list[str] = []
        contents: list[dict] = []
        for m in messages:
            role = m.get("role")
            c = m.get("content", "")
            if isinstance(c, list):
                # Flatten list-of-blocks content to plain text — Gemini
                # accepts that form natively but we keep things simple.
                c = "".join(b.get("text", "") for b in c if isinstance(b, dict))
            if role == "system":
                if isinstance(c, str) and c:
                    system_parts.append(c)
                continue
            g_role = "model" if role == "assistant" else "user"
            contents.append({"role": g_role, "parts": [{"text": str(c or "")}]})

        thinking_on = self._supports_thinking(self.model)
        max_out = max(self.max_tokens, REASONING_MAX_OUTPUT) if thinking_on else self.max_tokens

        generation_config: dict = {
            "temperature": self.temperature,
            "maxOutputTokens": max_out,
        }
        if thinking_on:
            # -1 = unlimited dynamic thinking. Includes chain-of-thought
            # in the streamed response when `includeThoughts` is set, but
            # we currently don't ingest the thinking channel separately —
            # the model's final text is what goes to the game.
            generation_config["thinkingConfig"] = {"thinkingBudget": -1}

        payload: dict = {
            "contents": contents,
            "generationConfig": generation_config,
        }
        if system_parts:
            payload["systemInstruction"] = {"parts": [{"text": "\n\n".join(system_parts)}]}
        return payload

    def _strip_key(self, s: str) -> str:
        """Scrub the API key from any error text before it reaches the UI.
        Gemini uses a URL-query key so error messages can echo it back."""
        if not self.api_key or not s:
            return s
        return s.replace(self.api_key, "<REDACTED>")

    def chat(self, messages: list[dict]) -> tuple[str, dict]:
        url = f"{self.endpoint}/models/{self.model}:generateContent?key={self.api_key}"
        payload = self._build_payload(messages)

        start_time = time.time()
        try:
            response = requests.post(url, json=payload,
                                     headers={"Content-Type": "application/json"},
                                     timeout=180)
            response.raise_for_status()
        except requests.exceptions.Timeout:
            return "", {"error": "Request timed out"}
        except requests.exceptions.ConnectionError:
            return "", {"error": "Cannot connect to generativelanguage.googleapis.com"}
        except requests.exceptions.HTTPError as e:
            body = ""
            try:
                body = (response.json().get("error") or {}).get("message") or str(e)
            except Exception:
                body = str(e)
            return "", {"error": self._strip_key(f"HTTP {response.status_code}: {body}")}

        elapsed = time.time() - start_time
        data = response.json()

        text = ""
        finish_reason = None
        cands = data.get("candidates") or []
        if cands:
            c0 = cands[0]
            finish_reason = c0.get("finishReason")
            parts = ((c0.get("content") or {}).get("parts") or [])
            text = "".join(p.get("text", "") for p in parts if isinstance(p, dict))

        usage = data.get("usageMetadata") or {}
        prompt_tokens = int(usage.get("promptTokenCount") or 0)
        completion_tokens = int(usage.get("candidatesTokenCount") or 0)
        self.total_prompt_tokens += prompt_tokens
        self.total_completion_tokens += completion_tokens
        self.total_requests += 1

        return text, {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": prompt_tokens + completion_tokens,
            "elapsed_seconds": elapsed,
            "finish_reason": finish_reason,
        }

    def chat_stream(self, messages: list[dict]) -> Iterator[tuple[str, object]]:
        url = f"{self.endpoint}/models/{self.model}:streamGenerateContent?alt=sse&key={self.api_key}"
        payload = self._build_payload(messages)

        start_time = time.time()
        full_parts: list[str] = []
        prompt_tokens = 0
        completion_tokens = 0
        finish_reason = None

        try:
            response = requests.post(url, json=payload,
                                     headers={"Content-Type": "application/json",
                                              "Accept": "text/event-stream"},
                                     stream=True, timeout=(10, 300))
            response.raise_for_status()

            for raw_line in response.iter_lines(decode_unicode=True):
                if not raw_line:
                    continue
                line = raw_line.strip()
                if not line.startswith("data:"):
                    continue
                data_str = line[5:].strip()
                if not data_str or data_str == "[DONE]":
                    continue
                try:
                    chunk = json.loads(data_str)
                except json.JSONDecodeError:
                    continue

                cands = chunk.get("candidates") or []
                if cands:
                    c0 = cands[0]
                    if c0.get("finishReason"):
                        finish_reason = c0["finishReason"]
                    parts = ((c0.get("content") or {}).get("parts") or [])
                    piece = "".join(p.get("text", "") for p in parts if isinstance(p, dict))
                    if piece:
                        full_parts.append(piece)
                        yield ("delta", piece)

                usage = chunk.get("usageMetadata")
                if isinstance(usage, dict):
                    prompt_tokens = int(usage.get("promptTokenCount") or prompt_tokens)
                    completion_tokens = int(usage.get("candidatesTokenCount") or completion_tokens)

        except requests.exceptions.Timeout:
            yield ("error", {"error": "Request timed out"}); return
        except requests.exceptions.ConnectionError:
            yield ("error", {"error": "Cannot connect to generativelanguage.googleapis.com"}); return
        except requests.exceptions.HTTPError as e:
            body = ""
            try:
                body = (response.json().get("error") or {}).get("message") or str(e)
            except Exception:
                body = str(e)
            yield ("error", {"error": self._strip_key(f"HTTP {response.status_code}: {body}")}); return
        except Exception as e:  # noqa: BLE001
            yield ("error", {"error": self._strip_key(f"Stream failed: {e}")}); return

        elapsed = time.time() - start_time
        full_text = "".join(full_parts)
        self.total_prompt_tokens += prompt_tokens
        self.total_completion_tokens += completion_tokens
        self.total_requests += 1

        yield ("done", {
            "text": full_text,
            "usage": {
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
                "total_tokens": prompt_tokens + completion_tokens,
                "elapsed_seconds": elapsed,
                "finish_reason": finish_reason,
            },
        })

    def get_total_usage(self) -> dict:
        return {
            "prompt_tokens": self.total_prompt_tokens,
            "completion_tokens": self.total_completion_tokens,
            "total_tokens": self.total_prompt_tokens + self.total_completion_tokens,
            "total_requests": self.total_requests,
        }


# ---------------------------------------------------------------------------
# OpenCode adapter
# ---------------------------------------------------------------------------
# Routes through a locally-spawned `opencode serve` process. The big win:
# the `opencode/*` gateway exposes free models (gpt-5-nano, minimax-m2.5-free,
# nemotron-3-super-free, qwen3.6-plus-free, big-pickle) with NO auth and
# `cost: 0`, billed against OpenCode's free-tier quota rather than a vendor
# API key. Useful for cheap baseline runs.
#
# Caveat: every request goes through OpenCode's coding-agent system prompt
# (~9.5k input tokens of overhead before our messages even arrive). The
# model still returns clean JSON when our user-message system prompt is
# emphatic enough — verified empirically — but the token overhead means
# we subtract ~10k from each model's nominal context window when reporting it.
#
# Wire shape (undocumented in `opencode serve`'s OpenAPI spec, discovered
# by probing):
#   POST /session                              → {id: "ses_..."}
#   POST /session/{id}/message  body:
#     {parts: [{type:"text", text:"..."}],
#      model: {providerID:"opencode", modelID:"<name>"},
#      agent?: "<name>"}                       → full message dict (synchronous)
# Response shape:
#   {info: {tokens: {input,output,reasoning,...}, cost, finish, ...},
#    parts: [{type:"step-start"}, {type:"reasoning", text:...},
#            {type:"text", text:...}, {type:"step-finish"}]}
#
# Server lifecycle: one `opencode serve` per process, spawned lazily on
# the first chat() call, cached on the class, killed via atexit.

import atexit
import shutil
import subprocess
import tempfile
import threading


PROVIDER_OPENCODE = "opencode"


class OpencodeAdapter:
    """Adapter that routes through a local `opencode serve` process to
    talk to OpenCode's free model gateway (opencode/*).

    Model IDs may be passed bare (`gpt-5-nano`) or namespaced
    (`opencode/gpt-5-nano`) — the namespace defaults to `opencode` so
    the existing free models Just Work. To talk to a different OpenCode-
    routed provider through the same server, pass `<providerID>/<modelID>`.
    """

    # Class-level so multiple adapter instances in one process share one
    # `opencode serve`. Locked to make the lazy-spawn race-safe — the
    # webapp runs benchmarks on a thread pool, so two adapters can race.
    _server_lock = threading.Lock()
    _server_proc: subprocess.Popen | None = None
    _server_url: str | None = None
    _server_workdir: str | None = None

    def __init__(
        self,
        model: str,
        api_key: str | None = None,  # ignored — opencode handles auth itself
        temperature: float = 0.3,
        max_tokens: int = 16384,
        endpoint: str | None = None,  # ignored — we manage the server URL
        agent: str | None = None,
    ):
        # Split "providerID/modelID" — fall back to provider="opencode"
        # for bare names so users can just write "gpt-5-nano".
        if "/" in model:
            self.provider_id, self.model_id = model.split("/", 1)
        else:
            self.provider_id, self.model_id = "opencode", model
        # Public `model` keeps the namespaced form so the runner / webapp
        # surfaces a recognizable string in logs and the leaderboard.
        self.model = f"{self.provider_id}/{self.model_id}"
        self.provider = PROVIDER_OPENCODE
        self.temperature = temperature  # opencode doesn't expose temperature
        self.max_tokens = max_tokens    # opencode controls output length itself
        self.agent = agent

        self.total_prompt_tokens = 0
        self.total_completion_tokens = 0
        self.total_requests = 0
        self._context_window: int | None = None

    # ---------- server lifecycle ----------

    @staticmethod
    def _pick_free_port() -> int:
        """Bind to port 0 to let the OS pick a free port, then close the
        socket and return the port. Tiny race window before opencode binds
        it but negligible in practice."""
        import socket as _socket
        s = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        return port

    @classmethod
    def _ensure_server(cls) -> str:
        """Spawn `opencode serve --port <chosen>` once per process and
        wait for /global/health to answer. We pick the port ourselves
        rather than parsing it from opencode's stdout — Windows + npm's
        bash/cmd shims make stdout pipes unreliable, but health-polling
        an HTTP port works the same on every platform."""
        with cls._server_lock:
            if cls._server_url and cls._server_proc and cls._server_proc.poll() is None:
                return cls._server_url

            # Reset stale handles if a previous process died
            cls._server_proc = None
            cls._server_url = None

            # On Windows, npm installs both a bash shim (no extension) and
            # a .cmd batch file. The bash shim doesn't propagate stdout/
            # exit cleanly through Popen, so prefer the .cmd.
            opencode = None
            if os.name == "nt":
                opencode = (shutil.which("opencode.cmd")
                            or shutil.which("opencode.exe")
                            or shutil.which("opencode"))
            else:
                opencode = shutil.which("opencode")
            if not opencode:
                raise RuntimeError(
                    "opencode CLI not found on PATH. Install from "
                    "https://opencode.ai or `npm i -g opencode-ai`."
                )

            # Blank cwd so opencode doesn't index the bench's source tree.
            cls._server_workdir = tempfile.mkdtemp(prefix="balatrobench-opencode-")
            port = cls._pick_free_port()

            # Detach stdio to DEVNULL so we never block on a full pipe
            # buffer — we don't read opencode's logs, we poll its HTTP
            # endpoint to know when it's ready.
            # CREATE_NEW_PROCESS_GROUP on Windows so Ctrl-C in the parent
            # doesn't propagate to opencode (we manage shutdown via atexit).
            popen_kwargs: dict = dict(
                cwd=cls._server_workdir,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL,
            )
            if os.name == "nt":
                popen_kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
                # .cmd / .bat batch files need cmd.exe to interpret them;
                # Popen with a list won't dispatch through cmd by default.
                # shell=True wraps the call appropriately on Windows.
                if opencode.lower().endswith((".cmd", ".bat")):
                    popen_kwargs["shell"] = True

            proc = subprocess.Popen(
                [opencode, "serve", "--port", str(port)],
                **popen_kwargs,
            )

            # Poll /global/health until opencode answers or we give up.
            url = f"http://127.0.0.1:{port}"
            deadline = time.time() + 45
            last_err: str | None = None
            while time.time() < deadline:
                if proc.poll() is not None:
                    raise RuntimeError(
                        f"opencode serve exited before becoming ready "
                        f"(exit code {proc.returncode}, port {port})"
                    )
                try:
                    r = requests.get(f"{url}/global/health", timeout=2)
                    if r.ok and r.json().get("healthy"):
                        cls._server_proc = proc
                        cls._server_url = url
                        atexit.register(cls._shutdown_server)
                        return url
                    last_err = f"health returned HTTP {r.status_code}"
                except requests.RequestException as e:
                    last_err = str(e)
                time.sleep(0.5)

            try:
                proc.kill()
            except Exception:  # noqa: BLE001
                pass
            raise RuntimeError(
                f"opencode serve on port {port} didn't become healthy "
                f"within 45s (last: {last_err})"
            )

    @classmethod
    def _shutdown_server(cls) -> None:
        with cls._server_lock:
            if cls._server_proc and cls._server_proc.poll() is None:
                try:
                    cls._server_proc.terminate()
                    try:
                        cls._server_proc.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        cls._server_proc.kill()
                except Exception:  # noqa: BLE001
                    pass
            cls._server_proc = None
            cls._server_url = None

    # ---------- public interface ----------

    def get_context_window(self) -> int:
        if self._context_window is None:
            # Look up by namespaced ID first, then bare model_id.
            ctx = STATIC_CONTEXT_WINDOWS.get(self.model)
            if ctx is None:
                ctx = STATIC_CONTEXT_WINDOWS.get(self.model_id, DEFAULT_CONTEXT_WINDOW)
            # Subtract opencode's baked-in system-prompt overhead so the
            # runner's context-management math doesn't blow past the real
            # limit. ~9.5k measured empirically; round up for safety.
            self._context_window = max(8000, ctx - 12_000)
        return self._context_window

    @staticmethod
    def _flatten_messages(messages: list[dict]) -> str:
        """Collapse a chat-completions message list into one user-message
        text block. We can't override opencode's session system prompt,
        and feeding multi-turn history through opencode's session model
        gets murky fast — so the bench-side approach is: fresh session
        per call, our entire conversation transcript dumped as ONE user
        message. The runner already passes full history each call.

        Roles are preserved as inline labels so the model still sees the
        turn structure (which matters for parsing stuff like "your last
        action was...")."""
        parts: list[str] = []
        for m in messages:
            role = (m.get("role") or "user").upper()
            content = m.get("content", "")
            if isinstance(content, list):
                # OpenAI block content; flatten to text
                content = "".join(
                    b.get("text", "") for b in content if isinstance(b, dict)
                )
            parts.append(f"[{role}]\n{content}")
        return "\n\n".join(parts)

    def _post_message(self, base_url: str, text: str) -> dict:
        sid_resp = requests.post(
            f"{base_url}/session",
            json={},
            headers={"Content-Type": "application/json"},
            timeout=30,
        )
        sid_resp.raise_for_status()
        sid = sid_resp.json()["id"]

        body: dict = {
            "parts": [{"type": "text", "text": text}],
            "model": {"providerID": self.provider_id, "modelID": self.model_id},
        }
        if self.agent:
            body["agent"] = self.agent

        msg_resp = requests.post(
            f"{base_url}/session/{sid}/message",
            json=body,
            headers={"Content-Type": "application/json"},
            timeout=600,  # local server, but the upstream model can be slow
        )
        msg_resp.raise_for_status()
        return msg_resp.json()

    @staticmethod
    def _extract_text(parts: list[dict]) -> tuple[str, str]:
        """Return (final_text, all_reasoning_concatenated)."""
        text_chunks: list[str] = []
        reasoning_chunks: list[str] = []
        for p in parts or []:
            ptype = p.get("type")
            if ptype == "text" and isinstance(p.get("text"), str):
                text_chunks.append(p["text"])
            elif ptype == "reasoning" and isinstance(p.get("text"), str):
                reasoning_chunks.append(p["text"])
        return "".join(text_chunks).strip(), "".join(reasoning_chunks)

    def chat(self, messages: list[dict]) -> tuple[str, dict]:
        try:
            base_url = self._ensure_server()
        except RuntimeError as e:
            return "", {"error": str(e)}

        text_payload = self._flatten_messages(messages)
        start_time = time.time()
        try:
            data = self._post_message(base_url, text_payload)
        except requests.exceptions.Timeout:
            return "", {"error": "Request timed out"}
        except requests.exceptions.ConnectionError:
            return "", {"error": f"Cannot connect to opencode server at {base_url}"}
        except requests.exceptions.HTTPError as e:
            body = ""
            try:
                err = e.response.json()
                body = err.get("error") if isinstance(err.get("error"), str) else json.dumps(err.get("error"))
            except Exception:  # noqa: BLE001
                body = str(e)
            status = e.response.status_code if e.response is not None else "?"
            return "", {"error": f"HTTP {status}: {body}"}

        elapsed = time.time() - start_time
        info = data.get("info") or {}
        tokens = info.get("tokens") or {}
        prompt_tokens = int(tokens.get("input") or 0)
        completion_tokens = int(tokens.get("output") or 0)
        # Reasoning tokens are tracked separately by opencode; roll them
        # into completion so the leaderboard's totals reflect actual
        # work the model did.
        completion_tokens += int(tokens.get("reasoning") or 0)

        text, _reasoning = self._extract_text(data.get("parts") or [])

        self.total_prompt_tokens += prompt_tokens
        self.total_completion_tokens += completion_tokens
        self.total_requests += 1

        return text, {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": prompt_tokens + completion_tokens,
            "elapsed_seconds": elapsed,
            "finish_reason": info.get("finish"),
        }

    def chat_stream(self, messages: list[dict]) -> Iterator[tuple[str, object]]:
        """Pseudo-stream: opencode's /message endpoint is synchronous JSON,
        not SSE. We do one blocking call, then surface reasoning + final
        text as deltas so the dashboard's live overlay still has something
        to show. Real streaming would require subscribing to the
        /session/{id}/event SSE channel — left as a TODO; the bench's main
        loop only needs a (text, usage) round-trip anyway."""
        try:
            base_url = self._ensure_server()
        except RuntimeError as e:
            yield ("error", {"error": str(e)}); return

        text_payload = self._flatten_messages(messages)
        start_time = time.time()
        try:
            data = self._post_message(base_url, text_payload)
        except requests.exceptions.Timeout:
            yield ("error", {"error": "Request timed out"}); return
        except requests.exceptions.ConnectionError:
            yield ("error", {"error": f"Cannot connect to opencode server at {base_url}"}); return
        except requests.exceptions.HTTPError as e:
            body = ""
            try:
                err = e.response.json()
                body = err.get("error") if isinstance(err.get("error"), str) else json.dumps(err.get("error"))
            except Exception:  # noqa: BLE001
                body = str(e)
            status = e.response.status_code if e.response is not None else "?"
            yield ("error", {"error": f"HTTP {status}: {body}"}); return

        elapsed = time.time() - start_time
        info = data.get("info") or {}
        tokens = info.get("tokens") or {}
        prompt_tokens = int(tokens.get("input") or 0)
        completion_tokens = int(tokens.get("output") or 0) + int(tokens.get("reasoning") or 0)

        text, reasoning = self._extract_text(data.get("parts") or [])

        # Surface reasoning first (matches the ordering Anthropic /
        # Gemini emit), then the final answer. The dashboard concatenates
        # deltas in arrival order.
        if reasoning:
            yield ("delta", reasoning)
        if text:
            yield ("delta", text)

        self.total_prompt_tokens += prompt_tokens
        self.total_completion_tokens += completion_tokens
        self.total_requests += 1

        yield ("done", {
            "text": text,
            "usage": {
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
                "total_tokens": prompt_tokens + completion_tokens,
                "elapsed_seconds": elapsed,
                "finish_reason": info.get("finish"),
            },
        })

    def get_total_usage(self) -> dict:
        return {
            "prompt_tokens": self.total_prompt_tokens,
            "completion_tokens": self.total_completion_tokens,
            "total_tokens": self.total_prompt_tokens + self.total_completion_tokens,
            "total_requests": self.total_requests,
        }


# ---------------------------------------------------------------------------
# Codex CLI adapter
# ---------------------------------------------------------------------------
# Drives OpenAI's `codex exec` CLI as a subprocess per turn. Auth comes
# from the user's existing `~/.codex/auth.json` (ChatGPT login), so this
# is billed against their ChatGPT Plus/Pro quota — no API key needed.
#
# Per-turn invocation:
#   codex exec --json --ephemeral --skip-git-repo-check
#              -s read-only
#              --output-last-message <answer.txt>
#              -m <model>
#              -c model_reasoning_effort="xhigh"
#              --cd <tempdir>
#              "<flattened messages>"
#
# We deliberately do NOT pass --output-schema. Codex routes through
# OpenAI's structured-outputs API in strict mode (additionalProperties
# must be false, every property must be required), and our experiments
# with a multi-field schema covering all 15 mod action verbs caused
# gpt-5.4 + xhigh to time out at 10+ minutes — apparently the model
# reasons heavily about which fields to null out for each turn. The
# runner already does its own JSON extraction at runner.py:64, so a
# prompt-side instruction to emit JSON is sufficient and matches how
# every other adapter behaves. If response quality turns out to be
# unreliable we can add a discriminated-union (oneOf) schema later.
#
# Streaming events come on stdout as JSONL; we tail them for usage data
# (`turn.completed` carries input_tokens / output_tokens / cached_input_tokens)
# and read --output-last-message for the actual answer text.

PROVIDER_CODEX = "codex"


class CodexAdapter:
    """Adapter that runs OpenAI's `codex exec` CLI per chat() call.
    Auth is whatever `codex login` set up — typically ChatGPT subscription
    backed, so there's no API key to manage.

    Model IDs are passed bare (`gpt-5.4`) or namespaced (`codex/gpt-5.4`).
    The namespace is stripped before being passed to codex via -m.
    """

    def __init__(
        self,
        model: str,
        api_key: str | None = None,           # ignored — codex manages auth
        temperature: float = 0.3,             # codex doesn't expose temperature
        max_tokens: int = 16384,              # codex manages output length itself
        endpoint: str | None = None,          # ignored
        reasoning_effort: str = "xhigh",
    ):
        # Strip "codex/" prefix if present so we hand codex the raw model ID
        if "/" in model:
            ns, mid = model.split("/", 1)
            self.model_id = mid if ns == "codex" else model
        else:
            self.model_id = model
        self.model = f"codex/{self.model_id}"
        self.provider = PROVIDER_CODEX
        self.temperature = temperature
        self.max_tokens = max_tokens
        self.reasoning_effort = reasoning_effort

        self.total_prompt_tokens = 0
        self.total_completion_tokens = 0
        self.total_requests = 0
        self._context_window: int | None = None

    # ---------- helpers ----------

    @staticmethod
    def _resolve_codex_bin() -> str:
        """Locate the codex CLI. Prefer .cmd on Windows because the bare
        bash shim doesn't propagate stdio cleanly through subprocess."""
        if os.name == "nt":
            for candidate in ("codex.cmd", "codex.exe", "codex"):
                p = shutil.which(candidate)
                if p:
                    return p
        else:
            p = shutil.which("codex")
            if p:
                return p
        raise RuntimeError(
            "codex CLI not found on PATH. Install from "
            "https://developers.openai.com/codex/cli or `npm i -g @openai/codex`."
        )

    @staticmethod
    def _flatten_messages(messages: list[dict]) -> str:
        """Collapse a chat-style message list into one prompt for `codex
        exec`. We do NOT use [SYSTEM]/[USER] role labels — Codex's
        gpt-5.x models interpret them as prompt-injection attempts and
        refuse to respond. Instead: concat system messages as inline
        instructions, then any user/assistant turns separated by markdown
        headers. The runner mostly sends one system + one user per call
        anyway."""
        system_parts: list[str] = []
        turns: list[str] = []
        for m in messages:
            role = (m.get("role") or "user").lower()
            content = m.get("content", "")
            if isinstance(content, list):
                content = "".join(
                    b.get("text", "") for b in content if isinstance(b, dict)
                )
            if not isinstance(content, str):
                content = str(content)
            if role == "system":
                system_parts.append(content)
            elif role == "assistant":
                # Past assistant turns become "previous reply" context
                turns.append(f"## Previous reply\n{content}")
            else:
                turns.append(content)
        out = ""
        if system_parts:
            out = "\n\n".join(system_parts)
        if turns:
            if out:
                out += "\n\n## Current turn\n" + "\n\n".join(turns)
            else:
                out = "\n\n".join(turns)
        return out

    @staticmethod
    def _parse_jsonl_usage(stdout_text: str) -> tuple[int, int, str | None]:
        """Walk codex's JSONL stream looking for `turn.completed` and any
        agent_message text. Returns (input_tokens, output_tokens, message_text)
        — message_text is a fallback if --output-last-message wasn't readable."""
        prompt_tokens = 0
        completion_tokens = 0
        message_text: str | None = None
        for line in stdout_text.splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                evt = json.loads(line)
            except json.JSONDecodeError:
                continue
            etype = evt.get("type")
            if etype == "turn.completed":
                usage = evt.get("usage") or {}
                prompt_tokens = int(usage.get("input_tokens") or 0)
                completion_tokens = int(usage.get("output_tokens") or 0)
            elif etype == "item.completed":
                item = evt.get("item") or {}
                if item.get("type") == "agent_message":
                    txt = item.get("text")
                    if isinstance(txt, str):
                        message_text = txt
        return prompt_tokens, completion_tokens, message_text

    # ---------- public interface ----------

    def get_context_window(self) -> int:
        if self._context_window is None:
            ctx = STATIC_CONTEXT_WINDOWS.get(self.model)
            if ctx is None:
                ctx = STATIC_CONTEXT_WINDOWS.get(self.model_id, DEFAULT_CONTEXT_WINDOW)
            # Codex wraps the prompt in its own coding-agent system prompt
            # (~10–15k tokens of preamble). Subtract a conservative pad so
            # the runner's context-management math doesn't overflow.
            self._context_window = max(8000, ctx - 16_000)
        return self._context_window

    def chat(self, messages: list[dict]) -> tuple[str, dict]:
        try:
            codex_bin = self._resolve_codex_bin()
        except RuntimeError as e:
            return "", {"error": str(e)}

        # Each call gets its own --output-last-message file and working
        # directory. Working dir is empty/temp so Codex's read-only sandbox
        # doesn't accidentally crawl the bench's source tree.
        workdir = tempfile.mkdtemp(prefix="balatrobench-codex-")
        out_fd, out_path = tempfile.mkstemp(
            prefix="balatrobench-codex-msg-", suffix=".txt", dir=workdir
        )
        os.close(out_fd)

        cmd = [
            codex_bin, "exec",
            "--json",
            "--ephemeral",
            "--skip-git-repo-check",
            "-s", "read-only",
            "--output-last-message", out_path,
            "-m", self.model_id,
            "-c", f'model_reasoning_effort="{self.reasoning_effort}"',
            "--cd", workdir,
            self._flatten_messages(messages),
        ]

        popen_kwargs: dict = dict(
            cwd=workdir,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        if os.name == "nt":
            popen_kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
            if codex_bin.lower().endswith((".cmd", ".bat")):
                popen_kwargs["shell"] = True

        start_time = time.time()
        try:
            proc = subprocess.Popen(cmd, **popen_kwargs)
        except OSError as e:
            return "", {"error": f"Failed to spawn codex: {e}"}

        # Generous timeout: gpt-5.4 at xhigh reasoning has been seen at
        # ~90s/turn in smoke tests; double it for headroom on harder turns.
        try:
            stdout, stderr = proc.communicate(timeout=600)
        except subprocess.TimeoutExpired:
            proc.kill()
            try:
                stdout, stderr = proc.communicate(timeout=10)
            except Exception:  # noqa: BLE001
                stdout, stderr = "", ""
            return "", {"error": "codex exec timed out after 600s"}

        elapsed = time.time() - start_time

        if proc.returncode != 0:
            # Surface BOTH streams — codex prints info to stderr and JSON
            # events to stdout, errors can land in either.
            combined = (stderr or "") + "\n---STDOUT---\n" + (stdout or "")
            tail = combined.strip().splitlines()[-15:]
            return "", {"error": f"codex exec exited {proc.returncode}: "
                                  + " | ".join(tail)}

        prompt_tokens, completion_tokens, fallback_text = self._parse_jsonl_usage(stdout)

        # Prefer the --output-last-message file (cleaner) but fall back to
        # the JSONL agent_message item if the file wasn't written for some
        # reason.
        text = ""
        try:
            with open(out_path, "r", encoding="utf-8") as f:
                text = f.read().strip()
        except OSError:
            text = (fallback_text or "").strip()

        # Best-effort cleanup of the per-call workdir.
        try:
            os.remove(out_path)
            os.rmdir(workdir)
        except OSError:
            pass

        self.total_prompt_tokens += prompt_tokens
        self.total_completion_tokens += completion_tokens
        self.total_requests += 1

        return text, {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": prompt_tokens + completion_tokens,
            "elapsed_seconds": elapsed,
            "finish_reason": "stop",  # codex doesn't surface a finish reason
        }

    def chat_stream(self, messages: list[dict]) -> Iterator[tuple[str, object]]:
        """Pseudo-stream — codex exec is synchronous from our side. We could
        tail the JSONL stream for `item.completed` reasoning blocks, but
        the bench loop only needs (text, usage) so we just yield the final
        answer as one delta. Real streaming would mean parsing assistant_
        message_started / delta events and re-shaping codex's protocol."""
        text, usage = self.chat(messages)
        if "error" in usage:
            yield ("error", usage)
            return
        if text:
            yield ("delta", text)
        yield ("done", {"text": text, "usage": usage})

    def get_total_usage(self) -> dict:
        return {
            "prompt_tokens": self.total_prompt_tokens,
            "completion_tokens": self.total_completion_tokens,
            "total_tokens": self.total_prompt_tokens + self.total_completion_tokens,
            "total_requests": self.total_requests,
        }


# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------
def make_adapter(provider: str, model: str, api_key: str | None = None,
                 endpoint: str | None = None,
                 temperature: float = 0.3, max_tokens: int = 16384):
    """Return the right adapter for `provider`. All adapters share the
    same duck-typed interface: chat(), chat_stream(), get_context_window(),
    get_total_usage(), and public attributes (model, provider, total_*)."""
    provider = (provider or "openrouter").lower()
    if provider == PROVIDER_ANTHROPIC:
        return AnthropicAdapter(model=model, api_key=api_key, endpoint=endpoint,
                                temperature=temperature, max_tokens=max_tokens)
    if provider == PROVIDER_GOOGLE:
        return GeminiAdapter(model=model, api_key=api_key, endpoint=endpoint,
                             temperature=temperature, max_tokens=max_tokens)
    if provider == PROVIDER_OPENCODE:
        return OpencodeAdapter(model=model, api_key=api_key, endpoint=endpoint,
                               temperature=temperature, max_tokens=max_tokens)
    if provider == PROVIDER_CODEX:
        return CodexAdapter(model=model, api_key=api_key, endpoint=endpoint,
                            temperature=temperature, max_tokens=max_tokens)
    # All remaining providers share the OpenAI-compatible chat-completions
    # shape. Unknown provider strings fall through to the generic adapter
    # too — if the endpoint speaks OpenAI, it'll work.
    return ModelAdapter(model=model, provider=provider, endpoint=endpoint,
                        api_key=api_key, temperature=temperature, max_tokens=max_tokens)
