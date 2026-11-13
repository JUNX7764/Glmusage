import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class UIRefinementsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.binary = Path(cls.tmp.name) / "ui-refinements-tests"
        names = ("GLMPanelVisuals.swift", "GLMAnimatedTokenValue.swift", "GLMDeltaChip.swift")
        sources = [ROOT / "Sources" / name for name in names
                   if (ROOT / "Sources" / name).exists()]
        subprocess.run(["swiftc", "-target", "arm64-apple-macos13.0",
                        *map(str, sources),
                        str(ROOT / "tests/fixtures/ui-refinements/main.swift"),
                        "-o", str(cls.binary)], cwd=ROOT, check=True, timeout=120)

    def case(self, name):
        result = subprocess.run([str(self.binary), name], cwd=ROOT,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: " + name, result.stdout)

    def test_daily_corners(self):
        self.case("dailyCorners")

    def test_token_transition(self):
        self.case("tokenTransition")

    def test_delta_chip(self):
        self.case("deltaChip")

    def test_history_track(self):
        self.case("historyTrack")

    def test_distinct_symbols(self):
        self.case("distinctSymbols")
