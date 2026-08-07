---
name: olympus-workspace
description: Operate inside an Olympus Coder workspace, including persistent files, browser-accessible development previews, artifact exports, GitHub access, and optional GitOps/Cloudflare deployment. Use when an agent needs to run or expose a local web app, give Jacob a downloadable artifact, explain workspace URLs or persistence, or promote a workspace project into the Olympus Kubernetes cluster.
---

# Olympus Workspace

Treat the current machine as an isolated Coder workspace running as a Kubernetes
pod in the Olympus Talos cluster. Keep development inside the workspace and use
the managed paths and routes below instead of inventing another access method.

## Workspace contract

- Work under `/home/coder/project`; the selected GitHub repository normally lives
  in a child directory of that path.
- `/home/coder` is a persistent Longhorn volume. Files and agent state survive a
  normal workspace stop/start. Deleting the Coder workspace is destructive to its
  workspace volume, so export or commit anything that must outlive deletion.
- The Coder control plane is `https://coder.jacob-neel.dev`.
- GitHub authentication is supplied by Coder external auth. Use `gh` and normal
  HTTPS Git commands; never print or persist the short-lived token yourself.
- Read the active values from `OLYMPUS_CODER_OWNER`,
  `OLYMPUS_CODER_WORKSPACE`, `OLYMPUS_CODER_AGENT`, and
  `OLYMPUS_CODER_WILDCARD_DOMAIN` instead of guessing names.

## Preview a development website

1. Run the application in the workspace and listen on a known port. Prefer
   `0.0.0.0` for framework dev servers. If a process runs in a nested container or
   sidecar, publish its port back to the workspace network first.
2. Print the authenticated browser URL with `olympus-preview PORT`.
3. Give Jacob that HTTPS URL. It works from any browser through the shared
   Cloudflare Tunnel and requires the normal Coder login.

The generic route is:

```text
https://<port>--main--<workspace>--<owner>.jacob-neel.dev
```

Examples:

```bash
npm run dev -- --host 0.0.0.0 --port 5173
olympus-preview 5173

python -m http.server 8000 --bind 0.0.0.0
olympus-preview 8000
```

Coder also detects listening ports under **Open Ports**. The template's **Web
Preview** card points at its selected primary preview port. The optional card
does not participate in workspace health, so it remains neutral until a server
is started; opening it while the port is idle can still return a proxy error.
Preview routes stop when the workspace stops and are owner-only; do not weaken
sharing or add an unauthenticated tunnel unless Jacob explicitly requests it.

## Use Reasonix Desktop or CLI

In agent-capable templates, **Reasonix Desktop** is the preferred browser UI and
**Reasonix CLI** remains available as a persistent Zellij terminal. The desktop
server starts automatically in the selected repository on
`127.0.0.1:8787`; do not start a second server or expose that port through a
separate tunnel. Open it through the owner-only Coder app card.

Both interfaces use the same persistent `~/.reasonix` configuration, provider
keys, sessions, memory, and checkpoints. Stopping the workspace terminates the
server and CLI process, but their saved state survives on the Longhorn home
volume and resumes after the workspace starts again.

## Use Prime Agent

**Prime Agent** opens in a persistent Zellij terminal rooted in the selected
repository. Prime Agent also runs its own background daemon, so closing the
browser terminal does not stop active sessions while the workspace remains
started. Its state lives under `~/.prime`, and this skill is discovered through
the canonical `~/.agents/skills` directory. A managed `uv` installation in
`~/.local/bin` supports Prime's lazy IPython-kernel bootstrap; do not replace it
with a root-owned installation or remove it from `PATH`.

Coder supplies `DEEPSEEK_API_KEY` to the agent environment. The managed
`~/.prime/agent/auth.json` entry refers to that environment-variable name and
does not contain the secret value. Use the built-in DeepSeek provider without
printing, copying, exporting, or committing the key. A workspace stop or update
ends live daemon processes, but the Longhorn home volume retains Prime Agent's
sessions and harness state for normal resume.

## Use an assigned GPU

When the workspace metadata shows a selected GPU, Kubernetes pins the pod to
that GPU's physical node, requests one `nvidia.com/gpu`, and uses the `nvidia`
RuntimeClass. GPU access does not require `sudo`, privileged mode, or additional
Linux capabilities. The base Agent image may not include `nvidia-smi`; use the
project's CUDA userspace environment and application-level CUDA smoke test.

If `NVIDIA_VISIBLE_DEVICES` is set but `/dev/nvidia*` is absent, report a Coder
template/runtime integration failure to the cluster owner. Do not attempt to
fix it with `sudo`, host package installation, manual device mounts, or broader
container privileges.

## Export downloadable artifacts

Copy a completed file or directory into the persistent export area:

```bash
olympus-export SOURCE [DOWNLOAD_NAME]
```

Then direct Jacob to the **Exports** card on the workspace page. Its direct route
is:

```text
https://coder.jacob-neel.dev/@<owner>/<workspace>.main/apps/exports/
```

Use a short, descriptive download name. Do not place credentials, `.env` files,
private keys, or provider tokens in `/home/coder/exports`. For a directory with
many files, create a `.tar.gz` or `.zip` first so the browser downloads one
artifact. Container Forge's `container-build` command already creates a complete
offline bundle under `/home/coder/exports`.

## Choose preview or deployment

Use a Coder preview for development servers, demos, test APIs, and other
workspace-scoped work. It is already routed through the cluster's shared
`olympus-access` Cloudflare Tunnel; do not launch a separate `cloudflared`
process.

Use a normal Olympus GitOps deployment when the service must remain available
after the workspace stops, needs a stable hostname, or should be operated as a
cluster workload. When available, invoke the `olympus-deploy` skill. Otherwise,
follow the public-safe Flux conventions in `link2427/homelab`:

1. Build and publish an OCI image.
2. Add Kubernetes manifests under the appropriate `apps/olympus/` directory.
3. Store secrets only through the repository's SOPS workflow.
4. Add a cluster-internal Service URL such as
   `http://<service>.<namespace>.svc.cluster.local:<port>`.
5. Add a dedicated `https://<app>.jacob-neel.dev` Cloudflare hostname only when
   Jacob explicitly asks for public access, and put Authentik or application
   authentication in front of sensitive interfaces.
6. Commit, push, reconcile Flux, and verify the deployed endpoint.

Never treat a preview URL as production, expose a Kubernetes dashboard or admin
surface anonymously, or bypass GitOps for a long-lived workload.

## Diagnose access

- Confirm the process is still running and listening on the requested port.
- Use `curl -I http://127.0.0.1:<port>` from the workspace before blaming Coder.
- For a nested container, confirm its port is published on the workspace network.
- Re-run `olympus-preview <port>` and use the exact returned hostname.
- A Coder login redirect is expected for an unauthenticated browser.
- A stopped workspace intentionally has no working preview.
