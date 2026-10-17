#!/usr/bin/env python3
"""Checks run by test/test_web.sh against a running results website.

  web_checks.py <base_url> <user> <password>

Standard library only. Exits non-zero if any check fails.
"""
import base64
import json
import sys
import urllib.error
import urllib.request

base, user, password = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3]
AUTH = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()
results = []


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


opener = urllib.request.build_opener(NoRedirect)


def get(path, auth=True, accept="application/json"):
    req = urllib.request.Request(base + path, headers={"Accept": accept})
    if auth:
        req.add_header("Authorization", AUTH)
    try:
        with opener.open(req, timeout=60) as r:
            return r.status, r.headers, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS  " if cond else "FAIL  ") + name + (f"  ({detail})" if detail and not cond else ""))


def js(body):
    return json.loads(body.decode())


# ── Health and authentication ────────────────────────────────────────────────
st, _, body = get("/healthz", auth=False)
check("healthz answers without login", st == 200 and js(body).get("ok"), st)
st, _, _ = get("/api/summary", auth=False)
check("API refuses requests without login", st == 401, st)
st, hdr, _ = get("/", auth=False, accept="text/html")
check("browser without login is sent to /login", st in (301, 302, 303) and "/login" in (hdr.get("Location") or ""), st)
req = urllib.request.Request(base + "/api/summary", headers={"Authorization": "Basic " + base64.b64encode(b"admin:wrong").decode()})
try:
    urllib.request.urlopen(req, timeout=30); wrong = 200
except urllib.error.HTTPError as e:
    wrong = e.code
check("wrong password is refused", wrong == 401, wrong)

# ── Pages and static assets ──────────────────────────────────────────────────
for page in ["/", "/sample.html", "/gene-search.html", "/umap.html", "/stats.html", "/app.css", "/common.js", "/contact.js", "/vendor/plotly.min.js"]:
    st, _, body = get(page, accept="text/html")
    check(f"GET {page}", st == 200 and len(body) > 100, st)

# ── Summary ──────────────────────────────────────────────────────────────────
st, _, body = get("/api/summary")
summary = js(body) if st == 200 else {}
samples = summary.get("samples", [])
check("summary lists centers and samples", st == 200 and summary.get("centers") and samples, f"{st}, {len(samples)} samples")
classified = [s for s in samples if s.get("status") == "classified"]
check("at least one classified sample", classified, "no *.mdall.json found under the results root")
check("reference subtype list supplied (19 MD-ALL subtypes)", len(summary.get("subtypes", [])) == 19, len(summary.get("subtypes", [])))
print(f"      {len(summary.get('centers', []))} centers, {len(samples)} samples, {len(classified)} classified")

# ── Reference data ───────────────────────────────────────────────────────────
st, _, body = get("/api/reference/umap")
ref = js(body) if st == 200 else {}
check("reference UMAP has 1,821 samples", len(ref.get("samples", [])) == 1821, len(ref.get("samples", [])))
st, _, body = get("/api/genes?q=CRLF")
check("gene autocomplete finds CRLF2", st == 200 and any(g.get("name") == "CRLF2" for g in js(body)))

# ── Per-sample endpoints ─────────────────────────────────────────────────────
if classified:
    s = classified[0]
    c, n = s["center"], s["sample"]
    print(f"      using sample {c}/{n}")
    st, _, body = get(f"/api/sample/{c}/{n}")
    d = js(body) if st == 200 else {}
    md = d.get("mdall") or {}
    check("sample detail has the MD-ALL result", st == 200 and md.get("call") and md.get("predictions"), st)
    check("sample detail has PhenoGraph and SVM calls",
          md.get("call", {}).get("phenograph", {}).get("call") and md.get("call", {}).get("svm", {}).get("call"))
    check("sample has 22 per-feature-set predictions", len(md.get("predictions", [])) == 22, len(md.get("predictions", [])))
    check("sample was projected onto the UMAP", (md.get("umap") or {}).get("x") is not None)

    st, _, body = get(f"/api/gene/{c}/{n}/CRLF2")
    g = js(body) if st == 200 else {}
    n_ref = sum(len(v) for v in g.get("reference", {}).values())
    check("gene search CRLF2 returns sample + 1,821 reference values",
          st == 200 and isinstance(g.get("sample_value"), (int, float)) and n_ref == 1821, f"{st}, {n_ref}")
    st, _, _ = get(f"/api/gene/{c}/{n}/ENSG00000205755")
    check("gene search accepts Ensembl ids", st == 200, st)
    st, _, _ = get(f"/api/gene/{c}/{n}/NOT_A_GENE_XYZ")
    check("unknown gene gives 404", st == 404, st)

    files = d.get("files", {})
    if files.get("mdall"):
        f = files["mdall"][0]
        st, _, body = get(f"/files/{c}/{n}/mdall/{f}")
        check(f"download {f}", st == 200 and len(body) > 0, st)

    # Path traversal and unknown ids must never reach the file system.
    for bad in [f"/files/{c}/{n}/mdall/..%2F..%2F..%2Fetc%2Fpasswd",
                f"/files/{c}/{n}/mdall/%2E%2E%2Fcounts%2F{n}.counts_qc.json",
                f"/files/{c}/{n}/bam/{n}.bam",
                f"/files/{c}/{n}/mdall/other.txt",
                f"/api/sample/{c}/..%2F..",
                "/api/sample/..%2Fetc/passwd"]:
        st, _, body = get(bad)
        check(f"refused: {bad}", st in (400, 404) and b"root:" not in body, st)

st, hdr, body = get("/api/export.tsv")
lines = body.decode(errors="replace").strip().split("\n") if st == 200 else []
check("TSV export has a header and one row per sample", st == 200 and len(lines) == len(samples) + 1, f"{st}, {len(lines)} lines")
st, _, _ = get("/api/sample/NOPE/NOPE")
check("unknown sample gives 404", st == 404, st)

failed = results.count(False)
print(f"\n{len(results) - failed}/{len(results)} checks passed")
sys.exit(1 if failed else 0)
