"""Pull the latest DAOS Magazine blog posts from the Shopify Atom feed and
inject them into facebook-index.html between the BLOG-FEED markers.
Run before build-facebook.py. Keeps the site's existing look: same card
styles, same red buttons, no redesign.
"""
import html
import re
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

BASE = Path(__file__).parent
NS = {"a": "http://www.w3.org/2005/Atom"}


def clean(text, limit=200):
    text = re.sub(r"<[^>]+>", "", text or "")
    text = html.unescape(text).strip()
    return text[:limit] + ("…" if len(text) > limit else "")


def main():
    req = urllib.request.Request(
        "https://deadlyartofsurvival.com/blogs/news.atom",
        headers={"User-Agent": "daosmedia-build/1.0"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        root = ET.fromstring(resp.read())
    cards = []
    for entry in root.findall("a:entry", NS)[:5]:
        title = entry.findtext("a:title", "", NS) or ""
        link = ""
        for l in entry.findall("a:link", NS):
            if l.get("rel") in (None, "alternate"):
                link = l.get("href", "")
        published = (entry.findtext("a:published", "", NS) or "")[:10]
        summary = entry.findtext("a:summary", "", NS) or ""
        cards.append(
            f'<p><strong><a href="{html.escape(link)}">{html.escape(title)}</a></strong>'
            f'<br><span class="meta">{html.escape(published)}</span>'
            f'<br>{html.escape(clean(summary))}</p>'
        )
    tpl = (BASE / "facebook-index.html").read_text()
    pattern = re.compile(r"<!-- BLOG-FEED-START -->.*?<!-- BLOG-FEED-END -->", re.S)
    new = "<!-- BLOG-FEED-START -->" + "\n".join(cards) + "<!-- BLOG-FEED-END -->"
    tpl, n = pattern.subn(new, tpl)
    if n != 1:
        raise SystemExit("BLOG-FEED markers not found exactly once")
    (BASE / "facebook-index.html").write_text(tpl)
    print(f"injected {len(cards)} blog posts")


if __name__ == "__main__":
    main()
