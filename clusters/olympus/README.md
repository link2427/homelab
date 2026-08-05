# Olympus cluster

Flux bootstraps from this directory and reconciles the following dependency
graph:

```text
flux-system -> infrastructure -> apps
                              \-> vpn-egress
```

Keep only cluster composition objects here. Put reusable or deployable
resources under `infrastructure/olympus` and `apps/olympus`.

The optional VPN egress facility reconciles independently so a provider outage
or credential failure cannot block unrelated cluster changes.
