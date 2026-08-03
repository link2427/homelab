# NetBox

NetBox is the Olympus source of truth for IP address management (IPAM), rack
layout, devices, interfaces, and cabling. Flux installs the official NetBox
chart and exposes it only to the tailnet at `http://olympus-netbox`.

Interactive login uses Google through Authentik. A randomly generated local
administrator remains in the SOPS-encrypted `netbox-secrets` Secret for
break-glass recovery; it is not exposed outside the tailnet.

Authoritative inventory is stored in PostgreSQL on a 10 GiB
`longhorn-resilient` volume. Uploaded media uses a 5 GiB Longhorn RWX volume.
Both volumes are backed up to the Atlas Longhorn target every night. Valkey is
an intentionally ephemeral queue/cache and is rebuilt automatically.

Useful checks:

```powershell
kubectl -n netbox get pods,pvc,service
kubectl -n netbox get helmrelease netbox
kubectl -n netbox logs deployment/netbox --tail=100
kubectl -n netbox logs deployment/netbox-worker --tail=100
```
