# AI Content Curator & Publisher

Stateless pipeline: reads your Telegram channels, LLM curates a digest, publishes to Telegram, Ghost, and Substack.

## How it works

1. **Collect** — Reads all subscribed broadcast channels → `/tmp/telegram_messages.json`
2. **Curate** — Two parallel LLM calls generate platform-specific digests:
   - Messenger digest (short, emoji, links) for Telegram
   - Blog digest (long-form HTML) for Ghost and Substack
3. **Publish** — Posts to all platforms in parallel:
   - **Ghost** (main blog) — Lexical format, newsletter emails via Mailgun
   - **Telegram** — plain text to channel
   - **Substack** (secondary) — ProseMirror format

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

### 2. Ghost setup

1. Deploy Ghost using `infra/ghost/deploy-ghost.sh` (Docker Compose on any Linux server)
2. Create an admin account at `https://your-domain/ghost`
3. Settings → Integrations → Add custom integration → copy the Admin API key
4. (Optional) Settings → Mailgun → configure for newsletter emails

### 3. Substack credentials

See [agent/integrations/substack/README.md](agent/integrations/substack/README.md) for how to get your `connect.sid` cookie.

### 4. GitHub secrets & variables

**Secrets:**

| Secret | Description |
|--------|-------------|
| `TELEGRAM_API_ID` | Numeric API ID from my.telegram.org |
| `TELEGRAM_API_HASH` | API hash string from my.telegram.org |
| `TELEGRAM_SESSION_STRING` | Output from `setup_session.py` |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code OAuth token (primary LLM auth) |
| `ANTHROPIC_API_KEY` | Claude API key (fallback LLM auth) |
| `GHOST_ADMIN_API_KEY` | Ghost Admin API key (format: `{id}:{secret}`) |
| `SUBSTACK_COOKIE` | Substack `connect.sid` cookie value |

**Variables:**

| Variable | Description |
|----------|-------------|
| `TELEGRAM_PUBLISH_CHANNEL` | Target Telegram channel (e.g. `@my_ai_digest`) |
| `GHOST_URL` | Ghost domain without https:// (e.g. `aicmo.blog`) |
| `SUBSTACK_PUBLICATION_URL` | Substack publication URL (e.g. `https://howai.substack.com`) |
| `LLM_PROVIDER` | LLM provider: `claude`, `openai`, `gemini`, `vertex` (default: `claude`) |
| `LLM_MODEL` | Model name (default: `claude-sonnet-4-6`) |
| `LLM_MAX_TOKENS` | Max tokens (default: `12288`) |

### 5. Run

Runs automatically daily at 6:00 UTC. Manual: Actions → "Generate Digest" → Run workflow.

Supports workflow dispatch inputs: `since_hours`, `start_date`, `end_date`, and per-platform publish toggles.

### 6. Backfill

To backfill past digests one day at a time:

```bash
.github/scripts/backfill-digests.sh 2026-02-08 2026-03-09
```

## Project structure

```
agent/integrations/
  telegram/
    telegram.py              # Telegram I/O (--read, --post, --list-channels)
    setup_session.py         # one-time auth → StringSession
    requirements.txt         # telethon, cryptg
  ghost/
    ghost.py                 # Ghost publisher (--post, --draft, HTML→Lexical)
    requirements.txt         # requests
  substack/
    substack.py              # Substack publisher (--post, --draft, HTML→ProseMirror)
    requirements.txt         # requests
    README.md                # Substack auth setup guide
infra/
  ghost/
    deploy-ghost.sh          # deploy Ghost (Docker Compose)
    docker-compose.yml       # Caddy + Ghost + MySQL
  ubuntu_security_hardening.sh  # server hardening (SSH, UFW, fail2ban, sysctl)
.github/
  scripts/
    backfill-digests.sh           # backfill past digests sequentially
  prompts/
    generate-digest-messenger.md  # Telegram digest prompt (short, emoji, links)
    generate-digest-blog.md       # Blog digest prompt (long-form HTML)
  workflows/
    generate-digest.yml           # daily pipeline
    test-ghost.yml                # manual Ghost test
    test-substack.yml             # manual Substack test
```
