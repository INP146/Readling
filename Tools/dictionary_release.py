#!/usr/bin/env python3
"""Prepare, build, check and adopt dictionary pack releases (see docs/dictionary-design.md).

  prepare VERSION [--source-commit SHA]  bump the release, rebuild the bundled core, draft release notes
                                         (with RELEASE_AI_PROVIDER in .env, a local codex/claude writes the draft)
  check [TAG] [--require-notes]          release.json, the bundled core, notes and manifest agree
  build [--verify-core]                  fetch the pinned ECDICT, build and package every pack (CI runs this)
  adopt VERSION                          point Dictionaries/manifest.json at a published release

Never commits, tags or pushes. Standard library only; runs on macOS Python 3.9.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
import shutil
import sqlite3
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "INP146/Readling"
RELEASE = Path("Dictionaries/release.json")
MANIFEST = Path("Dictionaries/manifest.json")
CORE = Path("Readling/Resources/dictionary-core.sqlite")
BUILD = Path("build/dict")
SOURCE_CSV = Path("build/ecdict/ecdict.csv")
NOTES = Path("docs/releases")
VERSION_RE = re.compile(r"\d{4}\.\d{2}\.\d{2}(?:\.[1-9]\d*)?")
HEX40, HEX64 = re.compile(r"[0-9a-f]{40}"), re.compile(r"[0-9a-f]{64}")
TODO = "RELEASE_TODO"
# Fixed timestamps and permissions, so packaging the same pack twice gives the same bytes.
ZIP_TIME = (1980, 1, 1, 0, 0, 0)

_spec = importlib.util.spec_from_file_location("build_dictionary", ROOT / "Tools" / "build-dictionary.py")
builder = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(builder)
sys.path.insert(0, str(ROOT / "Tools"))
import release_ai  # noqa: E402


def normalize_version(value: str) -> str:
    version = value[len("dict-"):] if value.startswith("dict-") else value
    if VERSION_RE.fullmatch(version) is None:
        raise ValueError("版本格式必须是 2026.11.18 或 2026.11.18.1（可带 dict- 前缀）")
    return version


def version_key(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split("."))


def tag(version: str) -> str:
    return f"dict-{version}"


def notes_path(root: Path, version: str) -> Path:
    return root / NOTES / f"{tag(version)}.md"


def source_url(commit: str) -> str:
    return f"https://raw.githubusercontent.com/skywind3000/ECDICT/{commit}/ecdict.csv"


def release_url(version: str, name: str) -> str:
    return f"https://github.com/{REPOSITORY}/releases/download/{tag(version)}/{name}"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_release(root: Path) -> dict:
    return json.loads((root / RELEASE).read_text(encoding="utf-8"))


def pack_meta(path: Path) -> dict[str, str]:
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        return dict(db.execute("SELECT key, value FROM meta"))
    finally:
        db.close()


def content_digest(path: Path) -> str:
    """A hash of a pack's rows, independent of the SQLite version that wrote the file."""
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    digest = hashlib.sha256()
    try:
        tables = {name for (name,) in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        for table, key in (("meta", "key"), ("entry", "key"), ("form", "form")):
            if table not in tables:
                continue
            digest.update(f"[{table}]\n".encode())
            for row in db.execute(f"SELECT * FROM {table} ORDER BY {key}"):
                digest.update(json.dumps(row, ensure_ascii=False).encode() + b"\n")
    finally:
        db.close()
    return digest.hexdigest()


def fetch_source(root: Path, source: dict) -> Path:
    """The pinned ecdict.csv, downloaded once into build/ and checked against its sha256."""
    path = root / SOURCE_CSV
    if path.is_file() and sha256_file(path) == source["sha256"]:
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_suffix(".partial")
    with urllib.request.urlopen(source["url"], timeout=300) as response, open(partial, "wb") as f:
        shutil.copyfileobj(response, f)
    if sha256_file(partial) != source["sha256"]:
        partial.unlink()
        raise ValueError(f"下载的 ecdict.csv 与 {RELEASE} 中的 sha256 不符")
    partial.replace(path)
    return path


def build_packs(csv_path: Path, out: Path, version: str, commit: str) -> dict[str, int]:
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    return builder.build(str(csv_path), str(out), set(builder.PACKS), version, commit)


def package(out: Path, version: str) -> dict:
    """Zips every pack, the core included (apps update their bundled core from it), then writes
    manifest.json and SHA256SUMS next to them."""
    packs = []
    for path in sorted(out.glob("dictionary-*.sqlite")):
        meta = pack_meta(path)
        archive = out / f"dictionary-{meta['id']}.zip"
        info = zipfile.ZipInfo(path.name, date_time=ZIP_TIME)
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr(info, path.read_bytes(), compresslevel=9)
        packs.append({
            "id": meta["id"], "title": meta["title"], "group": meta["group"], "order": int(meta["order"]),
            "schema": int(meta["schema"]), "version": meta["version"], "entries": int(meta["entries"]),
            "size": archive.stat().st_size, "installedSize": path.stat().st_size,
            "sha256": sha256_file(archive), "url": release_url(version, archive.name)})
    packs.sort(key=lambda pack: (pack["order"], pack["id"]))
    manifest = {"format": 1, "release": version, "packs": packs}
    (out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    sums = [f"{pack['sha256']}  dictionary-{pack['id']}.zip" for pack in packs]
    sums.append(f"{sha256_file(out / 'manifest.json')}  manifest.json")
    (out / "SHA256SUMS").write_text("\n".join(sums) + "\n", encoding="utf-8")
    return manifest


def check(root: Path, version: str | None = None, *, require_notes: bool = False) -> str:
    """Rejects an inconsistent release before anything is built or published. Returns the release version."""
    errors = []
    release = load_release(root)
    current = release.get("version", "")
    if VERSION_RE.fullmatch(current) is None:
        errors.append(f"{RELEASE} 的 version 格式不正确")
    source = release.get("source", {})
    commit = source.get("commit", "")
    if HEX40.fullmatch(commit) is None or source.get("url") != source_url(commit) or HEX64.fullmatch(source.get("sha256", "")) is None:
        errors.append(f"{RELEASE} 的 source 应包含 ECDICT 完整提交号、对应 url 和 sha256")
    if version is not None and normalize_version(version) != current:
        errors.append(f"tag 版本 {version} 与 {RELEASE} 的 {current} 不一致")

    core = root / CORE
    meta = pack_meta(core) if core.is_file() else {}
    if meta.get("schema") != str(builder.SCHEMA) or meta.get("id") != "core":
        errors.append(f"{CORE} 不是 schema {builder.SCHEMA} 的核心词典")
    elif meta.get("version") != current or meta.get("sourceCommit") != commit:
        errors.append(f"{CORE} 来自 {meta.get('version')}，应重新生成为 {current}（prepare 会更新它）")

    if require_notes:
        path = notes_path(root, current)
        if not path.is_file():
            errors.append(f"缺少发布说明 {path.relative_to(root)}")
        else:
            notes = path.read_text(encoding="utf-8")
            if not notes.startswith(f"# 词典包 {tag(current)} 发布说明\n"):
                errors.append("发布说明标题与版本号不一致")
            if TODO in notes:
                errors.append(f"请完成 {path.relative_to(root)} 中的 {TODO} 内容")
            changes = re.search(r"(?m)^## 主要变更[ \t]*\n([\s\S]*?)(?=^## |\Z)", notes)
            if not changes or not changes[1].strip():
                errors.append("发布说明缺少或未填写 ## 主要变更")

    if (root / MANIFEST).is_file():
        manifest = json.loads((root / MANIFEST).read_text(encoding="utf-8"))
        adopted = manifest.get("release", "")
        if manifest.get("format") != 1 or VERSION_RE.fullmatch(adopted) is None:
            errors.append(f"{MANIFEST} 格式不正确")
        elif VERSION_RE.fullmatch(current) and version_key(adopted) > version_key(current):
            errors.append(f"{MANIFEST} 指向 {adopted}，比 {RELEASE} 的 {current} 还新")
        for pack in manifest.get("packs", []):
            name = f"dictionary-{pack.get('id')}.zip"
            if pack.get("id") not in builder.PACKS or pack.get("schema") != builder.SCHEMA \
                    or pack.get("version") != adopted or pack.get("url") != release_url(adopted, name) \
                    or HEX64.fullmatch(pack.get("sha256", "")) is None:
                errors.append(f"{MANIFEST} 中的 {pack.get('id')} 与 {tag(adopted)} 不符")
    if errors:
        raise ValueError("\n".join(errors))
    return current


def previous_counts(root: Path) -> dict[str, int]:
    """Entry counts of the release in use: the bundled core and the adopted manifest."""
    counts = {}
    if (root / CORE).is_file():
        counts["core"] = int(pack_meta(root / CORE).get("entries", 0))
    if (root / MANIFEST).is_file():
        for pack in json.loads((root / MANIFEST).read_text(encoding="utf-8")).get("packs", []):
            counts[pack["id"]] = pack["entries"]
    return counts


def draft_notes(version: str, previous: str | None, counts: dict[str, int], source: dict,
                before: dict[str, int] | None = None, *, ai_review: bool = False) -> str:
    base = f"相对 {tag(previous)}" if previous else "首次发布"
    before = before or {}

    def change(pack):
        if pack not in before:
            return "新增" if previous else "—"
        delta = counts[pack] - before[pack]
        return f"{delta:+,}" if delta else "0"

    rows = "\n".join(
        f"| {title}{'（内置于 app，也可下载更新）' if pack == 'core' else ''} | {group} | {counts[pack]:,} | {change(pack)} |"
        for pack, (title, group, _) in sorted(builder.PACKS.items(), key=lambda item: item[1][2]))
    review = ""
    if ai_review:
        review = (f"\n{TODO}：以下草稿由本地 AI CLI 根据 {base.replace('相对 ', '')} 以来的改动生成，"
                  "请核对主要变更后删除此行及其他待确认标记。\n")
    return f"""# 词典包 {tag(version)} 发布说明
{review}
## 主要变更

{TODO}：填写{base}的主要变更（收录规则、数据源、新增或调整的包），删除此占位行。

## 词典包

| 包 | 分组 | 条目 | 变化 |
|---|---|---|---|
{rows}

数据来源：ECDICT [`{source['commit'][:7]}`](https://github.com/skywind3000/ECDICT/commit/{source['commit']})，
`ecdict.csv` sha256 `{source['sha256']}`。

## 上线

推送 tag 后，Actions 从上面固定的数据源重新构建全部词典包，核对其中的核心词典与 app 内置的一致，
再创建 Release，附上各词典包（含核心词典）、manifest.json 和 SHA256SUMS。Release 不会成为仓库的 Latest Release。

发布成功后运行 `python3 Tools/dictionary_release.py adopt {version}`，提交并推送
`Dictionaries/manifest.json`，app 的“设置 › 词典”才会提示更新到这一版。
"""


def prepare(root: Path, version: str, *, source_commit: str | None = None, dry_run: bool = False,
            base_tag: str | None = None) -> list[Path]:
    version = normalize_version(version)
    release = load_release(root) if (root / RELEASE).is_file() else None
    previous = release["version"] if release else None
    if previous and version_key(version) <= version_key(previous):
        raise ValueError(f"新版本必须高于当前版本 {previous}")
    notes = notes_path(root, version)
    if notes.exists():
        raise ValueError(f"{notes.relative_to(root)} 已存在；为保留已有说明，未修改任何文件")
    if source_commit is None and release is None:
        raise ValueError("首次准备需要用 --source-commit 指定 ECDICT 的提交号")
    if source_commit is not None and HEX40.fullmatch(source_commit) is None:
        raise ValueError("--source-commit 必须是 40 位的完整提交号")
    paths = [root / RELEASE, root / CORE, notes]
    config = release_ai.load_config(root)
    if config.provider != "none":
        # Before any download or build, so a missing tag fails fast.
        release_ai.validate_base_tag(root, previous, base_tag)
    else:
        print("提示：当前 RELEASE_AI_PROVIDER=none（未配置 .env 或显式设为 none），仅生成静态模板")
    if dry_run:
        if config.provider != "none":
            model_note = f" ({config.model})" if config.model else ""
            print(f"将调用 {config.provider}{model_note} 生成发布说明草稿（dry-run 不调用模型）")
        return paths

    if source_commit is None:
        source = release["source"]
    else:
        source = {"name": "ECDICT", "commit": source_commit, "url": source_url(source_commit), "sha256": ""}
        csv_path = root / SOURCE_CSV
        csv_path.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(source["url"], timeout=300) as response, open(csv_path, "wb") as f:
            shutil.copyfileobj(response, f)
        source["sha256"] = sha256_file(csv_path)
    csv_path = fetch_source(root, source)
    out = root / BUILD
    counts = build_packs(csv_path, out, version, source["commit"])
    package(out, version)

    # Everything built. The notes come first: if the agent fails, the release files stay as they were.
    template = draft_notes(version, previous, counts, source, previous_counts(root), ai_review=config.provider != "none")
    if config.provider == "none":
        notes.parent.mkdir(parents=True, exist_ok=True)
        notes.write_text(template, encoding="utf-8")
    else:
        release_ai.generate(root, version, previous, config, template=template, target=notes.relative_to(root),
                            base_tag=base_tag)
    shutil.copyfile(out / "dictionary-core.sqlite", root / CORE)
    (root / RELEASE).parent.mkdir(parents=True, exist_ok=True)
    (root / RELEASE).write_text(json.dumps({"version": version, "source": source}, indent=2) + "\n", encoding="utf-8")
    check(root)
    return paths


def build(root: Path, *, verify_core: bool = False) -> dict:
    release = load_release(root)
    out = root / BUILD
    build_packs(fetch_source(root, release["source"]), out, release["version"], release["source"]["commit"])
    if verify_core and content_digest(out / "dictionary-core.sqlite") != content_digest(root / CORE):
        raise ValueError(f"构建出的核心词典与 {CORE} 不一致：请用 prepare 重新生成并提交")
    return package(out, release["version"])


def download(url: str, *, first_byte_only: bool = False) -> bytes:
    request = urllib.request.Request(url, headers={"Range": "bytes=0-0"} if first_byte_only else {})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def adopt(root: Path, version: str) -> Path:
    """Copies a published release's manifest into the repository once every asset it lists is reachable."""
    version = normalize_version(version)
    manifest = download(release_url(version, "manifest.json"))
    sums = dict(reversed(line.split(None, 1)) for line in download(release_url(version, "SHA256SUMS")).decode().splitlines() if line)
    if sums.get("manifest.json") != hashlib.sha256(manifest).hexdigest():
        raise ValueError("manifest.json 与 Release 中的 SHA256SUMS 不符")
    data = json.loads(manifest)
    if data.get("release") != version:
        raise ValueError(f"Release 中的 manifest.json 属于 {data.get('release')}")
    for pack in data["packs"]:
        if sums.get(f"dictionary-{pack['id']}.zip") != pack["sha256"]:
            raise ValueError(f"{pack['id']} 的 sha256 与 SHA256SUMS 不符")
        download(pack["url"], first_byte_only=True)
    (root / MANIFEST).parent.mkdir(parents=True, exist_ok=True)
    (root / MANIFEST).write_bytes(manifest)
    check(root)
    return root / MANIFEST


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare", help="升级版本、重建内置核心词典并生成发布说明草稿")
    prepare_parser.add_argument("version")
    prepare_parser.add_argument("--source-commit", help="改用 ECDICT 的另一个提交（40 位）")
    prepare_parser.add_argument("--dry-run", action="store_true", help="只显示将修改的文件，不构建、不调用模型")
    prepare_parser.add_argument("--base-tag", help="AI 草稿的比较基准；默认是上一个词典版本的 tag")
    check_parser = commands.add_parser("check", help="校验版本一致性，可传入待发布 tag")
    check_parser.add_argument("version", nargs="?")
    check_parser.add_argument("--require-notes", action="store_true", help="要求发布说明已完成")
    build_parser = commands.add_parser("build", help="构建并打包全部词典包到 build/dict")
    build_parser.add_argument("--verify-core", action="store_true", help="要求构建出的核心词典与 app 内置的一致")
    adopt_parser = commands.add_parser("adopt", help="让 Dictionaries/manifest.json 指向已发布的 Release")
    adopt_parser.add_argument("version")
    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            for path in prepare(ROOT, args.version, source_commit=args.source_commit, dry_run=args.dry_run,
                                base_tag=args.base_tag):
                print(f"{'将修改' if args.dry_run else '已准备'} {path.relative_to(ROOT)}")
            if not args.dry_run:
                print("请填写发布说明，然后运行 python3 Tools/dictionary_release.py check --require-notes")
        elif args.command == "check":
            version = check(ROOT, args.version, require_notes=args.require_notes)
            print(f"词典版本校验通过：{tag(version)}")
        elif args.command == "build":
            manifest = build(ROOT, verify_core=args.verify_core)
            print(f"已构建 {len(manifest['packs'])} 个词典包到 {BUILD}")
        else:
            path = adopt(ROOT, args.version)
            print(f"已更新 {path.relative_to(ROOT)}；提交并推送 main 后 app 即可看到新词典包")
    except (ValueError, OSError, KeyError) as exc:
        print(f"词典发布失败：{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
