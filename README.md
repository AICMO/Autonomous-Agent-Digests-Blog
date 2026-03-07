# AI Content Curator & Publisher

Stateless pipeline: reads your Telegram channels, LLM curates a digest, publishes to Telegram and Substack.

## How it works

1. **Read** — Reads all subscribed broadcast channels → `/tmp/telegram_messages.json`
2. **Curate** — Two LLM calls generate platform-specific digests (short for Telegram, long-form for Substack)
3. **Publish** — Posts to Telegram channel and Substack newsletter

Runs daily at 6:00 UTC via GitHub Actions. No persistent state.

## Setup

### 1. Telegram credentials

1. Go to https://my.telegram.org → **API development tools**
2. Create a new application, copy `api_id` and `api_hash`
3. Generate a session string:

```bash
pip install telethon
export TELEGRAM_API_ID="your_api_id"
export TELEGRAM_API_HASH="your_api_hash"
export TELEGRAM_PHONE="+your_phone_number"
python agent/integrations/telegram/setup_session.py
```

4. Create a target channel: Menu → New Channel → make it Public → set a username

### 2. Substack credentials

See [agent/integrations/substack/README.md](agent/integrations/substack/README.md) for how to get your `connect.sid` cookie.

### 3. GitHub secrets & variables

**Secrets:**

| Secret | Description |
|--------|-------------|
| `TELEGRAM_API_ID` | Numeric API ID from my.telegram.org |
| `TELEGRAM_API_HASH` | API hash string from my.telegram.org |
| `TELEGRAM_SESSION_STRING` | Output from `setup_session.py` |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code OAuth token (primary LLM auth) |
| `ANTHROPIC_API_KEY` | Claude API key (fallback LLM auth) |
| `SUBSTACK_COOKIE` | Substack `connect.sid` cookie value |

**Variables:**

| Variable | Description |
|----------|-------------|
| `TELEGRAM_PUBLISH_CHANNEL` | Target Telegram channel (e.g. `@my_ai_digest`) |
| `SUBSTACK_PUBLICATION_URL` | Substack publication URL (e.g. `https://howai.substack.com`) |
| `LLM_PROVIDER` | LLM provider: `claude`, `openai`, `gemini`, `vertex` (default: `claude`) |
| `LLM_MODEL` | Model name (default: `claude-sonnet-4-6`) |
| `LLM_MAX_TOKENS` | Max tokens (default: `12288`) |

### 4. Run

Runs automatically daily at 6:00 UTC. Manual: Actions → "Generate Digest" → Run workflow.

## Project structure

```
agent/integrations/
  telegram/
    telegram.py              # Telegram I/O (--read, --post, --list-channels)
    setup_session.py         # one-time auth → StringSession
    requirements.txt         # telethon, cryptg
  substack/
    substack.py              # Substack publisher (--post, --draft)
    api.py                   # Substack API client (vendored)
    post.py                  # Post builder (vendored)
    exceptions.py            # API exceptions
    requirements.txt         # requests
    README.md                # Substack auth setup guide
.github/
  prompts/
    curate-digest-telegram.md  # Telegram digest prompt (short, emoji, links)
    curate-digest-substack.md  # Substack digest prompt (long-form newsletter)
  workflows/
    generate-digest.yml        # daily pipeline
```