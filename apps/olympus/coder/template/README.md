# Olympus Coder Workspaces

One source publishes four focused Kubernetes workspace templates. The `profile`
and `image` Terraform variables are fixed per template version; developers only
see the relevant resource, storage, and GPU parameters.

| Template | Profile | Purpose | Default storage |
| --- | --- | --- | --- |
| `olympus-linux` | `linux` | Lightweight everyday Linux development | Fast SSD, 2 replicas |
| `olympus-agent` | `agent` | Autonomous agents with Codex, Claude Code, OpenCode, and Reasonix | Fast SSD, 2 replicas |
| `olympus-gpu` | `gpu` | CUDA 12.6 PyTorch development with JupyterLab and persistent model/kernel caches | Fast SSD, 2 replicas |
| `olympus-build` | `build` | Large builds and caches pinned to the 7810 | Bulk HDD, 1 replica + backup |

All persistent home volumes receive daily Longhorn backups to Atlas. CPU,
memory, home size, and storage tier are selectable. GPU-capable profiles can
select the exact physical card:

- Quadro M4000, 8 GiB, on `precision-5810-01`
- Quadro P2000, 5 GiB, on `precision-7810-01`
- Tesla P40, 24 GiB, on `atlas`
- No GPU, with normal Kubernetes placement

GPU selection adds both the `nvidia.com/gpu: 1` limit and a hostname node
selector, so Kubernetes cannot silently assign the other card.

Every template can start from a GitHub repository. The creation form provides a
searchable dropdown of repositories available through the Olympus GitHub App;
Coder requests GitHub authorization if needed, clones the selection into
`/home/coder/project/<repository>`, and opens every editor and agent in that
directory. Choose **Empty project** to use `/home/coder/project` without a clone.

Coder intentionally does not fetch external data while rendering dynamic
parameters. `Publish-CoderTemplates.ps1` therefore reads the current repository
list from the authenticated GitHub CLI and injects it as a template variable
while publishing all four versions. The generated catalog is held only in a
temporary file and is never written into this public Git repository, so private
repository names do not leak into Git history. Archived repositories are omitted
unless the helper is called with `-IncludeArchived`.

Git authentication uses Coder's `github` external-auth provider and short-lived
GitHub App user tokens. Git operations receive credentials through Coder's
askpass helper, and the `olympus-agent` profile wraps `gh` so GitHub CLI commands
receive a fresh token without saving it to the workspace. The GitHub App
deliberately has no repository Administration permission, so agents cannot
delete repositories or change their core settings.

`olympus-agent` exposes the official Coder integrations for Codex, Claude Code,
and OpenCode. It provides correctly branded launcher tiles for Codex, Claude
Code, OpenCode CLI, and Reasonix, plus the OpenCode web interface. Node.js
24.18.1 LTS, Reasonix 1.19.1, and AgentAPI are installed into the persistent
home directory without requiring root privileges, so all four tools survive
workspace rebuilds and keep their user-level configuration with the workspace.
Reasonix runs with `sandbox.bash = "off"` because Talos deliberately disables
the nested user namespaces Bubblewrap requires and the Coder namespace rejects
unconfined seccomp profiles. The enclosing workspace remains a non-root pod
with every Linux capability dropped, RuntimeDefault seccomp, Coder auth, and
namespace-scoped RBAC; this keeps Bash functional without weakening cluster
Pod Security.

The owner-only **Exports** app serves `/home/coder/exports` through Coder's
authenticated application proxy. It listens only on the workspace loopback
interface, so it cannot be reached directly from the cluster network. Agents
can place a finished file or directory in the download area with
`olympus-export SOURCE [DOWNLOAD_NAME]`; the workspace owner can then preview or
download it from a normal browser after signing in to Coder. File Browser is
pinned to v2.63.5 and its release checksum is verified before installation.

`olympus-gpu` uses the official PyTorch 2.13.0 CUDA 12.6 runtime image. CUDA
12.6 is intentional: unlike CUDA 13, it retains binary support for both the
Maxwell M4000 and Pascal P2000. Hugging Face, Torch, extension, Matplotlib, and
Jupyter caches live on the persistent home volume.

## Publishing

Authenticate both CLIs, then run the publishing helper whenever repository
access changes or new repositories are created:

```powershell
gh auth login
coder login https://coder.jacob-neel.dev
.\Publish-CoderTemplates.ps1
```

Workspace Kubernetes permissions remain confined to the `coder` namespace.
