---
name: olympus-deploy
description: Package, deploy, migrate, update, troubleshoot, or remove an application on Jacob's Olympus Talos Kubernetes cluster through its public-safe Flux GitOps conventions. Use when a project needs an OCI image, Kubernetes manifests, persistent storage, GPU scheduling, Tailscale or public access, SOPS-encrypted secrets, Flux reconciliation, deployment verification, or cluster-aware operational guidance.
---

# Deploy to Olympus

Treat the homelab repository as the source of truth and Talos nodes as immutable.
Prefer GitOps changes over direct cluster mutation.

## Refresh canonical context

When this skill is installed from the canonical homelab checkout, run:

```powershell
python scripts/update_from_git.py
```

If it reports `UPDATED`, reread this file and any required references. The
script updates only a clean `main` checkout of `link2427/homelab`; it skips
standalone project copies, dirty trees, and non-main branches.

## Load the required context

Read [references/cluster-contract.md](references/cluster-contract.md) before
planning any deployment. Read
[references/deployment-patterns.md](references/deployment-patterns.md) when
authoring or modifying manifests, storage, exposure, secrets, or GPU placement.

Also read the target repository's own instructions and the current homelab
files that will be changed. Repository state overrides examples in this skill.

## Locate the GitOps repository

Use an existing checkout when available. Check, in order:

1. `HOMELAB_REPO` if defined.
2. `D:\repos\homelab` on Jacob's Windows workstation.
3. A sibling `homelab` checkout or `/home/coder/project/homelab` in Coder.
4. An explicitly supplied checkout.

If none exists, clone `https://github.com/link2427/homelab.git` only when the
task authorizes deployment or repository changes. Otherwise prepare a proposed
manifest patch without claiming it is deployed.

## Deployment workflow

1. Inspect the application.
   - Identify runtime, listen port, health endpoint, state, migrations,
     background workers, external dependencies, secrets, and architecture.
   - Determine whether an image already exists. Prefer a project-owned,
     reproducible Dockerfile and GHCR pipeline.
   - Never embed build-time or runtime secrets in an image or repository.

2. Choose the deployment shape.
   - Use a `Deployment` for stateless or single-writer applications that can
     tolerate pod replacement.
   - Use a `StatefulSet` only when stable identity or ordered storage is
     genuinely required.
   - Split databases, queues, and workers into distinct workloads when their
     lifecycle or scaling differs.
   - Default to one replica until the application is proven horizontally safe.

3. Choose exposure deliberately.
   - Default to `ClusterIP` when no user-facing access is requested.
   - Use a Tailscale `LoadBalancer` for private human access.
   - Treat public Cloudflare exposure, DNS changes, and Authentik policy as a
     separate security decision requiring explicit authorization.
   - Never create a public `NodePort` as a convenience shortcut.

4. Choose storage by data value and performance.
   - Use `longhorn-fast` for normal latency-sensitive application state.
   - Use `longhorn-resilient` for databases, identity, and difficult-to-rebuild
     state.
   - Use `longhorn-bulk` only for large rebuildable data and caches.
   - Do not create new claims on the legacy NFS provisioners; they are retained
     for rollback but currently scaled down.
   - Mark durable PVCs against Flux pruning and add the appropriate Longhorn R2
     recurring-backup labels.

5. Author GitOps resources.
   - Put applications under `apps/olympus/<app>/` with their own namespace and
     `kustomization.yaml`.
   - Add the directory to `apps/olympus/kustomization.yaml`.
   - Pin every image to an immutable digest or a specific version. Never add a
     new `latest` reference.
   - Set realistic requests, limits, readiness, liveness, and startup behavior.
   - Disable ServiceAccount token automount unless the application uses the
     Kubernetes API. Grant only namespace-scoped RBAC that it actually needs.
   - Prefer restricted pod security. Document and minimize every exception.

6. Encrypt secrets before staging.
   - Name secret files `*.secret.yaml` or `*credentials*.yaml` so `.sops.yaml`
     matches them.
   - Use SOPS with the repository's committed age recipient.
   - Confirm the Git diff contains only SOPS ciphertext and metadata—not
     plaintext values.
   - Never print, commit, paste into logs, or invent a credential.

7. Validate locally.

```powershell
kubectl kustomize .\apps\olympus
kubectl kustomize .\infrastructure\olympus
git diff --check
```

   Also validate the project image locally or in CI. Inspect `kubectl diff -k`
   when live access exists, but do not use `kubectl apply` as the deployment
   mechanism.

8. Publish intentionally.
   - Inspect the full diff and stage only files in scope.
   - Follow the repository's current branch/PR policy.
   - Remember that Flux watches `main`; a branch or open PR is not deployed.
   - Do not report success until the desired commit is on `main` and Flux has
     reconciled it.

9. Reconcile and verify.

```powershell
flux reconcile kustomization apps --with-source
flux get all -A
kubectl -n <namespace> rollout status deployment/<name> --timeout=5m
kubectl -n <namespace> get pods,svc,pvc
kubectl -n <namespace> get events --sort-by=.lastTimestamp
```

   Verify the health endpoint through the intended access path, inspect logs,
   confirm PVC binding and Longhorn replica health, and test the application's
   essential user flow. For migrations, retain rollback data until the new
   workload and its backups are validated.

## Interaction guardrails

- Begin with read-only inspection. Do not infer permission for unrelated live
  changes from a request to explain, review, or diagnose.
- Do not SSH into Talos nodes or install host packages. Use `talosctl` for
  Talos inspection and configuration only when the task explicitly requires it.
- Do not format, wipe, repartition, mount, or repurpose physical disks while
  deploying an application.
- Do not rely on Kubernetes `NetworkPolicy` as an enforced security boundary;
  Olympus currently uses plain Flannel without a policy engine.
- Avoid `hostPath`, `hostNetwork`, privileged pods, host devices, and broad
  cluster RBAC. Require an explicit reason and user authorization for them.
- Treat deletion of namespaces, PVCs, PVs, Longhorn volumes/backups, Flux
  objects, and CRDs as destructive. Resolve exact targets and preserve recovery.
- Preserve unrelated dirty-worktree changes and live workloads.

## Completion report

State separately:

- What changed in the application repository.
- What changed in the homelab repository.
- Whether the commit reached `main`.
- Whether Flux reconciled it.
- What live health, storage, access, and backup checks passed.
- Any remaining manual step, credential, DNS decision, or rollback copy.
