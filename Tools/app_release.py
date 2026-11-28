#!/usr/bin/env python3
"""Prepare, check and build Readling iOS app releases (see docs/release.md).

  prepare VERSION [--dry-run] [--base-tag TAG]  bump Xcode version/build and draft release notes
                                                (with RELEASE_AI_PROVIDER in .env, codex/claude writes the draft)
  check [TAG] [--require-notes]                 project.pbxproj, data migrations, bundled dictionary and notes agree
  build [--allow-unreleased]                    compile unsigned Release iOS app, verify bundle and package IPA
  post-release [TAG] [--destination DEST]       after tagging: freeze the data fixture of TAG and open `next`

Never commits, tags or pushes. Standard library only; runs on macOS Python 3.9+.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools"))
import dictionary_release  # noqa: E402
import release_ai  # noqa: E402

PBXPROJ = Path("Readling.xcodeproj/project.pbxproj")
DATA_VERSION_FILE = Path("Readling/Persistence/DataVersion.swift")
SNAPSHOTS_DIR = Path("Readling/Persistence/Snapshots")
MIGRATIONS_DIR = Path("Readling/Persistence/Migrations")
FIXTURES_DIR = Path("ReadlingTests/Fixtures/AppData")
NOTES_DIR = Path("docs/releases")
BUILD_DIR = Path("build/app")
DERIVED_DATA = Path("build/DerivedData")
APP_NAME = "Readling"
BUNDLE_ID = "com.inp146.readling"
UNRELEASED_VERSION = "0.0.0"
# The last entry of DataVersion.chain while the release after the last one is in development; prepare names it.
NEXT = "next"
SWIFT_SOURCE_DIRS = (Path("Readling"), Path("ReadlingTests"))
VERSION_RE = re.compile(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-rc([1-9]\d*))?")
TODO = "RELEASE_TODO"
REQUIRED_HEADINGS = ("## 主要变更", "## 安装与重签", "## 升级与兼容")
# Fixed timestamps and Unix permissions, so packaging the same .app twice gives the same bytes.
ZIP_TIME = (1980, 1, 1, 0, 0, 0)

TARGET_RE = re.compile(
    r'(?ms)\b([0-9A-F]{24}) /\* Readling \*/ = \{\s*isa = PBXNativeTarget;'
    r'[\s\S]*?buildConfigurationList = ([0-9A-F]{24})[^;]*;'
    r'[\s\S]*?productType = "com\.apple\.product-type\.application";'
)
SETTING_RE_TEMPLATE = r"(?m)^(\s*{key}\s*=\s*)([^;\n]+?)(;\s*)$"


def normalize_version(value: str, *, allow_unreleased: bool = False) -> str:
    version = value[1:] if value.startswith("v") else value
    match = VERSION_RE.fullmatch(version)
    if match is None:
        raise ValueError("版本格式必须是 0.1.0 或 0.1.0-rc1（可带 v 前缀）")
    major, minor, patch, _ = match.groups()
    if (major, minor, patch) == ("0", "0", "0"):
        if not allow_unreleased or version != UNRELEASED_VERSION:
            raise ValueError("发布版本必须高于 0.0.0，例如 0.1.0-rc1 或 0.1.0")
    return version


def version_key(version: str) -> tuple[int, int, int, float]:
    normalized = normalize_version(version, allow_unreleased=True)
    match = VERSION_RE.fullmatch(normalized)
    assert match is not None
    major, minor, patch, rc = match.groups()
    return int(major), int(minor), int(patch), int(rc) if rc else float("inf")


def tag(version: str) -> str:
    return f"v{version}"


def ipa_name(version: str) -> str:
    return f"{APP_NAME}-{version}.ipa"


def notes_path(root: Path, version: str) -> Path:
    return root / NOTES_DIR / f"{tag(version)}.md"


def format_pbx_version(version: str) -> str:
    return f'"{version}"' if "-" in version else version


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def version_identifier(version: str) -> str:
    return "Next" if version == NEXT else version.replace(".", "_").replace("-", "_")


def version_label(version: str) -> str:
    """How code comments name a version: `v0.2.0`, or `vNext` until prepare names it."""
    return "vNext" if version == NEXT else f"v{version}"


def snapshot_name(version: str) -> str:
    return f"V{version_identifier(version)}"


def migration_name(from_version: str, to_version: str) -> str:
    return f"Migration_{version_identifier(from_version)}_to_{version_identifier(to_version)}"


def fixture_bundle_path(root: Path, version: str) -> Path:
    return root / FIXTURES_DIR / f"{version}.bundle"


def fixture_is_complete(bundle: Path) -> bool:
    return (bundle / "Readling/library.json").is_file() and (bundle / "settings.plist").is_file()


def read_data_version(root: Path) -> tuple[list[str], list[str], str]:
    """Reads `chain`, `migrations` type names, and `currentSettingsKeys` snapshot from DataVersion.swift."""
    path = root / DATA_VERSION_FILE
    text = path.read_text(encoding="utf-8")
    chain_match = re.search(r"static\s+let\s+chain\s*(?::\s*\[String\])?\s*=\s*\[([^\]]*)\]", text)
    if chain_match is None:
        raise ValueError(f"{DATA_VERSION_FILE} 缺少 static let chain 定义")
    chain = re.findall(r'"([^"]+)"', chain_match.group(1))
    mig_match = re.search(r"static\s+let\s+migrations\s*:\s*\[Migration\]\s*=\s*\[([^\]]*)\]", text)
    if mig_match is None:
        raise ValueError(f"{DATA_VERSION_FILE} 缺少 static let migrations 定义")
    migrations = re.findall(r"\b(Migration_[A-Za-z0-9_]+)\.migration\b", mig_match.group(1))
    keys_match = re.search(r"static\s+let\s+currentSettingsKeys\s*=\s*(V[A-Za-z0-9_]+)\.settingsKeys\b", text)
    if keys_match is None:
        raise ValueError(f"{DATA_VERSION_FILE} 缺少 static let currentSettingsKeys 定义")
    return chain, migrations, keys_match.group(1)


def scaffold_empty_migration(root: Path, from_version: str, to_version: str) -> list[tuple[Path, str]]:
    """Builds the snapshot, empty migration step, and updated DataVersion.swift that open `to_version`.

    Normally `to_version` is NEXT, opened by post-release; prepare uses a number only when post-release never ran.
    """
    from_snap = snapshot_name(from_version)
    to_snap = snapshot_name(to_version)
    mig_type = migration_name(from_version, to_version)
    snapshot_text = f"""import Foundation

