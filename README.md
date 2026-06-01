# control-repo-test-sonnet — Kubernetes LTS Build Repo

Builds and publishes 6 Kubernetes LTS components from the source fork
`oleksandr-minakov/k8s-test-sonnet`.

## Architecture

```
Source fork (k8s-test-sonnet @ release-1.32)
  CVE/backport PR → lts-tests.yml (unit×6 + build) → merge
  → manual dispatch release-please.yaml
  → release-please cuts tag vX.Y.Z-lts.N + GitHub Release
  → bump-build-repo job opens "chore: bump VERSION" PR here

Build repo (this repo @ release-1.32)
  Human merges bump PR → push VERSION → build.yaml fires
  → resolve job: reads VERSION → outputs.tag
  → 6-component matrix (fail-fast: false):
      checkout source fork @ tag to src/
      actions/setup-go@v5 (version from src/.go-version or 1.23.4)
      ./build.sh --component X --kind image|deb --tag <tag>
      Syft SBOM → Grype scan → cosign sign + (images) attest CycloneDX
      images → ghcr.io/oleksandr-minakov/lts-k8s/<X>
      debs → deb-<X> workflow artifact
  Daily scan.yaml: re-pulls 4 images, re-runs Syft+Grype.
```

## Components

| Component | Kind | Output |
|---|---|---|
| kube-apiserver | OCI image | `ghcr.io/oleksandr-minakov/lts-k8s/kube-apiserver:<tag>` |
| kube-controller-manager | OCI image | `ghcr.io/oleksandr-minakov/lts-k8s/kube-controller-manager:<tag>` |
| kube-scheduler | OCI image | `ghcr.io/oleksandr-minakov/lts-k8s/kube-scheduler:<tag>` |
| kube-proxy | OCI image | `ghcr.io/oleksandr-minakov/lts-k8s/kube-proxy:<tag>` |
| kubelet | Debian package | `deb-kubelet` workflow artifact |
| kubectl | Debian package | `deb-kubectl` workflow artifact |

## Key files

| File | Purpose |
|---|---|
| `VERSION` | Current source-repo tag (e.g. `v1.32.13-lts.0`). Written by bump-build-repo, read by build.yaml |
| `build.sh` | POSIX bash build script. Handles both `image` and `deb` kinds |
| `.github/workflows/build.yaml` | Push-on-VERSION trigger. Matrix build + SBOM + scan + cosign |
| `.github/workflows/scan.yaml` | Daily Grype/Syft scan of released images |

## Manual trigger

To build at a specific source ref without waiting for a release:

```bash
gh workflow run build.yaml \
  --repo oleksandr-minakov/control-repo-test-sonnet \
  --ref release-1.32 \
  -F source_ref=v1.32.13-lts.0
```

## Build pitfalls

- Binary built directly on runner (not in docker) — `ubuntu-latest` has `rsync` preinstalled; `golang:*-bookworm` does not.
- `GOFLAGS=-mod=vendor` — Kubernetes vendors all deps; `-mod=readonly` fails with `GOPROXY=off`.
- `-buildvcs=false` — required since Go 1.18 when build context lacks full git history.
- nfpm installed via apt (goreleaser apt repo), not tarball — tarball URLs frequently 404.
