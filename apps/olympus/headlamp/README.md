# Headlamp

Headlamp is the Kubernetes administration UI for Olympus. It is exposed only
through the tailnet at `http://olympus-headlamp` and is linked from Homepage.

The Headlamp pod has no cluster-wide RBAC permissions and cannot silently act
as an administrator. Generate a short-lived administrator token when needed:

```powershell
kubectl -n headlamp create token headlamp-admin --duration=24h
```

Paste the token into Headlamp's login screen. The browser session lasts up to
24 hours. Helm installation from within Headlamp is disabled so Flux remains
the source of truth for applications.
