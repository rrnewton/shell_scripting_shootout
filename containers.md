# Container Workflow

Each scored implementation has a `Containerfile` beside its source. The build
context is the repository root so the image can run the shared fixtures and
conformance harness.

Build and verify all available candidates with Podman:

```sh
python3 harness/containers.py
```

Select candidates or use Docker with:

```sh
python3 harness/containers.py --candidate rust --candidate python
python3 harness/containers.py --engine docker --candidate typescript-bun
```

Run the measurements inside each successfully built image and write raw JSON to
`results/raw/container-<candidate>.json` with:

```sh
standard-proxy-env python3 harness/containers.py --benchmark-runs 30
```

The same run writes `results/raw/container-bootstrap.json` with build wall time
and final image size. Use `--no-cache` when collecting reportable bootstrap
numbers; base-image download time remains separately visible in the build log.

The images are correctness and reproducibility environments. Performance
measurements run *inside* an already-running container or directly on the host;
container creation and `podman run` startup are never included in language
invocation timings.

Builds use host networking so developer-box proxy endpoints supplied by
`standard-proxy-env` remain reachable from build steps:

```sh
standard-proxy-env python3 harness/containers.py --candidate python
```

On hosts where `standard-proxy-env` exposes an IPv6-only endpoint that rootless Podman
cannot route to, the harness creates a localhost relay for the duration of the
build. Internal proxy addresses are not stored in images or repository
configuration.

Container base images and language dependency versions are pinned in each
candidate. Image digests should be refreshed deliberately and recorded in the
commit that changes them.
