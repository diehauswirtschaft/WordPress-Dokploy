"""Compare rendered pages of the live site with the migrated staging copy."""
import re
import sys
import urllib.request

LIVE = "https://nordstern.wien"
STAGE = "https://nordstern.dhw.wien"


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "nordstern-migration-check"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.status, r.read().decode("utf-8", "replace")


def summary(html):
    title = re.search(r"<title>(.*?)</title>", html, re.S)
    return {
        "title": title.group(1).strip() if title else None,
        "lang": (re.search(r'<html[^>]*lang="([^"]+)"', html) or [None, None])[1],
        "img": len(re.findall(r"<img\b", html)),
        "iframe": len(re.findall(r"<iframe\b", html)),
        "svg_refs": len(re.findall(r"\.svg\b", html)),
        "og_tags": len(re.findall(r'property="og:', html)),
        "words": len(re.sub(r"<[^>]+>", " ", re.sub(r"(?s)<(script|style).*?</\1>", "", html)).split()),
    }


def leftovers(html):
    return {
        "sites/6": html.count("sites/6"),
        "nordstern.wien": len(re.findall(r"(?<![.\w])nordstern\.wien", html)),
        "http://": len(re.findall(r'(?:src|href)="http://', html)),
    }


paths = [line.strip().replace(STAGE, "") for line in open(sys.argv[1]) if line.strip()]
problems = 0
for path in dict.fromkeys(["/"] + paths):
    _, live = fetch(LIVE + path)
    status, stage = fetch(STAGE + path)
    a, b = summary(live), summary(stage)
    left = leftovers(stage)
    # Matomo/OG differences in absolute counts are reported, word count allowed to drift slightly
    diffs = {k: (a[k], b[k]) for k in a if a[k] != b[k] and not (k == "words" and abs(a[k] - b[k]) <= 5)}
    bad_left = {k: v for k, v in left.items() if v}
    flag = "OK " if status == 200 and not diffs and not bad_left else "!! "
    problems += flag != "OK "
    print(f"{flag}{status} {path}  {b['title']!r}")
    if diffs:
        print(f"     differs (live, staging): {diffs}")
    if bad_left:
        print(f"     leftovers on staging: {bad_left}")
print(f"\n{problems} page(s) with differences")
