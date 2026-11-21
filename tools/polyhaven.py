#!/usr/bin/env python3
"""Downloads CC0 assets from Poly Haven into art_source/ (raw, git-ignored) and records them
in art_source/manifest.json + docs/ASSET_CREDITS.md.

Usage:
  tools/polyhaven.py texture <id> [res]      # diff, nor_gl, arm (or rough) maps as JPG
  tools/polyhaven.py model <id> [res]        # glTF + textures
"""
import json, os, sys, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "art_source")
UA = {"User-Agent": "wildbound-asset-pipeline/1.0"}


def get(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=120) as r:
        return r.read()


def save(url, path):
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    data = get(url)
    with open(path, "wb") as f:
        f.write(data)


def record(asset_id, kind, res):
    info = json.loads(get(f"https://api.polyhaven.com/info/{asset_id}"))
    mpath = os.path.join(SRC, "manifest.json")
    manifest = json.load(open(mpath)) if os.path.exists(mpath) else {}
    authors = ", ".join(info.get("authors", {}).keys())
    manifest[asset_id] = {"kind": kind, "res": res, "name": info.get("name", asset_id), "authors": authors,
                          "license": "CC0 1.0", "url": f"https://polyhaven.com/a/{asset_id}"}
    json.dump(manifest, open(mpath, "w"), indent=2, ensure_ascii=False)
    lines = ["# Third-party asset credits", "",
             "All listed assets are **CC0 1.0** (public domain) from Poly Haven — no attribution required,",
             "credited here voluntarily. Raw downloads live in `art_source/` (git-ignored); processed",
             "game-ready versions live in `assets/`.", "",
             "| Asset | Type | Authors | Source |", "|---|---|---|---|"]
    for k, v in sorted(manifest.items()):
        lines.append(f"| {v['name']} (`{k}`) | {v['kind']} {v['res']} | {v['authors']} | {v['url']} |")
    open(os.path.join(ROOT, "docs", "ASSET_CREDITS.md"), "w").write("\n".join(lines) + "\n")


def texture(asset_id, res="2k"):
    files = json.loads(get(f"https://api.polyhaven.com/files/{asset_id}"))
    out = os.path.join(SRC, "textures", asset_id)
    got = []
    for key, name in [("Diffuse", "diff"), ("nor_gl", "nor_gl"), ("arm", "arm"), ("Rough", "rough"), ("Displacement", "disp")]:
        entry = files.get(key, {}).get(res, {})
        fmt = entry.get("jpg") or entry.get("png")
        if fmt:
            ext = "jpg" if "jpg" in entry else "png"
            save(fmt["url"], os.path.join(out, f"{asset_id}_{name}_{res}.{ext}"))
            got.append(name)
    record(asset_id, "texture", res)
    print(asset_id, got)


def model(asset_id, res="1k"):
    files = json.loads(get(f"https://api.polyhaven.com/files/{asset_id}"))
    g = files["gltf"][res]["gltf"]
    out = os.path.join(SRC, "models", asset_id)
    save(g["url"], os.path.join(out, os.path.basename(g["url"])))
    for rel, e in g.get("include", {}).items():
        save(e["url"], os.path.join(out, rel))
    record(asset_id, "model", res)
    print(asset_id, "ok")


if __name__ == "__main__":
    kind, asset_id = sys.argv[1], sys.argv[2]
    res = sys.argv[3] if len(sys.argv) > 3 else ("2k" if kind == "texture" else "1k")
    {"texture": texture, "model": model}[kind](asset_id, res)
