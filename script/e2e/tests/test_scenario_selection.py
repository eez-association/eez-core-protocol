"""Known unsupported scenarios stay explicit-only in the network default suite."""
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

    def test_all_excludes_unsupported_top_level_retry(self):
        for target in ("all", "all:2"):
            with self.subTest(target=target):
                jobs = self.jobs(target)
                self.assertIn("counter-1", jobs)
                self.assertFalse(any(job.startswith(RETRY + "-") for job in jobs))

    def test_explicit_selection_keeps_retry_available(self):
        self.assertEqual(self.jobs(RETRY), [RETRY + "-1"])
        self.assertEqual(self.jobs(RETRY + ":2"), [RETRY + "-1", RETRY + "-2"])
