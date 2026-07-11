# k8s manifests — NPU-accelerated LLM chat on a Talos RK1 node

The full deploy story (including OS-level prerequisites) lives in the top-level
README — this is the manifest-level reference. Everything deploys into the
`chat-rk1` namespace.

## Files (apply in order)

| File | What |
|---|---|
| `00-namespace.yaml`          | `chat-rk1` namespace (PodSecurity: privileged — needed for `/dev/accel`) |
| `10-model-cache-pvc.yaml`    | model weights volume (put it on the NPU node's local disk!) |
| `20-llama-server-config.yaml`| every tunable: model URL, context size, batch, **the NPU switch** |
| `30-llama-server.yaml`       | llama-server Deployment (model-download initContainer) + Service |
| `40-open-webui.yaml`         | Open WebUI PVC + Deployment + Service (talks OpenAI API to llama-server) |
| `50-ingress.yaml`            | nginx Ingress for the UI — **edit the host** |
| `80-bench-config.yaml`       | *optional*: CPU-vs-NPU benchmark parameters |
| `90-bench-job.yaml`          | *optional*: the benchmark Job (reuses the model-cache PVC) |
| `kustomization.yaml`         | makes this directory a kustomize base (00–50; bench excluded) |

## Prerequisites on the node

1. **rocket driver loaded**, `/dev/accel/accel0` present. Confirm:
   `talosctl -n <node> ls /dev/accel` and `talosctl -n <node> read /proc/modules | grep rocket`.
2. **Label the NPU node** so llama-server (and the local-disk PVC, via
   WaitForFirstConsumer) land there:
   ```sh
   kubectl label node <your-npu-node> npu.rocket-stack/enabled=true
   ```
   Selecting by label (not node name) keeps the manifests portable — nothing
   here names a specific node or IP.
3. **Image**: the manifests default to the published
   `ghcr.io/OWNER/chat-rk1/rocket-runtime` image. If you built your own
   (`scripts/10-build-runtime.sh`), override it in an overlay (see below) —
   don't edit the base.
4. **Storage class**: `10-model-cache-pvc.yaml` deliberately has none (cluster
   default) so it works anywhere, but you want a local WaitForFirstConsumer
   class on the NPU node — patch it in your overlay.

## Deploy

Plain path (edit `50-ingress.yaml`'s host first):

```sh
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/10-model-cache-pvc.yaml
kubectl apply -f k8s/20-llama-server-config.yaml
kubectl apply -f k8s/30-llama-server.yaml
kubectl apply -f k8s/40-open-webui.yaml
kubectl apply -f k8s/50-ingress.yaml
```

Kustomize path (recommended once you have site values):

```sh
cp -r kustomize/overlays/example kustomize/overlays/mysite
# edit mysite/*.patch.yaml + kustomization.yaml
kubectl apply -k kustomize/overlays/mysite/
```

First start downloads the model (~6.2 GB) in the `fetch-model` initContainer:

```sh
kubectl -n chat-rk1 logs -f deploy/llama-server -c fetch-model
kubectl -n chat-rk1 rollout status deploy/llama-server deploy/open-webui
```

## Changing model / context / NPU switch

All in `20-llama-server-config.yaml` (or your overlay's `model.patch.yaml`):
edit + `kubectl -n chat-rk1 rollout restart deploy/llama-server`. Commenting
out `GGML_BACKEND_PATH` gives you the CPU baseline of the exact same server —
that A/B is the whole point of the repo (see the README's "prove it" section).

## Optional: reproduce the benchmark numbers

`80-bench-config.yaml` + `90-bench-job.yaml` run `llama-bench` CPU-vs-NPU with
the same image and the same PVC (the chat model is reused, no second
download):

```sh
kubectl apply -f k8s/80-bench-config.yaml
kubectl apply -f k8s/90-bench-job.yaml    # edit the image like the server's
kubectl -n chat-rk1 logs -f job/rocket-bench
```

Results land in the PVC under `/models/results/` (merged JSON + markdown
summary) — compare against `results/` in this repo. Delete the Job before
re-running (`kubectl -n chat-rk1 delete job rocket-bench`). Note the Job and
llama-server both want the NPU: scale the server down for clean numbers
(`kubectl -n chat-rk1 scale deploy/llama-server --replicas=0`).

## Device exposure: hostPath vs a device plugin

llama-server bind-mounts the host `/dev/accel` and runs privileged — the
minimal, dependency-free path for a single dedicated node. For a
shared/multi-tenant cluster, run a DRM-accel **device plugin** that advertises
`rocket.npu/accel` and injects the device into requesting pods, then drop the
`privileged` + `hostPath` bits and add a `resources.limits: rocket.npu/accel: 1`
request. The three cores appear as `/dev/accel/accel0..2`; the userspace
reaches multicore by opening multiple fds, so a single device request still
gets all three unless you partition them.
