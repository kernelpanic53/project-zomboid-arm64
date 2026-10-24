# Security and maintenance

The runtime image is ARM64 Debian Trixie. During each image build,
`scripts/security-updates.sh` refreshes the configured Debian indexes and
upgrades installed packages before the image is published. The weekly scheduled
build pulls the current base image and bypasses the cached `runtime` stage so
Debian fixes are incorporated even when application code has not changed.

The build scans the exact ARM64 image it will publish with Trivy. It retains a
30-day report containing all OS and bundled-library findings, and blocks
publication when Debian has an available fix for a High or Critical OS finding.
Other findings remain visible in the report for review. If an update is not yet
available from Debian, the build cannot patch it automatically.

The scan covers the container filesystem, including Box64 and DepotDownloader
files copied into the image. Project Zomboid server files and its bundled x86_64
JRE are downloaded to the persistent `/opt/zomboid` volume at startup, so they
are not covered by the image scan. Keep the server branch current, review
third-party mods, and update the container image regularly.

The Kubernetes chart runs as the configured non-root user, drops all Linux
capabilities, prevents privilege escalation, uses the RuntimeDefault seccomp
profile, disables service-account token mounting, and enables a read-only root
filesystem. `/opt/zomboid`, `/config`, `/home/pz`, and `/tmp` remain writable
through persistent or ephemeral volume mounts.

Pin deployments by image digest for repeatable rollouts. A successful image
scan is not a guarantee that every dependency or runtime-downloaded file is
free of vulnerabilities.
