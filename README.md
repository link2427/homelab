# Olympus homelab GitOps

This repository is the GitOps source of truth for the Olympus Kubernetes cluster.
Flux watches `main` and reconciles the cluster entry point at
`clusters/olympus`.

## Repository layout

```text
clusters/olympus/          Cluster composition and Flux bootstrap manifests
infrastructure/olympus/    Cluster-wide controllers, storage, networking, and policy
apps/olympus/              User-facing workloads and their configuration
```

Reconciliation is ordered deliberately:

1. `flux-system` installs and updates Flux itself.
2. `infrastructure` reconciles cluster prerequisites.
3. `apps` reconciles workloads after infrastructure is healthy.

## Day-to-day workflow

Make a declarative change, validate it locally, commit it, and push it to
`main`:

```powershell
kubectl kustomize .\infrastructure\olympus
kubectl kustomize .\apps\olympus
git add -A
git commit -m "Describe the desired cluster change"
git push origin main
flux reconcile kustomization flux-system --with-source
flux get all -A
```

Flux normally polls Git automatically, so the explicit reconcile command is
only needed when immediate feedback is useful.

## Safety rules

- Never commit kubeconfigs, Talos machine secrets, private keys, tokens, or
  plaintext Kubernetes Secrets.
- Use SOPS with age before moving secret-bearing workloads into Git.
- Pin container images to a version or digest instead of using `latest`.
- Import existing workloads one at a time and compare the rendered manifest
  with the live resource before enabling pruning.
- Treat Git as authoritative after a resource is imported; direct `kubectl`
  edits will be reconciled away.

The existing cluster workloads remain running and unmanaged until they are
deliberately imported into `infrastructure/olympus` or `apps/olympus`.

The Olympus SOPS age private key is stored outside this repository at
`C:\Users\Jacob\.config\sops\age\keys.txt` and in the cluster as the
`flux-system/sops-age` Secret. Only the public age recipient is committed.
