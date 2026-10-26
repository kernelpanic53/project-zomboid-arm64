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

## Box64 and Java runtime

The chart defaults to Box64's conservative Project Zomboid settings and Java's
interpreter mode for stability. The interpreter is slow; after confirming the
server survives with these Box64 settings, try `server.jitMode=c1` for better
startup and simulation speed. C1 can still crash under Box64, so switch back to
`interpreter` if the JVM reports another `SIGILL`.

The image also includes an optional x86_64 Azul Zulu Java 25.0.5 JRE. It is
downloaded with its SHA-256 from Azul's metadata API during the image build and
run through Box64. To select it:

```bash
helm upgrade --install zomboid . \
  --namespace zomboid \
  --set server.javaRuntime=zulu
```

The default `server.javaRuntime=bundled` uses the JRE that comes with the
Project Zomboid server depot. The alternate runtime remains Java 25 to avoid a
major-version change; switching runtimes may change JIT behavior, but it cannot
remove the x86_64-on-ARM64 emulation overhead or guarantee that C1 is stable.
To build with a different Java 25 patch, pass
`--build-arg ZULU_JRE_VERSION=<version>` and rebuild the image. The Zulu runtime
is included in the image; leave `server.javaRuntime` set to `bundled` to keep
using the server depot's Java runtime.
