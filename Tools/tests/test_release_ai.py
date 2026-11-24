"""Tests for Tools/release_ai.py and how prepare uses it."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import dictionary_release as release  # noqa: E402
import release_ai  # noqa: E402
from test_dictionary_release import write_csv  # noqa: E402

TEMPLATE = (
    "# 词典包 dict-2026.12.01 发布说明\n\nRELEASE_TODO：人工审阅。\n\n"
    "## 主要变更\n\nRELEASE_TODO：填写变更。\n\n"
    "## 词典包\n\n| 包 | 分组 | 条目 | 变化 |\n|---|---|---|---|\n| 核心词典 | core | 10 | +2 |\n\n"
    "## 上线\n\n推送 tag 后由 Actions 发布。\n"
)
TARGET = Path("docs/releases/dict-2026.12.01.md")
# Patching release_ai.subprocess.run patches the module everyone shares; git still needs the real one.
REAL_RUN = subprocess.run


def clean_environment():
    return mock.patch.dict(os.environ, {key: value for key, value in os.environ.items() if key not in release_ai.ENV_KEYS},
                           clear=True)


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.env = clean_environment()
        self.env.start()

    def tearDown(self):
        self.env.stop()
        shutil.rmtree(self.root)

    def test_dotenv_quotes_comments_and_environment_precedence(self):
        text = ('SOMETHING_ELSE="secret-$()"\n'
                'export RELEASE_AI_PROVIDER="claude" # chosen CLI\n'
                "RELEASE_AI_MODEL='literal-$(model)'\n"
                "RELEASE_AI_TIMEOUT_SECONDS=42\n")
        (self.root / ".env").write_text(text)
        self.assertEqual(release_ai.load_config(self.root), release_ai.AIConfig("claude", "literal-$(model)", 42))
        with mock.patch.dict(os.environ, {"RELEASE_AI_PROVIDER": "codex"}):
            self.assertEqual(release_ai.load_config(self.root).provider, "codex")
        self.assertEqual((self.root / ".env").read_text(), text)

    def test_invalid_config_fails_explicitly(self):
        for line in ("RELEASE_AI_PROVIDER=unknown", "RELEASE_AI_TIMEOUT_SECONDS=0", "RELEASE_AI_TIMEOUT_SECONDS=no",
                     'RELEASE_AI_MODEL="unclosed'):
            (self.root / ".env").write_text(line)
            with self.subTest(line=line), self.assertRaises(ValueError):
                release_ai.load_config(self.root)

    def test_missing_env_uses_template_mode(self):
        self.assertEqual(release_ai.load_config(self.root), release_ai.AIConfig("none", "", 600))


class GitRepoTestCase(unittest.TestCase):
    """A small repository with a dictionary release tag, a later commit and uncommitted changes."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.env = clean_environment()
        self.env.start()
        self.git("init", "-q")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release@example.invalid")
        (self.root / "Tools").mkdir()
        (self.root / "Tools/build-dictionary.py").write_text("rule = 1\n")
        self.git("add", ".")
        self.git("commit", "-qm", "initial")
        self.git("tag", "dict-2026.11.18.1")
        (self.root / "Tools/build-dictionary.py").write_text("rule = 2\n")
        self.git("commit", "-qam", "keep inflections in core")

    def tearDown(self):
        self.env.stop()
        shutil.rmtree(self.root)

    def git(self, *args):
        REAL_RUN(["git", *args], cwd=self.root, check=True, capture_output=True, text=True)


class BaseTagTests(GitRepoTestCase):
    def test_base_tag_defaults_to_the_previous_release(self):
        self.assertEqual(release_ai.validate_base_tag(self.root, "2026.11.18.1"), "dict-2026.11.18.1")

    def test_missing_or_malformed_base_tag_stops_before_generation(self):
        with self.assertRaisesRegex(ValueError, "tag 存在"):
            release_ai.validate_base_tag(self.root, "2026.11.30")
        with self.assertRaisesRegex(ValueError, "--base-tag"):
            release_ai.validate_base_tag(self.root, "2026.11.30", "v1.0.0")
        with self.assertRaisesRegex(ValueError, "首次发布"):
            release_ai.validate_base_tag(self.root, None)
        self.assertEqual(release_ai.validate_base_tag(self.root, None, "dict-2026.11.18.1"), "dict-2026.11.18.1")


