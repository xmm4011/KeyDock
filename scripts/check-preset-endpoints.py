"""Anonymous reachability checks of exported public preset references.

No credentials, cookies or real model calls. An HTTP response is not an account
verification. Run: KeyDockChecks --preset-reference-json > references.json
          python3 scripts/check-preset-endpoints.py references.json results.json
"""
import concurrent.futures
import datetime
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def check(job):
    method, url = job
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or parsed.username or parsed.password or parsed.query:
        raise ValueError("Only credential-free HTTPS preset URLs are accepted")
    request = urllib.request.Request(url, method=method, data=b"{}" if method == "POST" else None,
                                     headers={"Accept": "application/json, text/html", "User-Agent": "KeyDock-Preset-Check/1.0"})
    if method == "POST":
        request.add_header("Content-Type", "application/json")
    result = {"method": method, "url": url, "authenticated": False, "model_called": False}
    try:
        try:
            response = urllib.request.build_opener(NoRedirect).open(request, timeout=15)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            target = urllib.parse.urlsplit(urllib.parse.urljoin(url, response.headers.get("Location", "")))
            redirect = urllib.parse.urlunsplit((target.scheme, target.netloc, target.path, "", "")) if response.headers.get("Location") else ""
            result.update(status=response.code, content_type=response.headers.get("Content-Type", ""),
                          redirect=redirect)
            # Do not store returned cookies or page bodies.
            response.read(512)
    except Exception as error:
        result["error"] = type(error).__name__ + ": " + str(error)[:180]
    return result


def main():
    references = json.loads(Path(sys.argv[1]).read_text())
    jobs = set()
    for preset in references:
        for url in preset["documentation"]:
            jobs.add(("GET", url))
        for field in ("models", "balance"):
            if preset[field]["url"]:
                jobs.add(("GET", preset[field]["url"]))
        for protocol in preset["protocols"]:
            suffix = {"compatible": "chat/completions", "anthropic": "messages", "responses": "responses"}.get(protocol["kind"])
            if suffix:
                base = protocol["base_url"]
                if not urllib.parse.urlsplit(base).path.strip("/") and "api.deepseek.com" not in base:
                    base += "/v1"
                jobs.add(("POST", base.rstrip("/") + "/" + suffix))
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(check, sorted(jobs)))
    report = {"checked_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "scope": "Anonymous route/document reachability only; no real account or inference verification", "results": results}
    Path(sys.argv[2]).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    for result in results:
        print(result["method"], result.get("status", result.get("error")), result["url"], flush=True)
    print("CHECKED", len(results), "public URLs; no keys or real model calls")


if __name__ == "__main__":
    main()
