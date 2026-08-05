# Shared VPN egress

This is an opt-in NordVPN egress facility for Olympus. It is not a cluster-wide
default route and ordinary workloads continue to use normal cluster egress.

The `nordvpn-egress.vpn-egress.svc.cluster.local` ClusterIP service provides:

- an authenticated HTTP/HTTPS CONNECT proxy on TCP `8888`;
- an authenticated Shadowsocks endpoint on TCP/UDP `8388` for clients that
  explicitly support the Shadowsocks protocol.

Gluetun owns the VPN tunnel, DNS-over-TLS resolver, and kill-switch firewall.
The proxy ports are internal-only and are not exposed through Tailscale,
Cloudflare, a LoadBalancer, or a NodePort. The Gluetun control API is not
published.

## Connecting a workload

For an HTTP-proxy-aware workload, configure its proxy URL as
`http://nordvpn-egress.vpn-egress.svc.cluster.local:8888` and provide the
proxy username/password from a namespace-local SOPS Secret. Kubernetes Secrets
cannot be referenced across namespaces, so copy only the proxy client values;
never copy the NordVPN service credentials into an application namespace.

For software that must tunnel arbitrary TCP and UDP traffic but cannot use
HTTP CONNECT or Shadowsocks, use a Gluetun sidecar in that workload's pod. A
Kubernetes Service is a destination, not a transparent default gateway.

## Fail-closed consumers

Applications with a hard privacy requirement must also block direct pod egress.
The qBittorrent deployment is the reference implementation: an init container
sets IPv4 and IPv6 OUTPUT policies before qBittorrent starts, allowing only the
Olympus pod and service networks. Its torrent traffic is then explicitly sent
through this proxy. If the proxy or VPN is unavailable, downloads stop instead
of falling back to the household WAN address.

The `vpn-egress` namespace is the only new Pod Security exception. Gluetun keeps
only `CHOWN`, `DAC_OVERRIDE`, `NET_ADMIN`, `SETGID`, and `SETUID` plus access to
`/dev/net/tun`; it receives no service-account token, host network, host PID,
persistent storage, Kubernetes RBAC, or public exposure.

This component has its own Flux Kustomization. A provider login or tunnel
failure therefore reports unhealthy here without blocking reconciliation of
unrelated Olympus infrastructure or applications.
