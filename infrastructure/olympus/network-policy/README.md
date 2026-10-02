# Network-policy enforcement

Vulcan's deployment requires enforcement, so kube-router v2.11.1 runs as a
firewall-only DaemonSet beside Flannel and kube-proxy. Routing, service proxy,
load balancer and CNI installation are disabled. The image is pinned by digest.
See the [upstream guide](https://www.kube-router.io/docs/user-guide/) and
[v2.11.1 release](https://github.com/cloudnativelabs/kube-router/releases/tag/v2.11.1).

The controller needs privileged host networking/PID access to program netfilter;
this exception does not apply to Vulcan task pods. Its Kubernetes permissions
are read-only. Host mounts are the read-only kernel module directory and the
shared xtables lock. It never rewrites Flannel's CNI files or kube-proxy rules.

Pre-rollout policy review: Authentik/NetBox database policies allow same-namespace
clients; Coder PostgreSQL allows the actual `app.kubernetes.io/name=coder` server
label. Flux allows same-namespace controller traffic, all egress, cross-namespace
metrics on 8080 and notification-controller ingress. Their application probes,
database connections and Flux readiness must still be checked after rollout.
Pre-existing NetBox application pods were Unknown before this change.

The `network-policy` Flux Kustomization owns this directory. Controller readiness
is not proof of isolation: run the Vulcan per-node canaries before opening its
submission gate, including DNS/S3 success and forbidden API/database/pod/node/LAN,
metadata and Internet connections. Retain sanitized evidence with Vulcan.

Rollback: first close Vulcan submissions in Git and drain/cancel its tasks.
Removing a DaemonSet does not itself remove installed firewall rules. Prefer
repairing/reverting the offending NetworkPolicy while the controller still runs.
If removing the engine is necessary, use its documented `--cleanup-config`
procedure on every node through a reviewed GitOps cleanup workload, with router
and service-proxy functions disabled. Do not blindly flush host iptables or
remove Flannel/kube-proxy. Recheck application and cluster connectivity afterward.
