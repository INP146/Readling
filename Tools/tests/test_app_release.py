"""Tests for Tools/app_release.py (stdlib only)."""

import hashlib
import json
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import app_release  # noqa: E402
import dictionary_release  # noqa: E402
import release_ai  # noqa: E402
from test_dictionary_release import write_csv  # noqa: E402

REAL_PBXPROJ = (Path(__file__).resolve().parents[2] / app_release.PBXPROJ).read_text(encoding="utf-8")
REAL_RUN = subprocess.run
REAL_WHICH = shutil.which


def setup_minimal_repo(root: Path) -> str:
    """Writes Readling.xcodeproj/project.pbxproj (0.0.0 build 1) and a valid bundled core dictionary."""
    pbx = root / app_release.PBXPROJ
    pbx.parent.mkdir(parents=True, exist_ok=True)
    pbx.write_text(app_release.write_project_version(REAL_PBXPROJ, "0.0.0", 1), encoding="utf-8")

    csv_path = root / dictionary_release.SOURCE_CSV
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    write_csv(csv_path)
    dict_version = "2026.11.18.1"
    commit = "a" * 40
    source = {
        "name": "ECDICT",
        "commit": commit,
        "url": dictionary_release.source_url(commit),
        "sha256": dictionary_release.sha256_file(csv_path),
    }
    out = root / "build/test-dict"
    dictionary_release.builder.build(str(csv_path), str(out), {"core"}, dict_version, commit, log=lambda _: None)
    core_dest = root / dictionary_release.CORE
    core_dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(out / "dictionary-core.sqlite", core_dest)
    shutil.rmtree(out)

    rel_path = root / dictionary_release.RELEASE
    rel_path.parent.mkdir(parents=True, exist_ok=True)
    rel_path.write_text(json.dumps({"version": dict_version, "source": source}, indent=2) + "\n", encoding="utf-8")
    return dict_version


def complete_notes(path: Path) -> None:
    lines = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if app_release.TODO in line:
            if "主要变更" in line or "亮点" in line:
                lines.append("- 支持 EPUB/TXT 离线阅读、点词查释义与生词复习。")
            continue
        lines.append(line)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


