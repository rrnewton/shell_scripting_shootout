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
python3 harness/containers.py --benchmark-runs 30
```

After images have already passed conformance, repeat only the measurements
without rebuilding them:

```sh
python3 harness/containers.py --benchmark-only --benchmark-runs 30
```

The same run writes `results/raw/container-bootstrap.json` with build wall time
and final image size. Use `--no-cache` when collecting reportable bootstrap
numbers; base-image download time remains separately visible in the build log.

The images are correctness and reproducibility environments. Performance
measurements run *inside* an already-running container or directly on the host;
container creation and `podman run` startup are never included in language
invocation timings. Conformance and benchmark containers run with networking
disabled after the image build, which also verifies that cached dependencies
are sufficient for unchanged source execution.

Builds use host networking and forward the standard `HTTP_PROXY`,
`HTTPS_PROXY`, and lowercase proxy variables. For example:

```sh
HTTPS_PROXY=http://proxy.example:8080 \
  python3 harness/containers.py --candidate python
```

When a configured proxy endpoint is not directly routable from rootless
Podman, the harness creates a localhost relay for the duration of the build.
Proxy addresses are not stored in images or repository configuration.

Container base images and language dependency versions are pinned in each
candidate. Image digests should be refreshed deliberately and recorded in the
commit that changes them.
