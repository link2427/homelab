# Media automation

This stack provides private media requests and automation for the existing Plex
library on Atlas:

- Seerr handles user requests and talks to Plex, Radarr, and Sonarr.
- Prowlarr manages explicitly configured, lawful indexer sources.
- Radarr and Sonarr import into `Movies` and `TV Shows`.
- qBittorrent shares its pod network namespace with a restartable Gluetun
  sidecar. The application container does not start until the NordVPN tunnel and
  firewall health check pass.
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

Only Seerr is exposed to the tailnet as `http://olympus-seerr`. The Servarr and
qBittorrent admin APIs remain ClusterIP-only. qBittorrent has no independent
network path: Gluetun initializes first and owns the pod firewall.

## NordVPN secret

`nordvpn-credentials` must contain NordVPN **service credentials**, not the
normal account email/password. Store it only in a SOPS-encrypted
`nordvpn.secret.yaml`, add that file to `kustomization.yaml`, and then change the
qBittorrent deployment replica count from zero to one.