class GenerateTests(GitRepoTestCase):
    def setUp(self):
        super().setUp()
        self.which = mock.patch.object(release_ai.shutil, "which", lambda name: f"/bin/{name}")
        self.which.start()

    def tearDown(self):
        self.which.stop()
        super().tearDown()

    def generate(self, provider, run):
        with mock.patch.object(release_ai.subprocess, "run", run):
            return release_ai.generate(self.root, "2026.12.01", "2026.11.18.1",
                                       release_ai.AIConfig(provider, "custom-model", 42), template=TEMPLATE, target=TARGET)

    def test_agent_runs_in_the_repository_and_writes_the_notes(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                path = self.root / TARGET
                content = TEMPLATE.replace("RELEASE_TODO：填写变更。", "- 常用词的变形都留在核心词典。")
                calls = []

                def run(command, **kwargs):
                    if command[0] == "git":
                        return REAL_RUN(command, **kwargs)
                    calls.append((command, kwargs))
                    self.assertEqual(path.read_text(), TEMPLATE)
                    path.write_text(content)
                    stdout = "done" if provider == "codex" else json.dumps({"is_error": False})
                    return subprocess.CompletedProcess(command, 0, stdout, "")

                self.assertEqual(self.generate(provider, run), content)
                self.assertEqual(path.read_text(), content)
                command, kwargs = calls[0]
                self.assertEqual((kwargs["timeout"], kwargs["cwd"]), (42, self.root))
                self.assertIn(TARGET.as_posix(), kwargs["input"])
                self.assertIn("dict-2026.11.18.1", kwargs["input"])
                self.assertIn("custom-model", command)
                if provider == "codex":
                    self.assertEqual(command[command.index("--sandbox") + 1], "workspace-write")
                    self.assertEqual(command[command.index("--cd") + 1], str(self.root))
                else:
                    self.assertTrue({"Read", "Write", "Bash(git:*)"} <= set(command))
                path.unlink()

    def test_review_marker_is_restored_when_the_agent_drops_it(self):
        def run(command, **kwargs):
            if command[0] == "git":
                return REAL_RUN(command, **kwargs)
            (self.root / TARGET).write_text(TEMPLATE.replace("RELEASE_TODO：人工审阅。\n\n", "")
                                            .replace("RELEASE_TODO：填写变更。", "- 变更。"))
            return subprocess.CompletedProcess(command, 0, "done", "")

        self.assertIn("RELEASE_TODO", self.generate("codex", run))

    def test_a_failed_claude_run_reports_its_reason(self):
        def run(command, **kwargs):
            if command[0] == "git":
                return REAL_RUN(command, **kwargs)
            envelope = {"is_error": True, "result": "API Error: EPROTO: The TLS handshake failed."}
            return subprocess.CompletedProcess(command, 1, json.dumps(envelope), "secret stderr")

        with self.assertRaisesRegex(ValueError, "API Error: EPROTO") as raised:
            self.generate("claude", run)
        self.assertNotIn("secret", str(raised.exception))
        self.assertFalse((self.root / TARGET).exists())

    def test_a_failed_codex_run_reports_its_reason(self):
        def run(command, **kwargs):
            if command[0] == "git":
                return REAL_RUN(command, **kwargs)
            event = {"type": "turn.failed", "error": {"message": '404 Not Found: Model "old-model" is not supported'}}
            return subprocess.CompletedProcess(command, 1, json.dumps(event) + "\n", "secret stderr")

        with self.assertRaisesRegex(ValueError, '404 Not Found: Model "old-model"') as raised:
            self.generate("codex", run)
        self.assertNotIn("secret", str(raised.exception))
        self.assertFalse((self.root / TARGET).exists())

    def test_failed_or_malformed_drafts_are_removed(self):
        outcomes = {
            "no change": lambda path: None,
            "wrong title": lambda path: path.write_text("wrong title\n"),
            "empty section": lambda path: path.write_text("# 词典包 dict-2026.12.01 发布说明\n\n## 主要变更\n"),
            "exit code": lambda path: "fail",
            "timeout": lambda path: "timeout",
            "claude error": lambda path: "claude-error",
        }
        for name, act in outcomes.items():
            with self.subTest(name):
                def run(command, **kwargs):
                    if command[0] == "git":
                        return REAL_RUN(command, **kwargs)
                    outcome = act(self.root / TARGET)
                    if outcome == "timeout":
                        raise subprocess.TimeoutExpired(command, 42)
                    if outcome == "claude-error":
                        (self.root / TARGET).write_text(TEMPLATE.replace("RELEASE_TODO：填写变更。", "- x"))
                        return subprocess.CompletedProcess(command, 0, json.dumps({"is_error": True}), "")
                    return subprocess.CompletedProcess(command, 1 if outcome == "fail" else 0, "{}", "")

                with self.assertRaises(ValueError):
                    self.generate("claude" if name == "claude error" else "codex", run)
                self.assertFalse((self.root / TARGET).exists())

    def test_existing_notes_are_never_replaced(self):
        (self.root / TARGET).parent.mkdir(parents=True)
        (self.root / TARGET).write_text("kept\n")
        with self.assertRaisesRegex(ValueError, "已存在"):
            self.generate("codex", lambda command, **kwargs: REAL_RUN(command, **kwargs) if command[0] == "git"
                          else self.fail("agent should not run"))
        self.assertEqual((self.root / TARGET).read_text(), "kept\n")


class PrepareWithAgentTests(GitRepoTestCase):
    """prepare builds first, lets the agent write the notes, and only then updates the release files."""

    def setUp(self):
        super().setUp()
        csv_path = self.root / release.SOURCE_CSV
        csv_path.parent.mkdir(parents=True)
        write_csv(csv_path)
        source = {"name": "ECDICT", "commit": "a" * 40, "url": release.source_url("a" * 40),
                  "sha256": release.sha256_file(csv_path)}
        (self.root / release.RELEASE).parent.mkdir(parents=True)
        (self.root / release.RELEASE).write_text(json.dumps({"version": "2026.11.18.1", "source": source}))
        (self.root / release.CORE).parent.mkdir(parents=True)
        (self.root / ".env").write_text("RELEASE_AI_PROVIDER=claude\n")
        self.release_before = (self.root / release.RELEASE).read_text()

    def test_a_failing_agent_leaves_the_release_untouched(self):
        with mock.patch.object(release_ai, "generate", side_effect=ValueError("claude 生成失败")):
            with self.assertRaisesRegex(ValueError, "生成失败"):
                release.prepare(self.root, "2026.12.01")
        self.assertEqual((self.root / release.RELEASE).read_text(), self.release_before)
        self.assertFalse((self.root / release.CORE).exists())

    def test_the_agent_gets_a_template_with_count_changes(self):
        seen = {}

        def generate(root, version, previous, config, *, template, target, base_tag=None):
            seen.update(template=template, target=target, previous=previous)
            (root / target).parent.mkdir(parents=True, exist_ok=True)
            (root / target).write_text(template)
            return template

        with mock.patch.object(release_ai, "generate", generate):
            release.prepare(self.root, "2026.12.01")
        self.assertEqual(seen["target"], Path("docs/releases/dict-2026.12.01.md"))
        self.assertEqual(seen["previous"], "2026.11.18.1")
        self.assertIn("| 条目 | 变化 |", seen["template"])
        self.assertIn("以下草稿由本地 AI CLI", seen["template"])
        self.assertEqual(json.loads((self.root / release.RELEASE).read_text())["version"], "2026.12.01")

    def test_dry_run_checks_the_base_tag_without_building(self):
        self.git("tag", "-d", "dict-2026.11.18.1")
        with self.assertRaisesRegex(ValueError, "tag 存在"):
            release.prepare(self.root, "2026.12.01", dry_run=True)
        self.assertFalse((self.root / release.BUILD).exists())


if __name__ == "__main__":
    unittest.main()
