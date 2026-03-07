# Substack Integration

Vendored from [python-substack](https://github.com/ma2za/python-substack) (unofficial API).

## Authentication

Substack has no official public API. This uses their internal API with session cookie auth.

### Getting your `connect.sid` cookie

1. Open **substack.com** in your browser and sign in
2. Open DevTools:
   - **Chrome**: `Cmd+Option+I` → **Application** tab
   - **Firefox**: `Cmd+Option+I` → **Storage** tab
   - **Safari**: `Cmd+Option+I` → **Storage** tab
3. In the sidebar: **Cookies** → `https://substack.com`
4. Find the cookie named **`connect.sid`** — copy its **Value**
5. Set it as an environment variable:
   ```bash
   export SUBSTACK_COOKIE="s%3A..."
   ```

The cookie lasts ~3 months as long as you don't sign out of Substack.

### For GitHub Actions

Add `SUBSTACK_COOKIE` as a repository secret.

When the cookie expires, repeat steps 1-4 and update the secret.

## Environment Variables

| Variable | Description |
|----------|-------------|
| `SUBSTACK_COOKIE` | `connect.sid` cookie value from browser |
| `SUBSTACK_PUBLICATION_URL` | Publication URL (e.g. `https://howai.substack.com`) |

## Quick Test

```bash
export SUBSTACK_COOKIE="your_connect_sid_value"
export SUBSTACK_PUBLICATION_URL="https://howai.substack.com"
cd agent/integrations/substack
pip install requests
python test_post.py
```

This creates a **draft** (does not publish). Check your Substack dashboard to see it.