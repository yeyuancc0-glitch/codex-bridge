# DeepSeek Harness Setup Guide

## Profile and `.env`

Codex Bridge registers the DeepSeek Harness executable and an external `cordis.yml`. It does not read, store, or summarize API keys. Place `.env` beside the registered `cordis.yml`; Bridge launches Harness from that directory and Harness loads the file itself.

Start from the repository example:

```bash
cp Examples/DeepSeekHarnessProfile/.env.example /path/to/profile/.env
```

Edit the resulting `.env` locally. Never commit or share it.

## Models and Web Search use separate endpoints

```env
DEEPSEEK_API_KEY=
DEEPSEEK_BASE_URL=https://api.deepseek.com
DEEPSEEK_SEARCH_BASE_URL=https://api.deepseek.com/anthropic/v1
```

- `DEEPSEEK_BASE_URL` is the DeepSeek-compatible chat-completions base for the main model.
- `DEEPSEEK_SEARCH_BASE_URL` is the independent Anthropic-compatible Web Search base. DSH appends `/messages`; do not include `/messages` in the variable.
- The current Bridge profile uses `DEEPSEEK_API_KEY` for both the main model and the search plugin. When the endpoints belong to different services, verify that the same credential is valid for both. Otherwise Web Search can fail authentication while the main model continues to work.

Supporting `/messages` does not imply Web Search support. The endpoint must also accept the native `web_search_20250305` server tool in Anthropic Messages requests. Check the gateway documentation; successful authentication alone does not prove tool support.

## Common failures

### `Authentication Fails ... api key ... is invalid`

DSH resolved a credential and reached the search endpoint, but the remote service rejected that credential. Check:

1. `DEEPSEEK_SEARCH_BASE_URL` points to the intended search service instead of falling back to the official DeepSeek endpoint;
2. `DEEPSEEK_API_KEY` is valid for that search endpoint;
3. the endpoint accepts `POST <baseURL>/messages`.

### No `web_search_tool_result`

Authentication and the Messages request may have succeeded, but the endpoint did not execute native Web Search. Confirm explicit `web_search_20250305` support rather than inferring it from an Anthropic-compatible label.

Changing the external `cordis.yml`, Harness executable, or lock file triggers a Codex Bridge installation identity review. Updating the unregistered local `.env` does not alter the frozen installation artifacts.
