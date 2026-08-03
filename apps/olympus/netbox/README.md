# NetBox

NetBox is the Olympus source of truth for IP address management (IPAM), rack
layout, devices, interfaces, and cabling. Flux installs the official NetBox
chart and exposes it only to the tailnet at `http://olympus-netbox`.

Interactive login uses Google through Authentik. A randomly generated local
administrator remains in the SOPS-encrypted `netbox-secrets` Secret for
break-glass recovery; it is not exposed outside the tailnet.

NetBox's social-auth pipeline creates a local user record but does not apply the
header-auth-only `REMOTE_AUTH_SUPERUSERS` setting. After the first OIDC login,
the local `akadmin` record was explicitly promoted to superuser in PostgreSQL.
That authorization is durable database state and is included in the database
backups.

Authoritative inventory is stored in PostgreSQL on a 10 GiB
`longhorn-resilient` volume. Uploaded media uses a 5 GiB Longhorn RWX volume.
Both volumes are backed up to Cloudflare R2 every night. Valkey is
an intentionally ephemeral queue/cache and is rebuilt automatically.

The initial inventory covers the Olympus LAN and the known always-on hardware:

| Device | Management IP | Role | Notes |
| --- | --- | --- | --- |
| `optiplex-hermes` | `10.0.0.57/24` | Kubernetes Control Plane | Talos control plane/etcd; M.2 workspace storage |
| `precision-5810-01` | `10.0.0.25/24` | Kubernetes Compute | Talos worker; NVIDIA Quadro M4000 |
| `precision-7810-01` | `10.0.0.171/24` | Kubernetes Compute | Talos worker; NVIDIA Quadro P2000 |
| `hp-2920` | `10.0.0.95/24` | Network | Switch management console |
| `atlas` | `10.0.0.5/24` | Kubernetes Compute | Talos worker; DATA-2 NAS/Plex; NVIDIA Tesla P40; iLO `10.0.0.24` |

The `10.0.0.0/24` prefix and `10.0.0.1/24` gateway are also recorded. Rack
dimensions, rack units, switch ports, and cabling are intentionally left unset
until they can be measured or traced instead of guessed.

Useful checks:

```powershell
kubectl -n netbox get pods,pvc,service
kubectl -n netbox get helmrelease netbox
kubectl -n netbox logs deployment/netbox --tail=100
kubectl -n netbox logs deployment/netbox-worker --tail=100
```
