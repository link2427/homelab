"""Pin the runner image after the publication workflow's tool checks pass."""
from pathlib import Path
import re
import sys

image = sys.argv[1]
if not re.fullmatch(r"ghcr.io/link2427/olympus-runner@sha256:[a-f0-9]{64}", image):
    raise SystemExit("Expected an immutable Olympus runner image reference")
manifest = Path("infrastructure/olympus/actions/runner-defaults.yaml")
updated, count = re.subn(
    r"ghcr.io/link2427/olympus-runner@sha256:[a-f0-9]{64}",
    image,
    manifest.read_text(),
)
if count != 2:
    raise SystemExit(f"Expected runner and init-container image pins, found {count}")
manifest.write_text(updated)
