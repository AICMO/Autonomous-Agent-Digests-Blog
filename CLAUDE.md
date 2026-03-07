# AI Content Curator & Publisher

## Project Overview
Stateless pipeline: read Telegram channels → LLM curates digest → publish to Telegram + Substack.

## Architecture
- `agent/integrations/telegram/telegram.py` — Telegram I/O (read channels, publish digest)
- `agent/integrations/substack/substack.py` — Substack publisher
- `agent/integrations/substack/api.py` — Substack API client (vendored from python-substack)
- `.github/prompts/curate-digest-telegram.md` — Telegram prompt (short, emoji, links)
- `.github/prompts/curate-digest-substack.md` — Substack prompt (long-form newsletter)
- `.github/workflows/generate-digest.yml` — CI pipeline (daily cron)

## Pipeline
```
1. Read      telegram.py --read --since 24   → /tmp/telegram_messages.json
2. LLM       AICMO/llm-call-action@v1        → /tmp/llm_response.txt (twice: telegram then substack)
3. Publish   telegram.py --post              → Telegram channel
4. Publish   substack.py --post              → Substack newsletter
```

## LLM Auth
- Primary: `CLAUDE_CODE_OAUTH_TOKEN` via claude-code-action
- Fallback: `ANTHROPIC_API_KEY` (or any provider) via API
- Provider/model configurable via `LLM_PROVIDER`, `LLM_MODEL` repo variables

## Environment Variables
- `TELEGRAM_API_ID` — from my.telegram.org
- `TELEGRAM_API_HASH` — from my.telegram.org
- `TELEGRAM_SESSION_STRING` — from setup_session.py
- `TELEGRAM_PUBLISH_CHANNEL` — target channel (e.g. `@my_channel`)
- `CLAUDE_CODE_OAUTH_TOKEN` — Claude Code OAuth token (primary)
- `ANTHROPIC_API_KEY` — Claude API key (fallback)
- `SUBSTACK_COOKIE` — connect.sid cookie from browser (see substack/README.md)
- `SUBSTACK_PUBLICATION_URL` — e.g. `https://howai.substack.com`

## Agent Guidelines
- Fix content quality issues in `.github/prompts/`, not in scripts
- Pipeline is stateless — no persistent state, everything flows through /tmp/
- Respect Telegram rate limits — delays are built into telegram.py
- Substack uses an unofficial API — if it breaks, check python-substack upstream