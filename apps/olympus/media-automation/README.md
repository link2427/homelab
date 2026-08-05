# Media automation

This stack provides private media requests and automation for the existing Plex
library on Atlas:

- Seerr handles user requests and talks to Plex, Radarr, and Sonarr.
- Prowlarr manages explicitly configured indexer sources. Its external HTTP/S
  traffic uses the shared NordVPN proxy and a pod-level OUTPUT lock prevents
  fallback to the household WAN.
- Radarr and Sonarr import into `Movies` and `TV Shows`.
- qBittorrent uses the shared, authenticated `vpn-egress` HTTP CONNECT proxy.
  A pod-level IPv4/IPv6 OUTPUT lock prevents fallback to normal Internet egress.
- The entire writable media path is one DATA-2 NFS mount so imports can use
  hardlinks instead of duplicating files.

## Privacy and backup policy

All resources in this directory use `olympus.dev/backup-policy: never-r2` where
storage is involved. No media-automation PVC has a Longhorn recurring-backup
label. DATA-2 remains outside Longhorn and is never sent to the Cloudflare R2
backup target. This includes Seerr, Radarr, Sonarr, Prowlarr, and qBittorrent
configuration as well as downloaded and imported media.

Do not add `recurring-job.longhorn.io/*` labels to these claims. Local Longhorn
replicas protect small configuration volumes from a single cluster disk loss;
they are not remote backups.

## Network exposure

Seerr is exposed to the tailnet as `http://olympus-seerr`. Radarr, Sonarr, and
Prowlarr have tailnet-only admin endpoints at `http://olympus-radarr`,
`http://olympus-sonarr`, and `http://olympus-prowlarr`. qBittorrent's admin API
remains ClusterIP-only and is surfaced only through the private Homepage widget.
Prowlarr and qBittorrent can reach only the Olympus service and pod CIDRs
directly. Their external traffic uses the shared NordVPN proxy. If the proxy is
down, indexer queries and torrent traffic stop.

Radarr, Sonarr, and Prowlarr use Forms authentication with authentication
disabled only for local addresses. The Tailscale Kubernetes proxy reaches these
services from the cluster-local network, so a tailnet user does not receive a
second login prompt. The valid break-glass username and password are retained in
the SOPS-encrypted `servarr-ui-credentials` Secret. If any admin endpoint is ever
published beyond the tailnet, change `Authentication Required` to `Enabled` or
place the service behind Authentik before publishing it.

## Shared VPN dependency

The NordVPN service credentials live only in the SOPS-encrypted shared gateway
Secret under `infrastructure/olympus/vpn-egress`. Prowlarr receives only the
generated proxy-client login from the namespace-local SOPS Secret and enforces
the proxy settings on every container start. qBittorrent stores the same
proxy-client login in its local application configuration. See the shared
gateway README for reuse and security constraints.
