# Project Zomboid ARM64 Helm chart

## Install

```bash
kubectl create namespace zomboid
kubectl -n zomboid create secret generic zomboid-secret \
  --from-literal=admin-password='CHANGE-ME' \
  --from-literal=server-password='CHANGE-ME-SERVER' \
  --from-literal=rcon-password='CHANGE-ME-RCON'

helm upgrade --install zomboid . \
  --namespace zomboid \
  --set secret.existingName=zomboid-secret
```

The pod runs as a non-root user with capabilities dropped, seccomp enabled, and a
read-only root filesystem. `/opt/zomboid` and `/config` use persistent claims;
`/home/pz` and `/tmp` use disposable writable volumes.

## MetalLB

The Service is `LoadBalancer` by default. It exposes:

- UDP 16261: primary game port
- UDP 16262: secondary game port
- UDP 8766/8767: Steam ports
- TCP 27015: RCON

For a home ARM64 cluster using MetalLB, set `service.loadBalancerIP` if you want a fixed address.
