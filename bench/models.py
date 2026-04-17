"""Model API adapters for OpenRouter and local models."""

import json
import os
import time
from collections.abc import Iterator

import requests


class ModelAdapter:
    """Sends prompts to an AI model and gets responses."""

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
        elif provider == "local":
            self.endpoint = "http://localhost:11434/v1"  # Ollama default
        else:
            self.endpoint = "http://localhost:11434/v1"

        # Resolve API key
        if api_key:
            self.api_key = api_key
        elif provider == "openrouter":
            self.api_key = os.environ.get("OPENROUTER_API_KEY", "")
        else:
            self.api_key = os.environ.get("MODEL_API_KEY", "")

        # Token tracking
        self.total_prompt_tokens = 0
        self.total_completion_tokens = 0
        self.total_requests = 0

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

        payload = {
            "model": self.model,
            "messages": messages,
            "temperature": self.temperature,
            "max_tokens": self.max_tokens,
        }

        start_time = time.time()

        try:
            response = requests.post(url, json=payload, headers=headers, timeout=120)
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

        payload = {
            "model": self.model,
            "messages": messages,
            "temperature": self.temperature,
            "max_tokens": self.max_tokens,
            "stream": True,
        }

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
