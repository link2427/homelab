# LLM

llama.cpp router on Atlas's Tesla P40, reachable only from the `coder` namespace at `http://llm.llm.svc.cluster.local/v1`. There is no API key; the NetworkPolicy is the access boundary. Do not expose this Service publicly.

## Models

Presets are in `models.ini`. The router holds one model at a time (`--models-max=1`) and swaps on the request's `model` field.

| Model ID | Use | File | Size | Context |
| --- | --- | --- | ---: | ---: |
| `ornith-1.5-9b` | Coding agent (MIT) | `Ornith-1.5-9B-Q6_K.gguf` | 7.56 GB | 262144 |
| `hemmingway-1.5` | Prose (CC BY-NC 4.0, non-commercial) | `HemmingwayAI_Hemmingway-1.5-Q4_K_L.gguf` | 18.82 GB | 32768 |

The `fetch-models` init container downloads missing files at pinned Hugging Face revisions and checks their SHA-256 before use. To add or change a model, update the init script and `models.ini`, and grow the PVC if needed.

## Storage

`llm-models` is 40 GiB on `longhorn-ci-cache`: one replica, no backup, because every file can be downloaded again.

## GPU

This Deployment holds the P40 exclusively. DubQuick's VibeVoice override needs the GPU and is unavailable while it does. To return the card, scale this Deployment to zero through GitOps, verify the GPU is released, then restore DubQuick's `runtimeClassName: nvidia` and `nvidia.com/gpu` limit.
