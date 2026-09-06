"""Deploy a matched, verified runner/sidecar pair through Flux."""
from pathlib import Path
import re
import sys
import yaml

runner, dind = sys.argv[1:]
for image, name in [(runner, "olympus-runner"), (dind, "olympus-runner-dind")]:
    if not re.fullmatch(r"ghcr.io/link2427/" + name + r"@sha256:[a-f0-9]{64}", image):
        raise SystemExit("Expected an immutable Olympus image reference")
manifest = Path("infrastructure/olympus/actions/runner-defaults.yaml")
document = yaml.safe_load(manifest.read_text())
values = yaml.safe_load(document["data"]["values.yaml"])
spec = values["template"]["spec"]
if [c["name"] for c in spec["containers"]] != ["runner"]:
    raise SystemExit("Unexpected runner pod template")
spec["containers"][0]["image"] = runner
spec["initContainers"] = [c for c in spec["initContainers"] if c["name"] != "init-dind-externals"]
if [c["name"] for c in spec["initContainers"]] != ["dind"]:
    raise SystemExit("Unexpected sidecar template")
sidecar = spec["initContainers"][0]
sidecar["image"] = dind
sidecar["volumeMounts"] = [m for m in sidecar["volumeMounts"] if m["name"] != "dind-externals"]
spec["volumes"] = [v for v in spec["volumes"] if v["name"] != "dind-externals"]
document["data"]["values.yaml"] = yaml.safe_dump(values, sort_keys=False)
class ReadableDumper(yaml.SafeDumper):
    pass
def represent_string(dumper, value):
    return dumper.represent_scalar("tag:yaml.org,2002:str", value, style="|" if "\n" in value else None)
ReadableDumper.add_representer(str, represent_string)
manifest.write_text(yaml.dump(document, Dumper=ReadableDumper, sort_keys=False))
