# Olympus Coder Workspaces

One source publishes four focused Kubernetes workspace templates. The `profile`
and `image` Terraform variables are fixed per template version; developers only
see the relevant resource, storage, and GPU parameters. A fifth,
`container-forge`, is published from its own source because it also provisions
a disposable image-builder pod in the isolated `coder-forge` namespace.

| Template | Profile | Purpose | Default storage |
| --- | --- | --- | --- |
| `olympus-linux` | `linux` | Lightweight everyday Linux development | Fast SSD, 2 replicas |
| `olympus-agent` | `agent` | Autonomous agents with Codex, Claude Code, OpenCode, Prime Agent, and Reasonix | Fast SSD, 2 replicas |
| `olympus-gpu` | `gpu` | CUDA 12.6 PyTorch development with JupyterLab and persistent model/kernel caches | Fast SSD, 2 replicas |
| `olympus-build` | `build` | Large builds and caches pinned to the 7810 | Bulk HDD, 1 replica + backup |

Persistent home volumes receive scheduled Longhorn backups to Cloudflare R2.
The creation form is ordered as repository, compute, storage, placement, and
GPU. CPU, memory, and disk capacity use sliders; storage, node placement, and
GPU use visual choices with descriptions and icons. Each template also offers
three one-click presets ranging from its normal default to an Atlas-backed heavy
configuration. Presets leave the GitHub repository selector editable.

CPU-only workspaces can use automatic Kubernetes scheduling or pin themselves
to Atlas, the 5810, or the 7810. GPU selection overrides CPU placement and pins
the workspace to the exact physical card:

- Quadro M4000, 8 GiB, on `precision-5810-01`
- Quadro P2000, 5 GiB, on `precision-7810-01`
- Tesla P40, 24 GiB, on `atlas`
- No GPU, with normal Kubernetes placement

GPU selection adds the `nvidia` RuntimeClass, an `nvidia.com/gpu: 1` limit, and
a hostname node selector. The runtime class makes Talos containerd inject the
assigned device and driver libraries; the selector prevents Kubernetes from
silently assigning a different physical card.

The catalog uses a distinct built-in Coder icon for each template: Ubuntu for
Linux, OpenAI for Agent, PyTorch for GPU, Code for Build, and Container for
Forge. The publishing helper reapplies display names, descriptions, and icons
after every push so presentation does not drift from GitOps.

Every template can start from a GitHub repository. The creation form provides a
searchable dropdown of repositories available through the Olympus GitHub App;
Coder requests GitHub authorization if needed, clones the selection into
`/home/coder/project/<repository>`, and opens every editor and agent in that
directory. Choose **Empty project** to use `/home/coder/project` without a clone.

The dropdown also offers **Create new GitHub repository** and **Fork public OSS
repository**. Enter the requested repository name or upstream GitHub URL, create
the workspace, then use the GitHub action tile to approve the operation in the
signed-in browser. A non-blocking startup task waits for the repository and
clones it automatically into the normal project directory. Keep the prefilled
repository name when confirming the action; restart the workspace to retry if
the 15-minute watcher expires. The form only shows the repository-name field
for Create and the upstream-URL field for Fork.

The browser confirmation is deliberate. GitHub requires Administration-write
for a GitHub App to create repositories or forks, and that same permission can
delete repositories. Olympus does not grant it. The existing short-lived App
token remains limited to normal repository work while the signed-in GitHub page
performs the one privileged creation action.

Coder intentionally does not fetch external data while rendering dynamic
parameters. `Publish-CoderTemplates.ps1` therefore reads the current repository
list from the authenticated GitHub CLI and injects it as a template variable
while publishing all five templates. The generated catalog is held only in a
temporary file and is never written into this public Git repository, so private
repository names do not leak into Git history. Archived repositories are omitted
unless the helper is called with `-IncludeArchived`.

Git authentication uses Coder's `github` external-auth provider and short-lived
GitHub App user tokens. Git operations receive credentials through Coder's
askpass helper, and the `olympus-agent` profile wraps `gh` so GitHub CLI commands
receive a fresh token without saving it to the workspace. The GitHub App
deliberately has no repository Administration permission, so agents cannot
delete repositories or change their core settings.

`olympus-agent` exposes the official Coder integrations for Codex and Claude
Code, plus persistent launcher tiles for OpenCode CLI, Prime Agent, Reasonix
CLI, and Reasonix Desktop. Node.js 24.18.1 LTS, OpenCode 1.18.14, checksum-
verified Prime Agent 0.7.0, and Reasonix 1.19.1 are installed into the
persistent home directory without requiring root privileges. Prime Agent sees
Coder's `DEEPSEEK_API_KEY` secret directly and stores only an environment-
variable reference in `~/.prime/agent/auth.json`; the key value is not copied
into that file. Its daemon state, sessions, IPython runtime, memories, and
skills remain under the persistent home volume. Prime lazily prepares its
IPython runtime on first use so template startup is not blocked by that larger
one-time download.

The five CLI launcher buttons enter named Zellij `v0.44.3` sessions, so closing
and reopening a browser terminal reattaches to the same running agent while the
workspace stays started. A workspace stop, update, or pod reschedule still ends
live processes; files and agent history on the Longhorn home volume persist for
normal resume afterward. Reasonix Desktop starts `reasonix serve` in the
selected repository at `127.0.0.1:8787` and exposes it only through an
owner-only Coder application. Its sessions, configuration, memory, and
checkpoints use the same persistent `~/.reasonix` state as Reasonix CLI.
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

Every template has an owner-only **Web Preview** card whose port is selected at
workspace creation (3000, 5173, 8000, or 8080). The card intentionally has no
health check because the development server is optional; an idle preview port
must not degrade overall workspace health. Opening it before starting a server
can still return a normal proxy error. Any other listening port is available
through Coder's **Open Ports** view. The wildcard route is
`https://<port>--main--<workspace>--<owner>.jacob-neel.dev`; it reaches Coder
through the shared `olympus-access` Cloudflare Tunnel and still requires the
normal Coder/Authentik login.

At each workspace start, the public-safe `olympus-workspace` Agent Skill is
refreshed from this repository into `~/.agents/skills`. Compatibility links and
small global instruction blocks make it available to Codex, Claude Code,
OpenCode, Prime Agent, and Reasonix. Prime Agent natively discovers the
canonical `~/.agents/skills` directory. The same installer provides
`olympus-preview`, which
prints the exact authenticated URL for any requested port.

`olympus-gpu` uses the official PyTorch 2.13.0 CUDA 12.6 runtime image. CUDA
12.6 is intentional: unlike CUDA 13, it retains binary support for both the
Maxwell M4000 and Pascal P2000. Hugging Face, Torch, extension, Matplotlib, and
Jupyter caches live on the persistent home volume.

## Publishing

Authenticate both CLIs, then run the publishing helper whenever repository
access changes or new repositories are created. The three built-in repository
actions leave room for at most 61 catalog repositories:

```powershell
gh auth login
coder login https://coder.jacob-neel.dev
.\Publish-CoderTemplates.ps1
```

Normal workspace Kubernetes permissions remain confined to `coder`. Container
Forge uses the separate `coder-forge` namespace and its own narrowly scoped
provisioner role; see [`../container-forge/README.md`](../container-forge/README.md).
