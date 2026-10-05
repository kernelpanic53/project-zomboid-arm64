# Project Zomboid ARM64

ARM64 Kubernetes/Docker image for the Project Zomboid dedicated server.

This image follows the architecture used by `zhmarvi/valheim-arm64`:

- Debian ARM64 runtime
- native ARM64 DepotDownloader to retrieve Steam AppID `380870`
- official Linux x86_64 Project Zomboid server files
- Box64 to run the x86_64 server/JRE on ARM64
- persistent game-install and server-config volumes
- non-root runtime user
- Helm chart with MetalLB/LoadBalancer-friendly UDP/TCP services

The upstream Project Zomboid fork remains the reference for environment-driven
server configuration and Workshop/INI behavior.

## Build

```bash
docker buildx build \
  --platform linux/arm64 \
  -t ghcr.io/kernelpanic53/project-zomboid-arm64:latest \
  --push .
```

## Kubernetes

Create a secret outside Helm values/history:

```bash
kubectl create namespace zomboid
kubectl -n zomboid create secret generic zomboid-secret \
  --from-literal=admin-password='CHANGE-ME' \
  --from-literal=rcon-password='CHANGE-ME-RCON' \
  --from-literal=server-password='CHANGE-ME-SERVER'

helm upgrade --install zomboid ./charts/project-zomboid-arm64 \
  -n zomboid \
  --set secret.existingName=zomboid-secret
```

The chart defaults to a LoadBalancer Service and exposes UDP 16261, 16262,
8766, 8767 plus TCP 27015. For a home Kubernetes cluster, MetalLB is a good
fit.

## Important ARM64 limitation

Project Zomboid's Linux dedicated server is x86_64. This is therefore an
ARM64 compatibility image, not a native ARM64 server. Box64 is required.

Initial installation/update is intentionally done at container startup into a
persistent PVC. This keeps the image smaller and allows `UPDATE_ON_START=true`
to pick up a new Project Zomboid build without rebuilding the image.