/// The data {version_label(to_version)} writes. Frozen once {version_label(to_version)} is released (see docs/data-versioning.md).
///
/// Changes from v{from_version}: none yet.
///
/// To change a stored structure, replace its typealias with a copy of the struct from `{from_snap}` and change the
/// copy (list the change above). Never use the app's live models here: snapshots of released versions must not change.
enum {to_snap} {{
    typealias Library = {from_snap}.Library
    typealias Book = {from_snap}.Book
    typealias ChapterInfo = {from_snap}.ChapterInfo
    typealias Position = {from_snap}.Position
    typealias Passage = {from_snap}.Passage
    static let settingsKeys = {from_snap}.settingsKeys
}}
"""
    migration_text = f"""import Foundation

/// v{from_version} → {version_label(to_version)}.
/// - Library: unchanged.
/// - Settings: unchanged.
/// - Reading text: not rebuilt.
///
/// This version's data changes go here (docs/data-versioning.md 3.3): convert source data from `{from_snap}` to
/// `{to_snap}` through `context`, and ask for `.content` to be rebuilt when import builds text differently. Keep the
/// list above up to date; it is what the release notes and the next reader go by.
enum {mig_type} {{
    static let migration = Migration(from: "{from_version}", to: "{to_version}") {{ _ in }}
}}
"""
    dv_path = root / DATA_VERSION_FILE
    dv_text = dv_path.read_text(encoding="utf-8")
    dv_text, c1 = re.subn(
        r"(static\s+let\s+chain\s*(?::\s*\[String\])?\s*=\s*\[)([^\]]*)(\])",
        lambda m: f'{m.group(1)}{m.group(2).rstrip()}, "{to_version}"{m.group(3)}',
        dv_text,
        count=1,
    )
    dv_text, c2 = re.subn(
        r"(static\s+let\s+migrations\s*:\s*\[Migration\]\s*=\s*\[)([^\]]*)(\])",
        lambda m: f"{m.group(1)}{m.group(2).rstrip()}\n        {mig_type}.migration,\n    {m.group(3)}",
        dv_text,
        count=1,
    )
    dv_text, c3 = re.subn(
        r"static\s+let\s+currentSettingsKeys\s*=\s*V[A-Za-z0-9_]+\.settingsKeys\b",
        f"static let currentSettingsKeys = {to_snap}.settingsKeys",
        dv_text,
        count=1,
    )
    if (c1, c2, c3) != (1, 1, 1):
        raise ValueError(f"无法更新 {DATA_VERSION_FILE}")
    return [
        (root / SNAPSHOTS_DIR / f"{to_snap}.swift", snapshot_text),
        (root / MIGRATIONS_DIR / f"{mig_type}.swift", migration_text),
        (dv_path, dv_text),
    ]


def name_next(root: Path, previous: str, version: str) -> tuple[list[tuple[Path, str]], list[Path]]:
    """Gives `next` its release number: renames VNext and Migration_<previous>_to_Next and every use of them.

    Returns the files to write and the files to remove; nothing is touched here.
    """
    old_snap, new_snap = snapshot_name(NEXT), snapshot_name(version)
    old_mig, new_mig = migration_name(previous, NEXT), migration_name(previous, version)
    old_snap_path = root / SNAPSHOTS_DIR / f"{old_snap}.swift"
    old_mig_path = root / MIGRATIONS_DIR / f"{old_mig}.swift"
    for path in (old_snap_path, old_mig_path):
        if not path.is_file():
            raise ValueError(f"缺少开发中的 {path.relative_to(root)}")
    for path in (root / SNAPSHOTS_DIR / f"{new_snap}.swift", root / MIGRATIONS_DIR / f"{new_mig}.swift"):
        if path.exists():
            raise ValueError(f"{path.relative_to(root)} 已存在，无法把 {NEXT} 命名为 {version}")

    def rename(text: str) -> str:
        text = re.sub(rf"\b{old_snap}\b", new_snap, text)
        text = re.sub(rf"\b{old_mig}\b", new_mig, text)
        return re.sub(r"\bvNext\b", f"v{version}", text)

    writes: list[tuple[Path, str]] = []
    for source_dir in SWIFT_SOURCE_DIRS:
        for path in sorted((root / source_dir).rglob("*.swift")):
            if path in (old_snap_path, old_mig_path):
                continue
            text = path.read_text(encoding="utf-8")
            updated = rename(text)
            if path == root / DATA_VERSION_FILE:
                updated, count = re.subn(
                    r"(static\s+let\s+chain\s*(?::\s*\[String\])?\s*=\s*\[[^\]]*)\"next\"([^\]]*\])",
                    lambda m: f'{m.group(1)}"{version}"{m.group(2)}', updated, count=1)
                if count != 1:
                    raise ValueError(f"无法在 {DATA_VERSION_FILE} 的 chain 中把 {NEXT} 改为 {version}")
            if updated != text:
                writes.append((path, updated))

    writes.append((root / SNAPSHOTS_DIR / f"{new_snap}.swift", rename(old_snap_path.read_text(encoding="utf-8"))))
    mig_text = rename(old_mig_path.read_text(encoding="utf-8"))
    declaration = f'Migration(from: "{previous}", to: "{NEXT}")'
    if declaration not in mig_text:
        raise ValueError(f"{old_mig_path.relative_to(root)} 必须声明 {declaration}")
    mig_text = mig_text.replace(declaration, f'Migration(from: "{previous}", to: "{version}")')
    writes.append((root / MIGRATIONS_DIR / f"{new_mig}.swift", mig_text))
    return writes, [old_snap_path, old_mig_path]


def merged_app_tags(root: Path) -> list[str]:
    git = shutil.which("git")
    if not git or not (root / ".git").exists():
        return []
    res = subprocess.run([git, "tag", "--merged", "HEAD", "--list", "v*"], cwd=root, capture_output=True, text=True)
    if res.returncode != 0:
        return []
    versions: list[str] = []
    for raw in res.stdout.splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            versions.append(normalize_version(raw))
        except ValueError:
            continue
    return sorted(set(versions), key=version_key)


def step_requests_content_rebuild(root: Path, from_version: str, to_version: str) -> bool:
    step_path = root / MIGRATIONS_DIR / f"{migration_name(from_version, to_version)}.swift"
    if not step_path.is_file():
        return False
    text = re.sub(r"//.*", "", step_path.read_text(encoding="utf-8"))
    return "requestRebuild(.content)" in text


def check_data_versioning(
    root: Path,
    project_version: str,
    target_version: str | None,
    *,
    require_notes: bool,
) -> list[str]:
    if not (root / DATA_VERSION_FILE).is_file():
        return []
    errors: list[str] = []
    try:
        chain, migrations, keys_snap = read_data_version(root)
    except ValueError as exc:
        return [str(exc)]

    if not chain:
        return [f"{DATA_VERSION_FILE} 的 chain 不能为空"]
    developing = chain[-1] == NEXT
    released = chain[:-1] if developing else chain
    valid_chain = True
    if NEXT in released:
        errors.append(f"{DATA_VERSION_FILE} 的 chain 只有最后一项可以是 {NEXT}")
        valid_chain = False
    if developing and len(chain) < 2:
        errors.append(f"{DATA_VERSION_FILE} 的 chain 在 {NEXT} 之前至少要有一个已发布版本")
        valid_chain = False
    for item in released:
        if item == NEXT:
            continue
        try:
            normalize_version(item)
        except ValueError as exc:
            errors.append(f"{DATA_VERSION_FILE} 的 chain 含无效版本 {item}：{exc}")
            valid_chain = False
    if valid_chain:
        if chain[0] != "0.1.0":
            errors.append(f"{DATA_VERSION_FILE} 的迁移链起点应为 0.1.0，当前为 {chain[0]}")
        for a, b in zip(released, released[1:]):
            if version_key(a) >= version_key(b):
                errors.append(f"{DATA_VERSION_FILE} 的 chain 必须严格递增：{a} -> {b}")

    expected_keys_snap = snapshot_name(chain[-1])
    if keys_snap != expected_keys_snap:
        errors.append(f"{DATA_VERSION_FILE} 的 currentSettingsKeys 应指向 {expected_keys_snap}，当前为 {keys_snap}")

    for item in chain:
        snap = snapshot_name(item)
        snap_path = root / SNAPSHOTS_DIR / f"{snap}.swift"
        if not snap_path.is_file():
            errors.append(f"缺少数据快照 {snap_path.relative_to(root)}")
        elif not re.search(rf"\benum\s+{re.escape(snap)}\b", snap_path.read_text(encoding="utf-8")):
            errors.append(f"{snap_path.relative_to(root)} 未定义 enum {snap}")

    expected_migrations = [migration_name(a, b) for a, b in zip(chain, chain[1:])]
    if migrations != expected_migrations:
        errors.append(f"{DATA_VERSION_FILE} 的 migrations 应为 {expected_migrations}，当前为 {migrations}")
    for a, b in zip(chain, chain[1:]):
        mig = migration_name(a, b)
        mig_path = root / MIGRATIONS_DIR / f"{mig}.swift"
        if not mig_path.is_file():
            errors.append(f"缺少迁移步骤 {mig_path.relative_to(root)}")
        else:
            mig_text = mig_path.read_text(encoding="utf-8")
            if f'Migration(from: "{a}", to: "{b}")' not in mig_text:
                errors.append(f'{mig_path.relative_to(root)} 必须声明 Migration(from: "{a}", to: "{b}")')

    for fixture_version in chain[:-1]:
        bundle = fixture_bundle_path(root, fixture_version)
        if not fixture_is_complete(bundle):
            errors.append(f"缺少已发布版本的数据夹具 {bundle.relative_to(root)}")

    if project_version and project_version != UNRELEASED_VERSION and valid_chain:
        # In development the project keeps the last release's number; prepare names both at once.
        expected = released[-1]
        if project_version != expected:
            errors.append(
                f"{PBXPROJ} 的版本 {project_version} 应为 {expected}"
                f"（{DATA_VERSION_FILE} 的 chain 为 {chain}）"
            )

    if target_version is not None and chain[-1] != target_version:
        hint = f"，请先运行 prepare {target_version}" if developing else ""
        errors.append(f"待发布版本 {target_version} 与 {DATA_VERSION_FILE} 末端 {chain[-1]} 不一致{hint}")

    for tagged in merged_app_tags(root):
        if tagged not in chain:
            errors.append(f"git tag v{tagged} 未包含在 {DATA_VERSION_FILE} 的 chain 中")

    if require_notes and len(chain) >= 2:
        effective = target_version or project_version
        if effective == chain[-1] and step_requests_content_rebuild(root, chain[-2], chain[-1]):
            path = notes_path(root, effective)
            if path.is_file():
                notes = path.read_text(encoding="utf-8")
                section = re.search(r"(?m)^## 升级与兼容[ \t]*\n([\s\S]*?)(?=^## |\Z)", notes)
                body = section.group(1) if section else ""
                if not any(word in body for word in ("自动更新", "自动重建", "重新生成正文")):
                    errors.append(
                        f"{migration_name(chain[-2], chain[-1])} 要求重建正文，"
                        f"{path.relative_to(root)} 的“## 升级与兼容”需说明已导入的书会自动更新"
                    )

    return errors


def _config_blocks(pbx_text: str) -> list[tuple[str, str, slice]]:
    target = TARGET_RE.search(pbx_text)
    if target is None:
        raise ValueError(f"{PBXPROJ} 缺少 Readling 应用 target")
    config_list_id = target.group(2)
    list_match = re.search(
        rf"(?ms)\b{config_list_id} /\*[^*]*\*/ = \{{\s*isa = XCConfigurationList;\s*"
        r"buildConfigurations = \(([\s\S]*?)\);",
        pbx_text,
    )
    if list_match is None:
        raise ValueError(f"{PBXPROJ} 缺少 Readling 的 XCConfigurationList")
    config_ids = re.findall(r"\b([0-9A-F]{24})\b", list_match.group(1))
    if not config_ids:
        raise ValueError(f"{PBXPROJ} 的 Readling 配置列表为空")
    blocks = []
    for config_id in config_ids:
        block = re.search(
            rf"(?ms)^(\t\t{config_id} /\* ([^*]+?) \*/ = \{{\s*isa = XCBuildConfiguration;\s*buildSettings = \{{)"
            r"([\s\S]*?)"
            r"(\n\t\t\t\};\s*name = [^\n]+;\s*\};)",
            pbx_text,
        )
        if block is None:
            raise ValueError(f"{PBXPROJ} 缺少配置块 {config_id}")
        blocks.append((config_id, block.group(2).strip(), slice(block.start(3), block.end(3))))
    return blocks


def _read_setting(settings_body: str, key: str) -> tuple[str, bool]:
    match = re.search(SETTING_RE_TEMPLATE.format(key=re.escape(key)), settings_body)
    if match is None:
        raise ValueError(f"{PBXPROJ} 的 Readling 配置缺少 {key}")
    raw = match.group(2).strip()
    if len(raw) >= 2 and raw[0] == '"' and raw[-1] == '"':
        return raw[1:-1], True
    if '"' in raw:
        raise ValueError(f"{PBXPROJ} 中 {key} 的引号不完整：{raw}")
    return raw, False


def read_project_configs(root: Path) -> dict[str, tuple[str, int, str, bool]]:
    """Returns {config_name: (marketing_version, build_number, bundle_id, marketing_quoted)}."""
    path = root / PBXPROJ
    if not path.is_file():
        raise ValueError(f"缺少 {PBXPROJ}")
    text = path.read_text(encoding="utf-8")
    configs: dict[str, tuple[str, int, str, bool]] = {}
    for _, name, body_slice in _config_blocks(text):
        body = text[body_slice]
        marketing, quoted = _read_setting(body, "MARKETING_VERSION")
        build_raw, _ = _read_setting(body, "CURRENT_PROJECT_VERSION")
        bundle_id, _ = _read_setting(body, "PRODUCT_BUNDLE_IDENTIFIER")
        if not re.fullmatch(r"[1-9]\d*", build_raw):
            raise ValueError(f"{PBXPROJ} ({name}) 的 CURRENT_PROJECT_VERSION 必须是正整数，当前为 {build_raw}")
        configs[name] = (marketing, int(build_raw), bundle_id, quoted)
    return configs


def write_project_version(pbx_text: str, version: str, build_number: int) -> str:
    if build_number < 1:
        raise ValueError("CURRENT_PROJECT_VERSION 必须是正整数")
    formatted_version = format_pbx_version(version)
    blocks = _config_blocks(pbx_text)
    # Replace from bottom to top so earlier slices remain valid.
    updated = pbx_text
    for _, name, body_slice in reversed(blocks):
        body = updated[body_slice]
        body, count_v = re.subn(
            SETTING_RE_TEMPLATE.format(key="MARKETING_VERSION"),
            lambda m: f"{m.group(1)}{formatted_version}{m.group(3)}",
            body,
            count=1,
        )
        body, count_b = re.subn(
            SETTING_RE_TEMPLATE.format(key="CURRENT_PROJECT_VERSION"),
            lambda m: f"{m.group(1)}{build_number}{m.group(3)}",
            body,
            count=1,
        )
        if count_v != 1 or count_b != 1:
            raise ValueError(f"{PBXPROJ} ({name}) 缺少 MARKETING_VERSION 或 CURRENT_PROJECT_VERSION")
        updated = updated[:body_slice.start] + body + updated[body_slice.stop:]
    return updated


def check(root: Path, version: str | None = None, *, require_notes: bool = False) -> tuple[str, int]:
    """Rejects inconsistent app/dictionary metadata before anything is built or published."""
    errors: list[str] = []
    current = ""
    build_number = 0
    try:
        configs = read_project_configs(root)
    except ValueError as exc:
        errors.append(str(exc))
        configs = {}

    if configs:
        if set(configs) != {"Debug", "Release"}:
            errors.append(f"{PBXPROJ} 的 Readling 配置应同时包含 Debug 和 Release，当前为 {sorted(configs)}")
        versions = {item[0] for item in configs.values()}
        builds = {item[1] for item in configs.values()}
        bundles = {item[2] for item in configs.values()}
        if bundles != {BUNDLE_ID}:
            errors.append(f"{PBXPROJ} 的 PRODUCT_BUNDLE_IDENTIFIER 应统一为 {BUNDLE_ID}")
        for cfg_name, (ver, _, _, quoted) in configs.items():
            if "-" in ver and not quoted:
                errors.append(f'{PBXPROJ} ({cfg_name}) 中含连字符的 MARKETING_VERSION 必须加双引号："{ver}"')
        if len(versions) != 1:
            errors.append(f"{PBXPROJ} 中 Debug 与 Release 的 MARKETING_VERSION 不一致：{configs}")
        else:
            current = next(iter(versions))
            try:
                normalize_version(current, allow_unreleased=True)
            except ValueError as exc:
                errors.append(f"{PBXPROJ} 的 MARKETING_VERSION 无效：{exc}")
        if len(builds) != 1:
            errors.append(f"{PBXPROJ} 中 Debug 与 Release 的 CURRENT_PROJECT_VERSION 不一致：{configs}")
        else:
            build_number = next(iter(builds))
            if current == UNRELEASED_VERSION and build_number != 1:
                errors.append(f"未发布基线 {UNRELEASED_VERSION} 的 CURRENT_PROJECT_VERSION 应为 1，当前为 {build_number}")

    plutil = shutil.which("plutil")
    if plutil and (root / PBXPROJ).is_file():
        lint = subprocess.run([plutil, "-lint", "-s", str(root / PBXPROJ)], capture_output=True, text=True)
        if lint.returncode != 0:
            errors.append(f"{PBXPROJ} 无法通过 plutil 语法校验")

    if (root / dictionary_release.RELEASE).is_file():
        try:
            dictionary_release.check(root)
        except ValueError as exc:
            errors.append(f"内置词典校验未通过：{exc}")
    else:
        errors.append(f"缺少 {dictionary_release.RELEASE}")

    expected_target = normalize_version(version) if version is not None else None
    if version is not None:
        if current == UNRELEASED_VERSION:
            errors.append(f"{PBXPROJ} 仍为未发布基线 {UNRELEASED_VERSION}，请先运行 prepare {expected_target}")
        elif current and current != expected_target:
            errors.append(f"tag 版本 {version} 与 {PBXPROJ} 的 {current} 不一致")

    errors.extend(check_data_versioning(root, current, expected_target, require_notes=require_notes))

    if require_notes:
        target_version = normalize_version(version) if version is not None else current
        if target_version == UNRELEASED_VERSION or not target_version:
            errors.append(f"当前版本为 {target_version or '空'}，尚未准备可发布的版本与发布说明")
        else:
            path = notes_path(root, target_version)
            if not path.is_file():
                errors.append(f"缺少发布说明 {path.relative_to(root)}")
            else:
                notes = path.read_text(encoding="utf-8")
                if not notes.startswith(f"# {APP_NAME} {tag(target_version)} 发布说明\n"):
                    errors.append("发布说明标题与版本号不一致")
                if TODO in notes:
                    errors.append(f"请完成 {path.relative_to(root)} 中的 {TODO} 内容")
                for heading in REQUIRED_HEADINGS:
                    section = re.search(rf"(?m)^{re.escape(heading)}[ \t]*\n([\s\S]*?)(?=^## |\Z)", notes)
                    if not section or not section[1].strip():
                        errors.append(f"发布说明缺少或未填写 {heading}")

    if errors:
        raise ValueError("\n".join(errors))
    return current, build_number


def draft_notes(version: str, previous: str | None, build_number: int, dict_version: str,
                *, base_tag: str | None = None, ai_review: bool = False,
                rebuilds_content: bool = False) -> str:
    if previous is None and base_tag is None:
        changes = f"{TODO}：填写首个版本的核心功能亮点（导入导出、阅读排版、查词与词典、翻译、生词复习），删除此占位行。"
        upgrade = (
            f"{TODO}：确认系统要求与数据存储说明，删除此占位段落后发布。\n\n"
            "需要 iOS 26.0 或更高版本。书籍、阅读进度与生词均保存在本机；日后升级新版本时，使用同一张证书和相同的 "
            f"Bundle ID（`{BUNDLE_ID}`）覆盖安装即可保留全部数据。"
        )
        basis = "仓库当前代码与文档"
    else:
        ref = base_tag or tag(previous or "")
        changes = f"{TODO}：填写相对 {ref} 的主要变更，删除此占位行。"
        rebuild_note = (
            "首次打开后，已导入的书籍会在后台自动更新正文，阅读进度与生词位置会自动换算。"
            if rebuilds_content else ""
        )
        upgrade = (
            f"{TODO}：说明从 {tag(previous) if previous else ref} 升级是否涉及书库/词典/设置迁移或回滚限制；"
            "若无需额外迁移，请保留下方覆盖安装说明并删除此占位行。\n\n"
            f"使用与旧版相同的签名证书和 Bundle ID（`{BUNDLE_ID}`）直接覆盖安装即可，书籍、阅读位置、生词、"
            f"已下载的词典包以及保存在本机钥匙串中的 API Key 都会保留。{rebuild_note}"
            "升级后的数据不可由旧版应用读取（不支持带数据降级）。"
        )
        basis = f"{ref} 以来的改动"
    review = ""
    if ai_review:
        review = (f"\n{TODO}：以下草稿由本地 AI CLI 根据{basis}生成，"
                  "请核对主要变更与升级说明后删除此行及其他待确认标记。\n")
    return f"""# {APP_NAME} {tag(version)} 发布说明
{review}
## 主要变更

