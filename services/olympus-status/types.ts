/** Public contract v1. Units: bytes, logical CPU cores, UTC ISO-8601 timestamps. */
export type Health = 'healthy' | 'degraded' | 'unknown';
export type ServiceHealth = Health | 'paused';
export interface NodeUsage {
  measuredAt: string | null;
  cpuCores: number | null;
  memoryBytes: number | null;
  cpuPercent: number | null;
  memoryPercent: number | null;
}
export interface ClusterNode {
  id: string;
  name: string;
  role: 'control-plane' | 'worker';
  status: Health;
  architecture: string | null;
  operatingSystem: string | null;
  kubernetesVersion: string | null;
  model: string | null;
  manufacturer: string | null;
  cpuCores: number;
  memoryBytes: number;
  allocatableCpuCores: number;
  allocatableMemoryBytes: number;
  /** Scheduling resources; MPS/time slicing can exceed physical card count. */
  gpuSchedulingUnits: number;
  usage: NodeUsage;
}
export interface ClusterService {
  id: string;
  name: string;
  namespace: string;
  category: string;
  kind: 'Deployment' | 'StatefulSet' | 'DaemonSet' | 'Group';
  status: ServiceHealth;
  desiredReplicas: number;
  readyReplicas: number;
  members: number;
  publicUrl: string | null;
}
export interface ScheduledJob {
  id: string;
  name: string;
  namespace: string;
  suspended: boolean;
  activeJobs: number;
  lastSucceededAt: string | null;
}
export interface ClusterFeed {
  schemaVersion: '1.0';
  cluster: { id: 'olympus'; name: 'Olympus'; status: Health };
  generatedAt: string;
  expiresAt: string;
  refreshIntervalSeconds: number;
  stale: boolean;
  partial: boolean;
  unavailableSources: string[];
  summary: {
    nodes: number;
    readyNodes: number;
    cpuCores: number;
    memoryBytes: number;
    gpuSchedulingUnits: number;
    activePods: number;
    readyPods: number;
    services: number;
    healthyServices: number;
    pausedServices: number;
    usage: { measuredNodes: number; cpuCores: number | null; memoryBytes: number | null };
  };
  nodes: ClusterNode[];
  services: ClusterService[];
  scheduledJobs: ScheduledJob[];
  /** Physical Longhorn backing filesystems; not usable replicated capacity or all NAS disks. */
  storage: {
    provider: 'Longhorn';
    disks: number;
    readyDisks: number;
    physicalCapacityBytes: number;
    physicalAvailableBytes: number;
  } | null;
  gitops: { total: number; ready: number } | null;
}
