# Media automation

This stack provides private media requests and automation for the existing Plex
library on Atlas:

- Seerr handles user requests and talks to Plex, Radarr, and Sonarr.
- Prowlarr manages explicitly configured, lawful indexer sources.
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
qBittorrent can reach only the Olympus service and pod CIDRs; all external
torrent traffic uses the shared NordVPN proxy. If the proxy is down, torrent
traffic stops.

## Shared VPN dependency

The NordVPN service credentials live only in the SOPS-encrypted shared gateway
Secret under `infrastructure/olympus/vpn-egress`. qBittorrent stores only the
generated proxy-client login in its local application configuration. See the
shared gateway README for reuse and security constraints.