{changes}

## 安装与重签

Release 提供未签名的真机安装包 `{ipa_name(version)}`（Build `{build_number}`，Bundle ID `{BUNDLE_ID}`，内置核心词典 `dict-{dict_version}`，支持 iOS 26.0+）及校验文件 `SHA256SUMS`。

- **iosign**：下载后运行 `iosign prod {ipa_name(version)}` 重签并安装到已连接的 iPhone。
- **自签工具**：将 `{ipa_name(version)}` 导入 AltStore、SideStore、Feather 或 Sideloadly 等工具签名安装。
- **完整性校验**：在同一目录运行 `shasum -a 256 -c SHA256SUMS`（Linux 用 `sha256sum -c SHA256SUMS`）。

## 升级与兼容

{upgrade}
"""


def prepare(root: Path, version: str, *, dry_run: bool = False, base_tag: str | None = None) -> list[Path]:
    version = normalize_version(version)
    current, current_build = check(root)
    previous = None if current == UNRELEASED_VERSION else current
    if version_key(version) <= version_key(current):
        raise ValueError(f"新版本必须高于当前版本 {current}")
    next_build = current_build if previous is None else current_build + 1
    notes = notes_path(root, version)
    if notes.exists():
        raise ValueError(f"{notes.relative_to(root)} 已存在；为保留已有说明，未修改任何文件")

    migration_writes: list[tuple[Path, str]] = []
    migration_removals: list[Path] = []
    rebuilds_content = False
    if (root / DATA_VERSION_FILE).is_file() and previous is not None:
        chain, _, _ = read_data_version(root)
        if chain[-1] == NEXT:
            # The usual case: post-release opened `next` after the last release, and now it gets its number.
            rebuilds_content = step_requests_content_rebuild(root, chain[-2], NEXT)
            migration_writes, migration_removals = name_next(root, previous, version)
        elif chain[-1] == previous:
            # post-release never opened `next`: this release changes no data.
            prev_bundle = fixture_bundle_path(root, previous)
            if not fixture_is_complete(prev_bundle):
                raise ValueError(
                    f"缺少已发布版本的数据夹具 {prev_bundle.relative_to(root)}；"
                    f"请先运行 python3 Tools/app_release.py post-release {tag(previous)}"
                )
            migration_writes = scaffold_empty_migration(root, previous, version)
        else:
            raise ValueError(
                f"{DATA_VERSION_FILE} 当前末端为 {chain[-1]}，"
                f"既不是 {NEXT}，也不是当前已发布版本 {previous}"
            )

    dict_version = dictionary_release.load_release(root)["version"]
    pbx_path = root / PBXPROJ
    updated_pbx = write_project_version(pbx_path.read_text(encoding="utf-8"), version, next_build)
    paths = [pbx_path, *[p for p, _ in migration_writes], *migration_removals, notes]

    config = release_ai.load_config(root)
    if config.provider != "none":
        release_ai.validate_base_tag(root, previous, base_tag, kind="app")
    else:
        print("提示：当前 RELEASE_AI_PROVIDER=none（未配置 .env 或显式设为 none），仅生成静态模板")
    if dry_run:
        if config.provider != "none":
            model_note = f" ({config.model})" if config.model else ""
            print(f"将调用 {config.provider}{model_note} 生成发布说明草稿（dry-run 不调用模型）")
        return paths

    # Draft notes first: if the agent fails, project.pbxproj and migration files stay untouched.
    template = draft_notes(version, previous, next_build, dict_version, base_tag=base_tag,
                           ai_review=config.provider != "none", rebuilds_content=rebuilds_content)
    if config.provider == "none":
        notes.parent.mkdir(parents=True, exist_ok=True)
        notes.write_text(template, encoding="utf-8")
    else:
        release_ai.generate(root, version, previous, config, template=template, target=notes.relative_to(root),
                            base_tag=base_tag, kind="app")
    for path, content in migration_writes:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    for path in migration_removals:
        path.unlink()
    pbx_path.write_text(updated_pbx, encoding="utf-8")
    check(root, version)
    return paths


def verify_app_bundle(app_dir: Path, version: str, build_number: int, *, core_version: str | None = None) -> None:
    if not app_dir.is_dir() or app_dir.name != f"{APP_NAME}.app":
        raise ValueError(f"找不到有效的 {APP_NAME}.app：{app_dir}")
    info_path = app_dir / "Info.plist"
    if not info_path.is_file():
        raise ValueError(f"{app_dir.name} 缺少 Info.plist")
    with open(info_path, "rb") as f:
        info = plistlib.load(f)
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise ValueError(f"Info.plist 的 CFBundleIdentifier 为 {info.get('CFBundleIdentifier')}，应为 {BUNDLE_ID}")
    if info.get("CFBundleShortVersionString") != version:
        raise ValueError(
            f"Info.plist 的 CFBundleShortVersionString 为 {info.get('CFBundleShortVersionString')}，应为 {version}"
        )
    if info.get("CFBundleVersion") != str(build_number):
        raise ValueError(f"Info.plist 的 CFBundleVersion 为 {info.get('CFBundleVersion')}，应为 {build_number}")
    executable = app_dir / info.get("CFBundleExecutable", APP_NAME)
    if not executable.is_file():
        raise ValueError(f"{app_dir.name} 缺少主可执行文件 {executable.name}")
    bundled_core = app_dir / "dictionary-core.sqlite"
    if not bundled_core.is_file():
        raise ValueError(f"{app_dir.name} 缺少内置核心词典 dictionary-core.sqlite")
    if core_version is not None:
        meta = dictionary_release.pack_meta(bundled_core)
        if meta.get("id") != "core" or meta.get("version") != core_version:
            raise ValueError(f"{app_dir.name} 内置核心词典版本为 {meta.get('version')}，应为 {core_version}")


def package_ipa(app_dir: Path, out_dir: Path, version: str, build_number: int,
                *, core_version: str | None = None) -> Path:
    """Verifies Readling.app and packages it as Payload/Readling.app inside a reproducible .ipa + SHA256SUMS."""
    verify_app_bundle(app_dir, version, build_number, core_version=core_version)
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    archive = out_dir / ipa_name(version)

    entries: list[tuple[str, Path | None]] = [("Payload/", None), (f"Payload/{app_dir.name}/", None)]
    for current_root, dirs, files in os.walk(app_dir, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d != "__MACOSX" and not d.startswith("._"))
        files = sorted(f for f in files if f != ".DS_Store" and not f.startswith("._"))
        base = Path(current_root)
        rel_root = base.relative_to(app_dir)
        prefix = f"Payload/{app_dir.name}" if rel_root == Path(".") else f"Payload/{app_dir.name}/{rel_root.as_posix()}"
        for d in dirs:
            p = base / d
            if p.is_symlink():
                entries.append((f"{prefix}/{d}", p))
            else:
                entries.append((f"{prefix}/{d}/", None))
        for f in files:
            entries.append((f"{prefix}/{f}", base / f))

    with zipfile.ZipFile(archive, "w") as z:
        for arcname, src in entries:
            info = zipfile.ZipInfo(arcname, date_time=ZIP_TIME)
            info.create_system = 3
            if src is None:
                info.compress_type = zipfile.ZIP_STORED
                info.external_attr = (stat.S_IFDIR | 0o755) << 16 | 0x10
                z.writestr(info, b"")
            elif src.is_symlink():
                info.compress_type = zipfile.ZIP_STORED
                info.external_attr = (stat.S_IFLNK | 0o755) << 16
                z.writestr(info, os.readlink(src).encode("utf-8"))
            else:
                mode = 0o755 if (src.stat().st_mode & 0o111) else 0o644
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = (stat.S_IFREG | mode) << 16
                z.writestr(info, src.read_bytes(), compresslevel=9)

    checksum = sha256_file(archive)
    (out_dir / "SHA256SUMS").write_text(f"{checksum}  {archive.name}\n", encoding="utf-8")
    return archive


def build(root: Path, *, allow_unreleased: bool = False) -> Path:
    version, build_number = check(root)
    if version == UNRELEASED_VERSION and not allow_unreleased:
        raise ValueError(f"当前为未发布基线 {UNRELEASED_VERSION}；发版前请先运行 prepare，或用 --allow-unreleased 测试构建")
    if not shutil.which("xcodebuild"):
        raise ValueError("找不到 xcodebuild；构建 iOS 安装包需要在安装 Xcode 的 macOS 上运行")
    core_version = dictionary_release.load_release(root)["version"]
    derived = root / DERIVED_DATA
    command = [
        "xcodebuild",
        "-project", str(root / "Readling.xcodeproj"),
        "-scheme", APP_NAME,
        "-configuration", "Release",
        "-destination", "generic/platform=iOS",
        "-derivedDataPath", str(derived),
        "CODE_SIGNING_ALLOWED=NO",
        "build",
    ]
    result = subprocess.run(command, cwd=root)
    if result.returncode != 0:
        raise ValueError("xcodebuild 编译失败")
    app_dir = derived / "Build" / "Products" / "Release-iphoneos" / f"{APP_NAME}.app"
    return package_ipa(app_dir, root / BUILD_DIR, version, build_number, core_version=core_version)


def ensure_head_is_tag(root: Path, version: str) -> None:
    """The fixture must come from the tagged code: HEAD is the tag and tracked files are unchanged."""
    git = shutil.which("git")
    if not git:
        raise ValueError("找不到 git")
    def rev(ref: str) -> str:
        res = subprocess.run([git, "rev-parse", "--verify", "--quiet", ref], cwd=root, capture_output=True, text=True)
        return res.stdout.strip() if res.returncode == 0 else ""
    tagged = rev(f"refs/tags/{tag(version)}^{{commit}}")
    if not tagged:
        raise ValueError(f"找不到 git tag {tag(version)}；请先打 tag 再运行 post-release")
    if tagged != rev("HEAD"):
        raise ValueError(f"HEAD 不是 {tag(version)}；请在该 tag 指向的提交上运行 post-release")
    if subprocess.run([git, "diff", "--quiet", "HEAD"], cwd=root).returncode != 0:
        raise ValueError("工作区有未提交的改动；数据夹具必须由 tag 上的代码生成")


def generate_fixture(root: Path, version: str, *, destination: str) -> Path:
    """Generates ReadlingTests/Fixtures/AppData/<version>.bundle with the code of the working tree."""
    bundle = fixture_bundle_path(root, version)
    if not shutil.which("xcodebuild"):
        raise ValueError("找不到 xcodebuild；生成数据夹具需要在安装 Xcode 的 macOS 上运行")
    staging = Path(tempfile.mkdtemp(prefix=f"readling-fixture-{version}-"))
    try:
        env = dict(os.environ, TEST_RUNNER_READLING_WRITE_FIXTURE=str(staging))
        command = [
            "xcodebuild",
            "-project", str(root / "Readling.xcodeproj"),
            "-scheme", APP_NAME,
            "-destination", destination,
            "test",
            "-only-testing:ReadlingTests/writeCurrentDataFixtureWhenRequested()",
        ]
        res = subprocess.run(command, cwd=root, env=env)
        if res.returncode != 0 or not fixture_is_complete(staging):
            raise ValueError("xcodebuild 生成数据夹具失败")
        (staging / "GENERATE.md").write_text(
            f"# v{version} 数据夹具\n\n"
            f"在 `{tag(version)}` 上由 `python3 Tools/app_release.py post-release {tag(version)}` 生成并冻结，不要手改。\n",
            encoding="utf-8",
        )
        bundle.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(staging), str(bundle))
    finally:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)
    return bundle


def post_release(
    root: Path,
    version: str | None = None,
    *,
    destination: str = "platform=iOS Simulator,name=iPhone 17 Pro",
    make_fixture=generate_fixture,
) -> list[Path]:
    """After tagging a release: freezes its data fixture, then opens `next` with an empty step for development."""
    current, _ = check(root, version)
    target = normalize_version(version) if version is not None else current
    if target == UNRELEASED_VERSION:
        raise ValueError("未发布基线没有可收尾的版本")
    ensure_head_is_tag(root, target)
    paths: list[Path] = []
    bundle = fixture_bundle_path(root, target)
    if fixture_is_complete(bundle):
        print(f"数据夹具 {bundle.relative_to(root)} 已存在，沿用")
    elif bundle.exists():
        raise ValueError(f"{bundle.relative_to(root)} 不完整；确认无用后删除再重试")
    else:
        paths.append(make_fixture(root, target, destination=destination))
    if (root / DATA_VERSION_FILE).is_file():
        writes = scaffold_empty_migration(root, target, NEXT)
        for path, content in writes:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        paths.extend(path for path, _ in writes)
    check(root)
    return paths


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    prepare_parser = commands.add_parser("prepare", help="升级版本号与 Build 号，并生成发布说明草稿")
    prepare_parser.add_argument("version")
    prepare_parser.add_argument("--dry-run", action="store_true", help="只显示将修改的文件，不调用模型、不写文件")
    prepare_parser.add_argument("--base-tag", help="AI 草稿的比较基准；默认是上一个 app 版本的 tag（首版默认全仓）")

    check_parser = commands.add_parser("check", help="校验版本一致性，可传入待发布 tag")
    check_parser.add_argument("version", nargs="?")
    check_parser.add_argument("--require-notes", action="store_true", help="要求发布说明已完成")

    build_parser = commands.add_parser("build", help="编译无签名 Release 真机包并打包到 build/app")
    build_parser.add_argument("--allow-unreleased", action="store_true",
                              help="允许在 0.0.0 未发布基线下运行编译与打包校验（供日常 CI 验证）")

    post_parser = commands.add_parser("post-release", help="在发布 tag 上冻结该版本的数据夹具，并开启下一版（next）的迁移步骤")
    post_parser.add_argument("version", nargs="?")
    post_parser.add_argument("--destination", default="platform=iOS Simulator,name=iPhone 17 Pro",
                                help="运行夹具生成的 iOS 模拟器 destination")

    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            for path in prepare(ROOT, args.version, dry_run=args.dry_run, base_tag=args.base_tag):
                print(f"{'将修改' if args.dry_run else '已准备'} {path.relative_to(ROOT)}")
            if not args.dry_run:
                print("请审阅并完善发布说明，然后运行 python3 Tools/app_release.py check --require-notes")
        elif args.command == "check":
            version, build_number = check(ROOT, args.version, require_notes=args.require_notes)
            label = f"{UNRELEASED_VERSION}（未发布基线，Build {build_number}）" if version == UNRELEASED_VERSION \
                else f"{tag(version)} (Build {build_number})"
            print(f"App 版本校验通过：{label}")
        elif args.command == "post-release":
            for path in post_release(ROOT, args.version, destination=args.destination):
                print(f"已生成 {path.relative_to(ROOT)}")
            print("请提交以上文件并推送 main；下一版的数据改动写进 *_to_Next 迁移步骤与 VNext 快照")
        else:
            archive = build(ROOT, allow_unreleased=args.allow_unreleased)
            print(f"已打包 {archive.relative_to(ROOT)} 与 {(archive.parent / 'SHA256SUMS').relative_to(ROOT)}")
    except (ValueError, OSError, KeyError, plistlib.InvalidFileException) as exc:
        print(f"App 发布失败：{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
