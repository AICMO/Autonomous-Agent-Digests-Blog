#!/usr/bin/env python3
"""Substack publisher — reads LLM digest and publishes to Substack.

Usage:
  python substack.py --post              # Publish /tmp/llm_response.txt
  python substack.py --post --draft      # Create draft only (don't publish)

API vendored from python-substack (https://github.com/ma2za/python-substack).
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urljoin, unquote

import requests

LLM_RESPONSE_TMP = Path("/tmp/llm_response.txt")


# ============================================================
# Substack API client (minimal)
# ============================================================

class SubstackError(Exception):
    def __init__(self, status_code, text):
        try:
            json_res = json.loads(text)
            self.message = ", ".join(
                e.get("msg", "") for e in json_res.get("errors", [])
            ) or json_res.get("error", "")
        except ValueError:
            self.message = f"Invalid response: {text}"
        self.status_code = status_code

    def __str__(self):
        return f"SubstackError(code={self.status_code}): {self.message}"


class SubstackApi:
    """Minimal Substack API client — cookie auth, create draft, publish."""

    def __init__(self, cookies_string: str, publication_url: str):
        self.base_url = "https://substack.com/api/v1"
        self._session = requests.Session()
        self._session.headers.update({
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "en-US,en;q=0.9",
            "Accept-Encoding": "gzip, deflate",
            "Origin": "https://substack.com",
            "Referer": "https://substack.com/",
            "Sec-Fetch-Dest": "empty",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Site": "same-origin",
            "Sec-Ch-Ua": '"Google Chrome";v="131", "Chromium";v="131", "Not_A Brand";v="24"',
            "Sec-Ch-Ua-Mobile": "?0",
            "Sec-Ch-Ua-Platform": '"macOS"',
        })

        # Parse cookie string
        for pair in cookies_string.split(";"):
            pair = pair.strip()
            if "=" in pair:
                key, value = pair.split("=", 1)
                self._session.cookies.set(key.strip(), unquote(value.strip()))

        # Try native API first, fall back to subdomain API (avoids Cloudflare on substack.com)
        match = re.search(r"https://(.*).substack.com", publication_url.lower())
        subdomain = match.group(1) if match else None
        subdomain_base_url = f"{publication_url.rstrip('/')}/api/v1"

        try:
            profile = self._get(f"{self.base_url}/user/profile/self")
            print("Using native API (substack.com)")
        except SubstackError:
            print("Native API blocked, falling back to subdomain API")
            self.base_url = subdomain_base_url
            profile = self._get(f"{self.base_url}/user/profile/self")

        # Find matching publication
        publication = None
        for pub_user in profile.get("publicationUsers", []):
            pub = pub_user.get("publication")
            if pub and pub.get("subdomain") == subdomain:
                publication = pub
                break

        if not publication:
            # Fall back to primary
            publication = profile.get("primaryPublication")
            if not publication:
                for pub_user in profile.get("publicationUsers", []):
                    if pub_user.get("is_primary"):
                        publication = pub_user.get("publication")
                        break

        if not publication:
            raise SubstackError(0, '{"error": "Could not find publication"}')

        custom_domain = publication.get("custom_domain")
        if custom_domain and not publication.get("custom_domain_optional"):
            base = f"https://{custom_domain}"
        else:
            base = f"https://{publication['subdomain']}.substack.com"

        self.publication_api = urljoin(base, "api/v1")
        self.user_id = profile["id"]

    def _handle(self, response):
        if not (200 <= response.status_code < 300):
            raise SubstackError(response.status_code, response.text)
        return response.json()

    def _get(self, url, **kwargs):
        return self._handle(self._session.get(url, **kwargs))

    def _post(self, url, **kwargs):
        return self._handle(self._session.post(url, **kwargs))

    def create_draft(self, title, subtitle, paragraphs):
        """Create a draft post from a list of paragraph strings."""
        body_content = []
        for text in paragraphs:
            body_content.append({
                "type": "paragraph",
                "content": [{"type": "text", "text": text}],
            })

        draft_body = {
            "draft_title": title,
            "draft_subtitle": subtitle,
            "draft_body": json.dumps({"type": "doc", "content": body_content}),
            "draft_bylines": [{"id": self.user_id, "is_guest": False}],
            "audience": "everyone",
            "section_chosen": True,
        }
        return self._post(f"{self.publication_api}/drafts", json=draft_body)

    def publish(self, draft_id, send_email=False):
        """Prepublish checks then publish a draft."""
        self._get(f"{self.publication_api}/drafts/{draft_id}/prepublish")
        return self._post(
            f"{self.publication_api}/drafts/{draft_id}/publish",
            json={"send": send_email, "share_automatically": False},
        )


# ============================================================
# CLI
# ============================================================

def cmd_post(draft_only: bool = False):
    if not LLM_RESPONSE_TMP.exists():
        print(f"Error: {LLM_RESPONSE_TMP} not found. Run the LLM pipeline first.")
        sys.exit(1)

    digest_text = LLM_RESPONSE_TMP.read_text().strip()
    if not digest_text:
        print("LLM response is empty, nothing to publish.")
        return

    cookie = os.environ.get("SUBSTACK_COOKIE")
    pub_url = os.environ.get("SUBSTACK_PUBLICATION_URL", "").strip()

    if not cookie:
        print("Error: SUBSTACK_COOKIE environment variable not set")
        sys.exit(1)
    if not pub_url:
        print("Error: SUBSTACK_PUBLICATION_URL environment variable not set")
        sys.exit(1)

    print(f"Connecting to Substack ({pub_url})...")
    api = SubstackApi(
        cookies_string=f"connect.sid={cookie}",
        publication_url=pub_url,
    )
    print(f"Authenticated as user {api.user_id}")

    today = datetime.now(timezone.utc).strftime("%B %d, %Y")
    title = f"AI Digest — {today}"

    paragraphs = [line.strip() for line in digest_text.split("\n") if line.strip()]

    draft = api.create_draft(title=title, subtitle="", paragraphs=paragraphs)
    draft_id = draft.get("id")
    print(f"Draft created: id={draft_id}")

    if draft_only:
        print(f"Draft only: {pub_url}/publish/posts/drafts")
    else:
        result = api.publish(draft_id, send_email=False)
        slug = result.get("slug", draft_id)
        print(f"Published: {pub_url}/p/{slug}")

    print("Done.")


def main():
    parser = argparse.ArgumentParser(description="Substack Publisher")
    parser.add_argument("--post", action="store_true", help="Publish /tmp/llm_response.txt to Substack")
    parser.add_argument("--draft", action="store_true", help="Create draft only, don't publish")
    args = parser.parse_args()

    if not args.post:
        parser.print_help()
        sys.exit(1)

    cmd_post(draft_only=args.draft)


if __name__ == "__main__":
    main()