# Olympus: Next Ten Ideas

This roadmap is ranked roughly in the order the additions should be considered.
It assumes the existing Olympus stack already includes Talos Linux, Flux,
Longhorn, Coder, Headlamp, Authentik, Cloudflare Tunnel, and NVIDIA GPU support.

## 1. Three-member Talos control plane

Move directly from one control-plane member to three, never two. A three-member
etcd cluster can tolerate one unavailable member while retaining quorum. Add
scheduled etcd snapshots and periodically test the recovery procedure.

- [Talos control-plane guidance](https://docs.siderolabs.com/talos/v1.12/learn-more/control-plane)
- [Talos disaster recovery](https://docs.siderolabs.com/talos/v1.10/build-and-extend-talos/cluster-operations-and-maintenance/disaster-recovery)

## 2. Full observability and alerting

Deploy kube-prometheus-stack, Grafana, Loki, Alloy, and Alertmanager. Monitor
node saturation, GPU temperature and VRAM, SMART data, Longhorn replica health,
Flux reconciliation failures, certificates, tunnels, and external reachability.
Route actionable alerts to email or another notification channel.

## 3. LiteLLM and Langfuse AI control plane

Use LiteLLM as a private OpenAI-compatible gateway for centralized provider
routing, virtual keys, budgets, and usage policies. Connect Langfuse for agent
traces, tool calls, latency, token usage, and evaluation. Keep both internal or
behind authenticated access because traces may contain source code and prompts.

- [LiteLLM documentation](https://docs.litellm.ai/)
- [Langfuse observability](https://langfuse.com/docs/observability/overview)

## 4. Ollama and Open WebUI

Run separate Ollama deployments pinned to the Quadro M4000 and Quadro P2000,
with Open WebUI as the shared interface. The available VRAM is best suited to
small or quantized coding, embedding, classification, and utility models rather
than large frontier models.

- [Ollama GPU support](https://docs.ollama.com/gpu)

## 5. KubeVirt and CDI

Add true virtual machines alongside containers, including persistent disks,
cloud-init, SSH, VNC, and lifecycle controls. Before installation, validate
VT-x, `/dev/kvm`, Talos compatibility, storage behavior, and node capacity.

- [KubeVirt architecture](https://kubevirt.io/user-guide/architecture/)
- [KubeVirt user guide](https://kubevirt.io/user-guide/)

## 6. Argo Workflows

Provide a visual and declarative engine for scheduled, multi-step, and parallel
jobs. Candidate workflows include agent swarms, repository analysis, backups,
data processing, model evaluation, and build pipelines. Argo also complements a
future Kubeflow deployment.

- [Argo Workflows](https://argo-workflows.readthedocs.io/en/latest/)

## 7. KubeRay

Enable distributed Python and machine-learning jobs across Kubernetes. KubeRay
would let notebooks, Coder workspaces, and future Kubeflow pipelines submit Ray
jobs that use multiple Olympus nodes.

- [KubeRay operator installation](https://docs.ray.io/en/latest/cluster/kubernetes/getting-started/kuberay-operator-installation.html)

## 8. Harbor registry

Host a private OCI registry with Docker Hub and GHCR proxy caches, vulnerability
scanning, retention, and local artifact storage. This improves rebuild speed and
reduces dependence on public registry availability and rate limits.

- [Harbor proxy cache](https://goharbor.io/docs/main/administration/configure-proxy-cache/)
- [Harbor vulnerability scanning](https://goharbor.io/docs/main/administration/vulnerability-scanning/)

## 9. GitHub Actions Runner Controller

Run autoscaling, ephemeral GitHub Actions runners inside the cluster. Each job
receives a fresh runner that is removed afterward, allowing Olympus compute to
handle CI without retaining state from earlier jobs. Treat workflows from
untrusted pull requests as hostile and isolate their permissions carefully.

- [GitHub self-hosted runner guidance](https://docs.github.com/en/actions/reference/runners/self-hosted-runners)

## 10. NetBox

Use NetBox as the infrastructure system of record for machines, IP addresses,
GPUs, disks, switch ports, cables, VLANs, and rack positions. This provides a
searchable answer for questions such as which switch port a node uses or where a
management address was assigned.

- [NetBox documentation](https://netboxlabs.com/docs/)

## Suggested order

1. Control-plane high availability and recovery
2. Observability and alerting
3. LiteLLM and Langfuse
4. Ollama and Open WebUI
5. Select the next workload-focused addition based on actual demand
