# Reliable Coder workspaces

Olympus Agent and Container Forge share an image with Codex, Claude Code,
OpenCode, Pi, Prime Agent, Reasonix, official DeepSeek Harness, OpenHands Agent
Canvas, and Grok Build. Linux, GPU, and Build keep their existing lean profiles.
All apps use native Coder cards, grouped into Development, Browser Agents,
Terminal Agents, Exports, and Maintenance. Browser apps remain owner-only.

## Startup and recovery

The image contains working tools and OpenHands' Python dependencies. Login,
editor startup, and service recovery do not require package registries. Named,
nonblocking Coder scripts start the services, configure local helpers, and check
releases independently. A registry failure is shown in Diagnostics without
preventing login.

The unprivileged supervisor restarts failed services, including cleaning up that
service's orphaned child processes after a launcher crash. It never resumes a
saved agent task. Terminal agents run in named Zellij sessions so a dropped
browser connection can reattach to the running session. Across a pod restart,
files, credentials, and saved histories persist; choose the task to resume.

DeepSeek currently requires a per-launch browser token. A loopback-only adapter
exchanges that token for DeepSeek's normal HttpOnly cookie after Coder has
authenticated the owner. It preserves the vendor's API/WebSocket authentication
and origin checks. Tokens are redacted from the adapter log. The DeepSeek card
uses its own subdomain; do not expose its port directly.

Grok Build is available as a terminal card and as the `Grok-Build` agent profile
in OpenHands. Use `grok login --device-auth` once if a Grok login is needed. Pick
that profile when starting a conversation. OpenHands' existing selected agent
and settings are preserved. No provider keys or paid requests are created by
setup or health tests.

## Updates

Coder checks all nine harnesses at startup and every 15 minutes. Each release is
installed in a separate directory, checked with its CLI and, where applicable,
its web/backend readiness endpoints, then atomically selected for new sessions.
Running sessions retain their original executable and dependencies. Restart a
browser service when its current task is finished to adopt a new version.

Major releases are staged for `olympus-adopt TOOL`. The image itself is rebuilt
daily and on runtime changes, tested offline, then published with immutable
image digests. Existing workspaces adopt template/image changes only when the
owner chooses to update/restart; the catalog publisher never creates workspace
builds or stops a workspace.

CLI releases live in `~/.local/share/olympus/tools`. A process lock serializes
updates; inherited shared leases protect files used by running sessions.
Cleanup preserves the selected version, previous version, pending major update,
recent releases, and active leases. Less than 3 GiB free prevents a new install.
Configuration snapshots before first launch of a new version retain the five
most recent per tool in `~/.local/state/olympus/recovery`, with mode 0600.

Useful commands:

```sh
olympus-doctor                    # selected/running/latest versions and errors
olympus-agent-update [tool]       # check releases now
olympus-services status
olympus-services restart reasonix # also: editor, exports, deepseek, openhands
olympus-rollback reasonix         # choose the previous validated installation
olympus-adopt reasonix            # adopt a staged major release
```

Rollback changes the executable used by new sessions. It does not overwrite
current configuration/history. Review the saved configuration archive before
restoring it, and stop the affected service first if a schema migration needs
undoing. Never replace a live database with an older copy.

## Repository catalog

The `coder-catalog` CronJob checks GitHub every 15 minutes. Its GitHub App can
read repository metadata only, including current and future personal
repositories. Its separate Coder account has the template-admin role. Keys are
SOPS encrypted in `publisher-credentials.secret.yaml`; the job has no Kubernetes
API token, runs as UID 1000, drops capabilities, and has a read-only root
filesystem. Rotate the Coder publisher token before its one-year expiry.

The Python publisher is shared with `template/Publish-CoderTemplates.ps1`.
It filters archived repositories, sorts deterministically, and suggests up to
60 repositories with an explicit URL option for any other repository. Catalog
values go directly to Coder, never into the public Git repository. Content and
configuration fingerprints avoid no-op template versions; commit activity alone
does not change the catalog. Failed imports preserve the active template.
Repository checkout contents are never pulled, reset, or overwritten by this job.

Check last successful refresh and errors with:

```sh
kubectl -n coder get cronjob coder-catalog
kubectl -n coder get jobs -l batch.kubernetes.io/job-name
kubectl -n coder logs job/JOB_NAME
```

## Rollout and validation

`publisher/images.json` is the source of image pins. Keep `promote_runtime` false
during the initial 24-hour Agent/Forge canary. The publisher can validate new
production template versions while leaving their active versions unchanged.
Linux, GPU, and Build catalog refreshes continue normally.

Create canary templates with `publish.py --canary`. For an Agent recovery test,
`--canary-home-pvc` accepts an already cloned same-namespace home PVC. The source
workspace must never be passed as the recovery PVC: use a distinct Longhorn
CSI clone, owned by the same user. This administrator-only option is empty in
normal templates. The ordinary unused home claim created for that test workspace
can be removed along with the test workspace after the canary is retired.

Acceptance covers fresh and restored homes, offline web/backend startup,
supervised launcher crashes, dropped terminal connections, Grok ACP initialize,
update failures/locks/low disk/checksums/major migrations/rollback, deterministic
catalog imports, and no workspace changes during publication. A canary passing
startup alone is insufficient: inspect all app health, startup script errors,
restart counts, volume health, and the existing production workspace throughout
the soak. Production promotion only changes the active template version.

## Upstream references

- [Coder scripts and startup behavior](https://coder.com/docs/admin/templates/extending-templates)
- [Coder template APIs](https://coder.com/docs/reference/api/templates)
- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
- [OpenHands ACP agents](https://github.com/OpenHands/OpenHands/blob/main/docs/ACP_AGENTS.md)
- [Grok CLI](https://docs.x.ai/build/cli/reference)
- [Longhorn PVC cloning](https://longhorn.io/docs/1.11.1/snapshots-and-backups/csi-volume-clone/)
