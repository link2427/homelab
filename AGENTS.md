# Olympus operational instructions

Read `.ai-context/README.md` when present for private local handoff notes, then
verify its claims against live state. Keep it updated with decisions, commits,
validation results, blockers and rollback instructions. `.ai-context/` is
gitignored; never place secret values in its notes.

Read `skills/olympus-deploy/SKILL.md` and `docs/olympus-handbook.md` before cluster
changes. This repository's `main` branch is the Flux source of truth. Preserve
unrelated changes and workloads; use GitOps and SOPS-encrypted secrets. Verify
the applied revision and each affected application's live health after deployment.
