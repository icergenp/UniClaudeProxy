# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

UniClaudeProxy is a FastAPI service that exposes an Anthropic-compatible `POST /v1/messages` endpoint and routes requests to different upstream LLM providers:

- OpenAI-compatible APIs (`/chat/completions` or `/responses`)
- Gemini native API (`generateContent` / `streamGenerateContent`)
- Anthropic-compatible passthrough APIs

The main use case is running Claude Code against `http://127.0.0.1:9223` while the proxy translates requests/responses to a non-Anthropic backend.

## Common commands

### Setup

```bash
cp config.example.json config.json
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### Run the proxy

```bash
python -m uvicorn app.main:app --host 127.0.0.1 --port 9223
```

Project-provided launchers:

```bash
./Run.sh
```

```bash
Run.bat
```

For local development with Python code auto-reload, run:

```bash
python app/main.py
```

### Health / manual verification

```bash
curl http://127.0.0.1:9223/
curl http://127.0.0.1:9223/health
```

Quick Anthropic-format smoke test (replace `model` with one mapped in your local `config.json`):

```bash
curl http://127.0.0.1:9223/v1/messages \
  -H 'content-type: application/json' \
  -d '{
    "model": "claude-sonnet-4-5",
    "max_tokens": 64,
    "messages": [{"role": "user", "content": "ping"}]
  }'
```

### Run Claude Code through the proxy

```bash
ANTHROPIC_BASE_URL=http://127.0.0.1:9223 claude
```

### Logs

```bash
tail -f debug.log
```

### Tests / linting

There is currently no checked-in test suite and no repo-level lint/type-check config (`pytest`, `ruff`, `mypy`, `flake8`, etc. were not found). Do not assume standard test or lint commands already exist.

## High-level architecture

### 1. Entry point and request dispatch

`app/main.py` is the orchestration layer.

It is responsible for:

- creating the FastAPI app
- enforcing `local_only` access with middleware
- loading `config.json` and starting the hot-reload watcher
- handling `POST /v1/messages`
- applying `system_replacements` before provider conversion
- choosing one of the execution paths below:
  - Anthropic passthrough
  - native OpenAI/Gemini conversion
  - ReAct XML fallback for models with `use_react: true`
- handling both streaming and non-streaming responses
- reconstructing non-streaming Anthropic responses from forced upstream SSE when `force_stream` is enabled

### 2. Config-driven routing

`app/config.py` defines the config model and route resolution.

Important structure in `config.json`:

- `server`
  - bind host/port
  - `local_only` gate
- `models`
  - maps Anthropic-facing model names to `provider_name/model_id`
- `providers`
  - provider connection info and per-model behavior flags

The route resolver returns a `ResolvedRoute` that carries behavior flags used everywhere else, including:

- `responses`
- `use_react`
- `inject_context`
- `force_stream`
- `upstream_system`
- `tool_mapping`
- `reasoning`
- `truncation`
- `text`
- `max_output_tokens`
- `parallel_tool_calls`
- `strip_tool_choice`
- `image_mode`
- `image_dir`
- `system_replacements`

`app/watcher.py` hot-reloads `config.json` only. Python code changes still require a process restart unless you run `python app/main.py`.

### 3. Anthropic-first internal model

`app/models.py` defines the internal Pydantic representation of Anthropic request/response objects:

- text/image/thinking/tool blocks
- messages
- tool definitions
- usage and response envelopes

Most of the application converts between this Anthropic-shaped model and provider-specific formats.

### 4. Provider boundary

`app/providers/` contains thin HTTP clients:

- `openai_provider.py`
- `gemini_provider.py`
- `anthropic_provider.py`

Keep transport concerns here:

- shared `httpx.AsyncClient`
- endpoint URL construction
- headers
- raw streaming/non-streaming HTTP calls

Keep protocol translation in `app/converters/`, not in `app/providers/`.

### 5. Conversion layer

The conversion modules are the real core of the project.

Anthropic → provider:

- `app/converters/anthropic_to_openai.py`
  - builds Chat Completions or Responses API payloads
  - maps Anthropic tool schemas to OpenAI function schemas
  - converts Anthropic image blocks for OpenAI-compatible backends
  - maps tool IDs between Anthropic `toolu_*` and Responses `fc_*`
- `app/converters/anthropic_to_gemini.py`
  - builds Gemini `contents`, `tools`, and `generationConfig`
  - strips/normalizes JSON Schema fields for Gemini function declarations
  - converts Anthropic tool history into Gemini `functionCall` / `functionResponse`

Provider → Anthropic:

- `app/converters/openai_to_anthropic.py`
  - converts Chat Completions and Responses API payloads back to Anthropic format
  - converts streaming SSE into Anthropic `message_start` / `content_block_delta` / `message_delta` events
  - handles thinking blocks and tool call output
  - supports `tool_mapping` for upstream tool event names such as shell-call style outputs
- `app/converters/gemini_to_anthropic.py`
  - converts Gemini responses and SSE to Anthropic blocks
  - preserves Gemini `thought` content as Anthropic `thinking`
  - stores Gemini `thoughtSignature` inside tool IDs for round-tripping
  - auto-fixes camelCase vs snake_case tool argument mismatches using the original Anthropic tool schema

### 6. ReAct fallback path

The `app/react/` package exists for models that do not support native function calling.

- `prompt.py`
  - injects an XML tool-calling instruction block into the system prompt
- `transform.py`
  - rewrites outgoing Anthropic tool history into XML/observation text
  - adds the `</tool_call>` stop sequence
  - parses returned XML tool calls back into Anthropic `tool_use` blocks
  - handles streaming parsing so plain text can flow until a `<tool_call>` sequence appears
- `parser.py`
  - lower-level XML parsing helpers

When debugging tool-use problems on local / weaker models, check whether the model is running through this ReAct path instead of native function calling.

### 7. Image handling

`app/utils/images.py` centralizes image support.

Current modes:

- `input_image`
- `save_and_ref`
- `strip`

This mainly affects OpenAI Responses-style requests and any provider/model config that needs image downgrading or local persistence.

## Important repo-specific behaviors

- `config.json` is local-only and gitignored; the tracked config shape lives in `config.example.json`.
- The server defaults to `127.0.0.1:9223` with `local_only: true`, so non-local traffic is rejected unless config changes.
- `start.sh` is environment-specific: it also checks `http://127.0.0.1:8789` and may try to launch `~/code/wesee/ai-scripts/cproxy.sh`. Do not assume this script is portable across machines.
- `debug.log` is truncated on startup by `app/main.py`; if you need old logs, save them before restarting.
- `system_prompt_cn_optimized.md` exists in the repo root but is not referenced by the current runtime code paths.

## Where to look first when changing behavior

- Routing/model selection problems:
  - `app/config.py`
  - `config.example.json`
  - local `config.json`
- Request/response shape bugs:
  - `app/converters/anthropic_to_openai.py`
  - `app/converters/openai_to_anthropic.py`
  - `app/converters/anthropic_to_gemini.py`
  - `app/converters/gemini_to_anthropic.py`
- Tool-calling regressions on non-native models:
  - `app/react/transform.py`
  - `app/react/prompt.py`
- Hot reload / config reload issues:
  - `app/watcher.py`
  - startup logic in `app/main.py`
- Upstream HTTP failures:
  - `app/providers/*.py`
  - `debug.log`
