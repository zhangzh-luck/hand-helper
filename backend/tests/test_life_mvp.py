"""Run the life suite in isolation from legacy tests' module-level DB setup."""

import os
import subprocess
import sys
from pathlib import Path


def test_life_scenario():
    root = Path(__file__).resolve().parents[1]
    subprocess.run(
        [sys.executable, "-m", "pytest", "tests/_life_scenario.py", "-q", "-p", "no:cacheprovider"],
        cwd=root,
        env={**os.environ, "PYTHONPATH": str(root)},
        check=True,
    )
