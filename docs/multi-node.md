# Scaling out: parallel inference across multiple RK1 nodes

If your cluster has more than one NPU-enabled RK1, you can serve multiple
simultaneous conversations at full speed — one per node. This doc describes
the design options and a recommended recipe. (Nothing here is deployed by the
base manifests; it's a variant you build on top.)

## Set expectations first: scale out, not up

This is **not** distributed inference. Splitting one model's compute across
boards (llama.cpp's RPC backend, tensor parallelism) is not worth it over
gigabit Ethernet — you'd spend more time shipping activations than computing.
What works well is the opposite: **N independent llama-servers, one per NPU
node, with each conversation pinned to one of them.** Every conversation then
gets a whole node — full NPU prefill, full decode speed, zero contention with
other chats.

One node still serves concurrent requests if asked (`LLAMA_ARG_N_PARALLEL`),
but slots split the context window and share the same CPU during decode —
two active chats on one RK1 stream at roughly half speed each. Real
parallelism comes from more nodes.

## The three problems to solve

### 1. Model storage on every node

The base setup puts the model on a node-local PVC, which is ideal for one
node but doesn't follow the server to others (and a local-disk storage class
may not exist on every node). Options, in rough order of preference:

- **Shared RWX volume (NFS or similar):** one PVC all servers mount; the
  model downloads once. Model *load* is slower over the network, but weights
  are mmap'd read-only — after the first pass they live in each node's page
  cache and decode/prefill are unaffected. The startup probe already
  tolerates slow loads. Simplest, and what the recipe below assumes.
- **Per-node local PVCs:** one PVC per server (a StatefulSet's
  `volumeClaimTemplates` does this naturally) on a `WaitForFirstConsumer`
  local-storage class. Fastest loads, but requires that class on every NPU
  node, and each node downloads its own copy.
- **`emptyDir` + the existing initContainer:** no storage class needed at
  all; costs one model-sized download per pod (re-)start and that much node
  ephemeral disk.

### 2. Conversation ↔ node stickiness (the subtle one)

Chat clients re-send the **whole conversation history every turn**, and
llama-server's prompt cache is what makes turn N cheap (a cache hit turns a
~60 s prefill into under a second). If you put N replicas behind one
Kubernetes Service, requests round-robin and each turn likely lands on a
node with a **cold cache — every turn pays full-history prefill**, wasting
exactly the thing the NPU accelerates. `sessionAffinity: ClientIP` doesn't
help: when Open WebUI proxies, all requests come from the same pod IP.

Ways to route instead:

- **Distinct model aliases (recommended):** each server advertises itself as
  a different "model" (`qwen-a`, `qwen-b`, …) and Open WebUI is given all
  the backends. A conversation picks its model once and is thereby pinned to
  one node for its whole life. Deterministic, zero extra moving parts, and
  users self-balance ("model busy? pick another"). Recipe below.
- **Same alias everywhere:** Open WebUI merges identically-named models
  across backends and spreads requests — automatic balancing, but you accept
  the cache-scatter cost above. Only sensible for single-turn workloads.
- **A slot-aware load balancer** (e.g. [paddler](https://github.com/distantmagic/paddler)):
  purpose-built llama.cpp balancing that tracks server slots, so you keep
  one model name *and* cache affinity. The right answer at "many users",
  overkill for a handful.

### 3. Placement and headroom

- Label every NPU node (`kubectl label node <n> npu.rocket-stack/enabled=true`)
  and give each server a `nodeSelector`/affinity that lands exactly one per
  node (a per-node Deployment pins explicitly; a single Deployment with
  `topologySpreadConstraints` or pod anti-affinity also works).
- Decode saturates all CPU cores while a chat streams. If an NPU node also
  runs control-plane components or other workloads, keep the CPU *request*
  modest (so scheduling stays honest), keep **no CPU limit**, and accept
  that a busy chat slows that node's other tenants. Memory limits are the
  hard constraint — size them for model + KV as in the base manifest.
- Nodes don't need matching NPU clocks: a 200 MHz node simply answers long
  prompts more slowly than a 600 MHz one (~1.8× vs ~2.4× prefill win).
  Naming the aliases after the node helps users pick (`qwen-600mhz`, …).

## Recipe: the aliases route

Sketch of the changes relative to the base manifests — adapt names/counts to
your node inventory. All of this fits naturally in a kustomize overlay.

1. **Shared model volume:** change (or patch) `10-model-cache-pvc.yaml` to
   your RWX storage class with `accessModes: ["ReadWriteMany"]`.

2. **One server per node.** Per NPU node, a copy of the llama-server
   Deployment + Service from `30-llama-server.yaml` with:
   ```yaml
   metadata: {name: llama-server-a}            # -b, -c, ...
   spec:
     template:
       spec:
         nodeSelector:
           kubernetes.io/hostname: <node-a>    # explicit pin, one per node
         containers:
           - name: llama-server
             env:                              # env beats the envFrom value
               - name: LLAMA_ARG_ALIAS
                 value: qwen2.5-3b-node-a
   ```
   plus a matching Service (`llama-server-a`, port 8080). Everything else —
   ConfigMap, probes, hostPath `/dev/accel`, resources — is shared as-is.
   (Yes, hostname pinning is site-specific; that's why this lives in your
   overlay, not the base.)

3. **Tell Open WebUI about all backends** (semicolon-separated):
   ```yaml
   - name: OPENAI_API_BASE_URLS
     value: "http://llama-server-a:8080/v1;http://llama-server-b:8080/v1;http://llama-server-c:8080/v1"
   ```
   (replaces the singular `OPENAI_API_BASE_URL`). Each conversation now
   selects `qwen2.5-3b-node-a/b/c` from the model picker — that choice *is*
   the node pinning.

4. **Multiple users:** enable auth (`WEBUI_AUTH=true` — first signup becomes
   admin) so each user has their own history; nothing else changes. Three
   users on three different aliases chat concurrently at full speed; two
   users on the *same* alias queue behind each other (or share slots if you
   raise `LLAMA_ARG_N_PARALLEL`, with the caveats above).

5. **Verify per node** exactly as in README Step 6, against each Service
   (`kubectl port-forward svc/llama-server-a ...`, then `-b`, `-c`) — you
   want to see the ROCKET backend and the prefill win on every node before
   blaming the router for slowness.

## Known trade-offs of the aliases route

- Users must understand "model = which node I'm on". For a homelab that's a
  feature (visible, debuggable); for a fleet you'd graduate to a slot-aware
  balancer.
- A node going down takes its alias's conversations' *placement* with it —
  history is safe in Open WebUI's volume; the user just continues the chat
  on another alias (paying one full prefill there).
- N copies of the weights in N page caches — irrelevant with a shared RWX
  volume on disk, just don't expect nodes to share RAM.
