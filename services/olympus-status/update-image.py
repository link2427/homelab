"""Pin both containers after CI tests the published image. Supports first bootstrap."""
from pathlib import Path
import re
import sys

image = sys.argv[1]
if not re.fullmatch(r"ghcr.io/link2427/olympus-status@sha256:[a-f0-9]{64}", image):
    raise SystemExit("Expected immutable Olympus status image")
path = Path("apps/olympus/olympus-status/resources.yaml")
if path.exists():
    content, count = re.subn(r"(?m)^(\s+image: )ghcr.io/link2427/olympus-status@sha256:[a-f0-9]{64}$", lambda m: m[1] + image, path.read_text())
    if count != 2:
        raise SystemExit(f"Expected exactly 2 image references, got {count}")
    path.write_text(content)
else:
    print("Bootstrap image ready; add the initial GitOps resources with this digest.")
