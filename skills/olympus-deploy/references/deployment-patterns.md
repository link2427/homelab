# Olympus deployment patterns

Use these as starting points, not as substitutes for inspecting the application
and current repository. Replace every placeholder and remove unused resources.

## Application directory

```text
apps/olympus/<app>/
├── kustomization.yaml
├── namespace.yaml
├── resources.yaml
└── <app>.secret.yaml       # only when encrypted with SOPS
```

Add `<app>` to `apps/olympus/kustomization.yaml`.

## Namespace

Prefer restricted Pod Security for new applications. Use baseline only when a
specific image cannot operate under restricted policy and record why.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: APP
  labels:
    kubernetes.io/metadata.name: APP
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

## Hardened application pod

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: APP
  namespace: APP
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: APP
  template:
    metadata:
      labels:
        app.kubernetes.io/name: APP
    spec:
      automountServiceAccountToken: false
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: APP
          image: ghcr.io/OWNER/IMAGE@sha256:DIGEST
          ports:
            - name: http
              containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            runAsNonRoot: true
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
```

Use a startup probe when initialization can legitimately take longer than the
liveness interval. Do not copy these resource values without considering the
actual process.

## Internal service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: APP
  namespace: APP
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: APP
  ports:
    - name: http
      port: 80
      targetPort: http
```

## Private Tailscale service

Create this in addition to, or instead of, the internal service when private
tailnet access is requested:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: APP-tailscale
  namespace: APP
  annotations:
    tailscale.com/hostname: olympus-APP
spec:
  type: LoadBalancer
  loadBalancerClass: tailscale
  selector:
    app.kubernetes.io/name: APP
  ports:
    - name: http
      port: 80
      targetPort: http
```

Public exposure uses the repository's current Cloudflare and Authentik patterns.
Inspect those live patterns and request explicit authorization rather than
copying a tunnel token or inventing a hostname.

## Durable claim

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: APP-data
  namespace: APP
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled
  labels:
    app.kubernetes.io/name: APP
    recurring-job.longhorn.io/source: enabled
    recurring-job.longhorn.io/olympus-app-backup: enabled
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: longhorn-fast
  resources:
    requests:
      storage: 5Gi
```

Use `longhorn-resilient` for databases and irreplaceable state. Use
`longhorn-bulk` only when a single replica plus backup is an accepted tradeoff.

## SOPS Secret

Create the manifest locally with `stringData`, then encrypt it before staging:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: APP-secrets
  namespace: APP
type: Opaque
stringData:
  EXAMPLE: replace-before-encryption
```

```powershell
sops --encrypt --in-place .\apps\olympus\APP\APP.secret.yaml
sops filestatus .\apps\olympus\APP\APP.secret.yaml
```

Never commit the plaintext intermediate. If a secret value has appeared in a
terminal transcript, patch, or Git commit, treat it as exposed and rotate it.

## Image publication

- Build a minimal multi-stage image in the application repository.
- Run tests and a vulnerability scan in CI when practical.
- Publish to GHCR using GitHub Actions' short-lived `GITHUB_TOKEN`.
- Reference the resulting immutable digest in the homelab manifest.
- For a private image, create a namespace-scoped encrypted pull Secret; do not
  reuse or reveal another application's credential.

## Safe update and rollback

- Preserve the prior image digest in Git history.
- Use backward-compatible database migrations or take a verified backup first.
- Do not combine an irreversible data migration with unrelated infrastructure
  changes.
- Roll back by reverting the Git commit, then reconciling Flux.
- A Git rollback does not undo an application-level data migration; maintain a
  separate data recovery path.