class VersionParsingTests(unittest.TestCase):
    def test_semver_and_rc_ordering(self):
        self.assertEqual(app_release.normalize_version("v0.1.0-rc1"), "0.1.0-rc1")
        self.assertEqual(app_release.normalize_version("0.1.0"), "0.1.0")
        self.assertEqual(app_release.normalize_version("0.0.0", allow_unreleased=True), "0.0.0")
        ordered = ["0.0.0", "0.1.0-rc1", "0.1.0-rc2", "0.1.0-rc10", "0.1.0", "0.1.1-rc1", "0.1.1", "1.0.0"]
        self.assertEqual(sorted(reversed(ordered), key=app_release.version_key), ordered)

    def test_invalid_versions_are_rejected(self):
        for bad in ("0.0.0", "v0.0.0", "0.0.0-rc1", "1.0", "01.1.0", "0.1.0-rc0", "0.1.0-beta1", "dict-2026.11.18"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                app_release.normalize_version(bad)


class AppReleaseLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.env = mock.patch.dict(os.environ, {"RELEASE_AI_PROVIDER": "none"})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.dict_version = setup_minimal_repo(self.root)

    def tearDown(self):
        shutil.rmtree(self.root)

    def test_unreleased_baseline_passes_default_check_but_blocks_tag_release(self):
        self.assertEqual(app_release.check(self.root), ("0.0.0", 1))
        with self.assertRaisesRegex(ValueError, "未发布基线"):
            app_release.check(self.root, "v0.1.0")
        with self.assertRaisesRegex(ValueError, "尚未准备"):
            app_release.check(self.root, require_notes=True)

    def test_first_release_keeps_build_1_and_subsequent_releases_increment_build(self):
        # First release: 0.1.0-rc1 (quoted in pbxproj because of hyphen), Build 1.
        app_release.prepare(self.root, "v0.1.0-rc1")
        self.assertEqual(app_release.check(self.root, "v0.1.0-rc1"), ("0.1.0-rc1", 1))
        pbx_text = (self.root / app_release.PBXPROJ).read_text(encoding="utf-8")
        self.assertIn('MARKETING_VERSION = "0.1.0-rc1";', pbx_text)
        with self.assertRaisesRegex(ValueError, "RELEASE_TODO"):
            app_release.check(self.root, "v0.1.0-rc1", require_notes=True)

        rc_notes = app_release.notes_path(self.root, "0.1.0-rc1")
        self.assertIn("Readling-0.1.0-rc1.ipa", rc_notes.read_text(encoding="utf-8"))
        self.assertIn(f"dict-{self.dict_version}", rc_notes.read_text(encoding="utf-8"))
        complete_notes(rc_notes)
        self.assertEqual(app_release.check(self.root, "v0.1.0-rc1", require_notes=True), ("0.1.0-rc1", 1))

        # Second release: 0.1.0 (unquoted in pbxproj), Build 2.
        app_release.prepare(self.root, "0.1.0")
        self.assertEqual(app_release.check(self.root, "v0.1.0"), ("0.1.0", 2))
        pbx_text = (self.root / app_release.PBXPROJ).read_text(encoding="utf-8")
        self.assertIn("MARKETING_VERSION = 0.1.0;", pbx_text)
        complete_notes(app_release.notes_path(self.root, "0.1.0"))
        self.assertEqual(app_release.check(self.root, "v0.1.0", require_notes=True), ("0.1.0", 2))

        # Cannot go backwards or re-prepare the same version.
        for bad in ("0.1.0", "0.1.0-rc2"):
            with self.assertRaisesRegex(ValueError, "高于"):
                app_release.prepare(self.root, bad)

    def test_check_catches_unquoted_hyphen_and_mismatched_configs(self):
        pbx_path = self.root / app_release.PBXPROJ
        broken = pbx_path.read_text(encoding="utf-8").replace(
            "MARKETING_VERSION = 0.0.0;", "MARKETING_VERSION = 0.1.0-rc1;"
        )
        pbx_path.write_text(broken, encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "双引号"):
            app_release.check(self.root)

        mismatched = REAL_PBXPROJ.replace("CURRENT_PROJECT_VERSION = 1;", "CURRENT_PROJECT_VERSION = 2;", 1)
        pbx_path.write_text(mismatched, encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "不一致"):
            app_release.check(self.root)


class PackageIPATests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.dict_version = setup_minimal_repo(self.root)
        self.app_dir = self.root / "Readling.app"
        self.app_dir.mkdir()
        info = {
            "CFBundleIdentifier": "com.inp146.readling",
            "CFBundleDisplayName": "Readling",
            "CFBundleExecutable": "Readling",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1",
        }
        (self.app_dir / "Info.plist").write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        binary = self.app_dir / "Readling"
        binary.write_bytes(b"\xcf\xfa\xed\xfe-mach-o")
        binary.chmod(0o755)
        shutil.copyfile(self.root / dictionary_release.CORE, self.app_dir / "dictionary-core.sqlite")
        (self.app_dir / "dictionary-core.sqlite").chmod(0o644)
        (self.app_dir / ".DS_Store").write_bytes(b"noise")
        (self.app_dir / "Frameworks").mkdir()
        os.symlink("Readling", self.app_dir / "Frameworks/Link")

    def tearDown(self):
        shutil.rmtree(self.root)

    def test_package_ipa_is_reproducible_and_preserves_unix_modes(self):
        out1 = self.root / "out1"
        out2 = self.root / "out2"
        ipa1 = app_release.package_ipa(self.app_dir, out1, "0.1.0", 1, core_version=self.dict_version)
        ipa2 = app_release.package_ipa(self.app_dir, out2, "0.1.0", 1, core_version=self.dict_version)
        self.assertEqual(ipa1.read_bytes(), ipa2.read_bytes())
        expected_sum = f"{hashlib.sha256(ipa1.read_bytes()).hexdigest()}  Readling-0.1.0.ipa\n"
        self.assertEqual((out1 / "SHA256SUMS").read_text(encoding="utf-8"), expected_sum)

        with zipfile.ZipFile(ipa1) as z:
            names = set(z.namelist())
            self.assertIn("Payload/Readling.app/Readling", names)
            self.assertIn("Payload/Readling.app/Info.plist", names)
            self.assertIn("Payload/Readling.app/dictionary-core.sqlite", names)
            self.assertNotIn("Payload/Readling.app/.DS_Store", names)
            exec_mode = z.getinfo("Payload/Readling.app/Readling").external_attr >> 16
            plist_mode = z.getinfo("Payload/Readling.app/Info.plist").external_attr >> 16
            link_info = z.getinfo("Payload/Readling.app/Frameworks/Link")
            self.assertEqual(stat.S_IMODE(exec_mode), 0o755)
            self.assertEqual(stat.S_IMODE(plist_mode), 0o644)
            self.assertTrue(stat.S_ISLNK(link_info.external_attr >> 16))
            self.assertEqual(z.read("Payload/Readling.app/Frameworks/Link"), b"Readling")

    def test_package_ipa_rejects_mismatched_bundle_metadata(self):
        with self.assertRaisesRegex(ValueError, "CFBundleShortVersionString"):
            app_release.package_ipa(self.app_dir, self.root / "out", "0.2.0", 1, core_version=self.dict_version)
        with self.assertRaisesRegex(ValueError, "CFBundleVersion"):
            app_release.package_ipa(self.app_dir, self.root / "out", "0.1.0", 2, core_version=self.dict_version)
        with self.assertRaisesRegex(ValueError, "核心词典版本"):
            app_release.package_ipa(self.app_dir, self.root / "out", "0.1.0", 1, core_version="2099.01.01")


class AppAgentDraftTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.env = mock.patch.dict(os.environ, {"RELEASE_AI_PROVIDER": "claude"}, clear=False)
        self.env.start()
        self.which = mock.patch.object(
            release_ai.shutil, "which", lambda name: f"/bin/{name}" if name in {"claude", "codex"} else REAL_WHICH(name)
        )
        self.which.start()
        self.addCleanup(self.env.stop)
        self.addCleanup(self.which.stop)
        setup_minimal_repo(self.root)
        REAL_RUN(["git", "init", "-q"], cwd=self.root, check=True)
        REAL_RUN(["git", "config", "user.name", "Release Test"], cwd=self.root, check=True)
        REAL_RUN(["git", "config", "user.email", "release@example.invalid"], cwd=self.root, check=True)
        REAL_RUN(["git", "add", "."], cwd=self.root, check=True)
        REAL_RUN(["git", "commit", "-qm", "initial baseline"], cwd=self.root, check=True)

    def tearDown(self):
        shutil.rmtree(self.root)

    def test_first_release_drafts_with_ai_without_needing_previous_app_tag(self):
        calls = []

        def run(command, **kwargs):
            if command[0] == "git" or "plutil" in str(command[0]):
                return REAL_RUN(command, **kwargs)
            calls.append((command, kwargs))
            notes = app_release.notes_path(self.root, "0.1.0")
            text = notes.read_text(encoding="utf-8")
            notes.write_text(text.replace("填写首个版本的核心功能亮点", "提供离线阅读与查词"), encoding="utf-8")
            return subprocess.CompletedProcess(command, 0, json.dumps({"is_error": False}), "")

        with mock.patch.object(release_ai.subprocess, "run", run):
            app_release.prepare(self.root, "0.1.0")
        self.assertEqual(app_release.check(self.root, "v0.1.0"), ("0.1.0", 1))
        command, kwargs = calls[0]
        self.assertIn("首个版本 v0.1.0", kwargs["input"])
        self.assertNotIn("Bash(sqlite3:*)", command)

    def test_failed_ai_leaves_pbxproj_untouched_and_missing_tag_fails_fast(self):
        before = (self.root / app_release.PBXPROJ).read_text(encoding="utf-8")
        with mock.patch.object(release_ai, "generate", side_effect=ValueError("claude 生成失败")):
            with self.assertRaisesRegex(ValueError, "生成失败"):
                app_release.prepare(self.root, "0.1.0")
        self.assertEqual((self.root / app_release.PBXPROJ).read_text(encoding="utf-8"), before)
        self.assertFalse(app_release.notes_path(self.root, "0.1.0").exists())

        # Once 0.1.0 is prepared without tagging v0.1.0 in git, preparing 0.1.1 with AI fails before touching files.
        with mock.patch.dict(os.environ, {"RELEASE_AI_PROVIDER": "none"}):
            app_release.prepare(self.root, "0.1.0")
            complete_notes(app_release.notes_path(self.root, "0.1.0"))
        with self.assertRaisesRegex(ValueError, "tag 存在"):
            app_release.prepare(self.root, "0.1.1", dry_run=True)


class DataVersioningReleaseTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.env = mock.patch.dict(os.environ, {"RELEASE_AI_PROVIDER": "none"})
        self.env.start()
        self.addCleanup(self.env.stop)
        setup_minimal_repo(self.root)
        pbx = self.root / app_release.PBXPROJ
        pbx.write_text(app_release.write_project_version(REAL_PBXPROJ, "0.1.0", 1), encoding="utf-8")
        # Seed DataVersion in development after 0.1.0: 0.1.0 -> next (rebuilding content), with a 0.1.0 fixture.
        (self.root / app_release.SNAPSHOTS_DIR).mkdir(parents=True)
        (self.root / app_release.MIGRATIONS_DIR).mkdir(parents=True)
        (self.root / app_release.SNAPSHOTS_DIR / "V0_1_0.swift").write_text("enum V0_1_0 { static let settingsKeys: [String: String] = [:] }\n", encoding="utf-8")
        (self.root / app_release.SNAPSHOTS_DIR / "VNext.swift").write_text(
            "/// The data vNext writes.\nenum VNext { static let settingsKeys = V0_1_0.settingsKeys }\n", encoding="utf-8")
        (self.root / app_release.MIGRATIONS_DIR / "Migration_0_1_0_to_Next.swift").write_text(
            'enum Migration_0_1_0_to_Next {\n'
            '    static let migration = Migration(from: "0.1.0", to: "next") { ctx in\n'
            '        _ = VNext.settingsKeys\n'
            '        ctx.requestRebuild(.content)\n'
            '    }\n'
            '}\n',
            encoding="utf-8",
        )
        (self.root / app_release.DATA_VERSION_FILE).write_text(
            'enum DataVersion {\n'
            '    static let chain = ["0.1.0", "next"]\n'
            '    static let next = "next"\n'
            '    static let migrations: [Migration] = [\n'
            '        Migration_0_1_0_to_Next.migration,\n'
            '    ]\n'
            '    static let currentSettingsKeys = VNext.settingsKeys\n'
            '}\n',
            encoding="utf-8",
        )
        (self.root / "Readling/LibraryStore.swift").write_text("// see `VNext.Library`, written since vNext\n", encoding="utf-8")
        self._write_fixture("0.1.0")

    def tearDown(self):
        shutil.rmtree(self.root)

    def _write_fixture(self, version: str) -> None:
        bundle = app_release.fixture_bundle_path(self.root, version)
        (bundle / "Readling").mkdir(parents=True)
        (bundle / "Readling/library.json").write_text('{"version":2}\n', encoding="utf-8")
        (bundle / "settings.plist").write_text("<plist version=\"1.0\"><dict/></plist>\n", encoding="utf-8")

    def test_real_repo_passes_check(self):
        real_root = Path(__file__).resolve().parents[2]
        version, build = app_release.check(real_root)
        self.assertTrue(version)
        self.assertGreaterEqual(build, 1)

    def _post_release(self, version: str) -> list[Path]:
        def fake_fixture(root, target, *, destination):
            self._write_fixture(target)
            return app_release.fixture_bundle_path(root, target)
        with mock.patch.object(app_release, "ensure_head_is_tag"):
            return app_release.post_release(self.root, f"v{version}", make_fixture=fake_fixture)

    def test_prepare_names_next_and_post_release_opens_it_again(self):
        self.assertEqual(app_release.check(self.root), ("0.1.0", 1))
        # Tag checks fail while the version in development has no number yet.
        with self.assertRaisesRegex(ValueError, "请先运行 prepare 0.2.0"):
            app_release.check(self.root, "v0.2.0")
        # The project keeps the last release's number while `next` is in development.
        pbx = self.root / app_release.PBXPROJ
        pbx.write_text(app_release.write_project_version(REAL_PBXPROJ, "0.2.0", 2), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "应为 0.1.0"):
            app_release.check(self.root)
        pbx.write_text(app_release.write_project_version(REAL_PBXPROJ, "0.1.0", 1), encoding="utf-8")

        # The number is decided at prepare: any version above 0.1.0 works, here 0.1.1.
        planned = app_release.prepare(self.root, "0.1.1", dry_run=True)
        self.assertFalse(app_release.notes_path(self.root, "0.1.1").exists())
        self.assertIn(self.root / app_release.MIGRATIONS_DIR / "Migration_0_1_0_to_Next.swift", planned)
        app_release.prepare(self.root, "0.1.1")
        notes = app_release.notes_path(self.root, "0.1.1")
        self.assertIn("自动更新正文", notes.read_text(encoding="utf-8"))
        complete_notes(notes)
        self.assertEqual(app_release.check(self.root, "v0.1.1", require_notes=True), ("0.1.1", 2))
        chain, migs, keys_snap = app_release.read_data_version(self.root)
        self.assertEqual(chain, ["0.1.0", "0.1.1"])
        self.assertEqual(migs, ["Migration_0_1_0_to_0_1_1"])
        self.assertEqual(keys_snap, "V0_1_1")
        self.assertFalse((self.root / app_release.SNAPSHOTS_DIR / "VNext.swift").exists())
        self.assertFalse((self.root / app_release.MIGRATIONS_DIR / "Migration_0_1_0_to_Next.swift").exists())
        step = (self.root / app_release.MIGRATIONS_DIR / "Migration_0_1_0_to_0_1_1.swift").read_text(encoding="utf-8")
        self.assertIn('Migration(from: "0.1.0", to: "0.1.1")', step)
        self.assertIn("V0_1_1.settingsKeys", step)
        self.assertEqual((self.root / app_release.SNAPSHOTS_DIR / "V0_1_1.swift").read_text(encoding="utf-8"),
                         "/// The data v0.1.1 writes.\nenum V0_1_1 { static let settingsKeys = V0_1_0.settingsKeys }\n")
        self.assertEqual((self.root / "Readling/LibraryStore.swift").read_text(encoding="utf-8"),
                         "// see `V0_1_1.Library`, written since v0.1.1\n")
        self.assertIn('static let next = "next"', (self.root / app_release.DATA_VERSION_FILE).read_text(encoding="utf-8"))

        # Removing the rebuild notice fails check --require-notes because the step requests .content.
        stripped = notes.read_text(encoding="utf-8").replace("首次打开后，已导入的书籍会在后台自动更新正文，阅读进度与生词位置会自动换算。", "")
        notes.write_text(stripped, encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "要求重建正文"):
            app_release.check(self.root, "v0.1.1", require_notes=True)
        complete_notes(notes)

        # After tagging: freeze the fixture and open `next` with an empty step.
        self._post_release("0.1.1")
        self.assertTrue(app_release.fixture_is_complete(app_release.fixture_bundle_path(self.root, "0.1.1")))
        chain, migs, keys_snap = app_release.read_data_version(self.root)
        self.assertEqual(chain, ["0.1.0", "0.1.1", "next"])
        self.assertEqual(migs, ["Migration_0_1_0_to_0_1_1", "Migration_0_1_1_to_Next"])
        self.assertEqual(keys_snap, "VNext")
        self.assertEqual(app_release.check(self.root), ("0.1.1", 2))
        # Running it again is refused: the release is no longer at the end of the chain.
        with self.assertRaisesRegex(ValueError, "不一致"):
            self._post_release("0.1.1")

        # The empty step gets the number of the next release.
        app_release.prepare(self.root, "0.2.0")
        complete_notes(app_release.notes_path(self.root, "0.2.0"))
        self.assertEqual(app_release.check(self.root, "v0.2.0", require_notes=True), ("0.2.0", 3))
        chain, migs, _ = app_release.read_data_version(self.root)
        self.assertEqual(chain, ["0.1.0", "0.1.1", "0.2.0"])
        self.assertEqual(migs, ["Migration_0_1_0_to_0_1_1", "Migration_0_1_1_to_0_2_0"])

    def test_prepare_without_post_release_scaffolds_an_empty_step(self):
        app_release.prepare(self.root, "0.1.1")
        complete_notes(app_release.notes_path(self.root, "0.1.1"))
        self._post_release("0.1.1")
        # Undo the opened `next`, as if post-release had only frozen the fixture.
        dv = self.root / app_release.DATA_VERSION_FILE
        dv.write_text(dv.read_text(encoding="utf-8")
                      .replace(', "next"]', "]")
                      .replace("        Migration_0_1_1_to_Next.migration,\n", "")
                      .replace("VNext.settingsKeys", "V0_1_1.settingsKeys"), encoding="utf-8")
        (self.root / app_release.SNAPSHOTS_DIR / "VNext.swift").unlink()
        (self.root / app_release.MIGRATIONS_DIR / "Migration_0_1_1_to_Next.swift").unlink()
        self.assertEqual(app_release.check(self.root), ("0.1.1", 2))
        app_release.prepare(self.root, "0.1.2")
        complete_notes(app_release.notes_path(self.root, "0.1.2"))
        self.assertEqual(app_release.check(self.root, "v0.1.2", require_notes=True), ("0.1.2", 3))
        _, migs, _ = app_release.read_data_version(self.root)
        self.assertEqual(migs, ["Migration_0_1_0_to_0_1_1", "Migration_0_1_1_to_0_1_2"])

if __name__ == "__main__":
    unittest.main()
