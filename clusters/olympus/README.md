# Olympus cluster

Flux bootstraps from this directory and reconciles the following dependency
graph:

```text
flux-system -> infrastructure -> apps
```

Keep only cluster composition objects here. Put reusable or deployable
resources under `infrastructure/olympus` and `apps/olympus`.

