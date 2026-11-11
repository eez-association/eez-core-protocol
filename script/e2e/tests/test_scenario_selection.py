"""Automatic selection includes every scenario, including previously excluded cases."""
from pathlib import Path
import subprocess
import unittest

REPO = Path(__file__).resolve().parents[3]
ORCHESTRATOR = REPO / "script/e2e/lib/orchestrator.sh"
RETRY = "localCounterRevertAndRetry"


class ScenarioSelectionTests(unittest.TestCase):
    def jobs(self, target):
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; expand_jobs "$2"; printf "%s\\n" "${JOB_NAMES[@]}"',
             "scenario-selection", str(ORCHESTRATOR), target],
            cwd=REPO, capture_output=True, text=True, timeout=15, check=True)
        return result.stdout.splitlines()

    def test_all_includes_every_scenario(self):
        scenarios = {
            path.parent.name
            for path in (REPO / "script/e2e/scenarios").rglob("E2E*.s.sol")
            if "shared" not in path.parts
        }
        for count in (1, 2):
            with self.subTest(count=count):
                jobs = self.jobs("all" if count == 1 else "all:2")
                expected = {
                    f"{name}-{index}"
                    for name in scenarios
                    for index in range(1, count + 1)
                }
                self.assertEqual(set(jobs), expected)
                self.assertEqual(len(jobs), len(expected))

    def test_explicit_selection_keeps_retry_available(self):
        self.assertEqual(self.jobs(RETRY), [RETRY + "-1"])
        self.assertEqual(self.jobs(RETRY + ":2"), [RETRY + "-1", RETRY + "-2"])
