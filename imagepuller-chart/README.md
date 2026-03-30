# Image Puller Chart

This is a standalone Helm chart that pre-pulls all container images used by the xtreme Helm chart onto each Kubernetes node. This significantly speeds up the initial deployment by caching images before they're needed.

## Why Standalone?

The imagepuller is designed to run independently of the main xtreme installation because:

- Image pulling can take significant time (minutes to hours depending on network speed)
- Customers may want to pre-pull images during off-peak hours
- Allows for separate scheduling of image preparation vs. service deployment
- Can be run once and reused for multiple xtreme installations

## How it works

The chart creates a DaemonSet that runs on every node and uses `crictl` to pull images directly into the host's containerd cache. The images are pulled with the exact same tags that the main Helm chart will use, ensuring version consistency.

## Usage

### Option 1: Run imagepuller first, then xtreme

```bash
# 1. Pre-pull all images (can take time)
helm install imagepuller ./imagepuller-chart -f values-aeo.yaml -f storage.yaml -f repos.yaml --set global.namespace.name=my-namespace

# 2. Wait for completion (check pod status)
kubectl get pods -n my-namespace

# 3. Install xtreme (images already cached)
./install_xtreme --values values-aeo.yaml --ns my-namespace

# 4. Clean up imagepuller when done
helm uninstall imagepuller
```

### Option 2: Use with install_xtreme script (future enhancement)

The `install_xtreme` script can be enhanced to optionally run imagepuller first.

## Images pulled

The chart pulls images for:
- **SDNC services** (using `global.sdncImgtag`)
- **Launchpad/AEO components** (using `launchpad.aeo.image.*.tag`)
- **Infrastructure services**: MongoDB, Prometheus, Grafana, Redis, NATS, HAProxy, etc.
- **Common utilities**: busybox, wait-for, etc.

All tags are dynamically resolved from the values files passed to the chart.

## Configuration

Pass the same values files used for xtreme installation:

```bash
helm install imagepuller ./imagepuller-chart \
  -f values-aeo.yaml \
  -f storage.yaml \
  -f repos.yaml \
  --set global.namespace.name=my-namespace
```

## Monitoring Progress

Watch the DaemonSet pods:

```bash
kubectl get pods -n my-namespace -l name=image-prepuller -w
```

Check logs:

```bash
kubectl logs -n my-namespace -l name=image-prepuller --follow
```

## Cleanup

After images are cached and xtreme is installed:

```bash
helm uninstall imagepuller
kubectl delete pvc -n my-namespace --selector name=image-prepuller  # if any
```