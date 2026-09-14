# QoLA — Quality of Life AITER

Manifest-driven ahead-of-time (AOT) builder for [AITER](https://github.com/ROCm/aiter) kernels. QoLA wraps AITER's `build_module()` JIT compilation system with a declarative TOML manifest, producing either:

- **pybind11 Python modules** — standard `.so` files importable from Python (requires PyTorch)
- **torch-free C-linkable shared libraries** (`cpp_itfs` mode) — plain `.so` files linked via HIP/ROCm with no PyTorch dependency

QoLA is designed for [Transformer Engine](https://github.com/NVIDIA/TransformerEngine) to pre-build AITER attention (MHA) kernels at package install time, replacing hours-long JIT compilation with a structured, reproducible build.

## Why QoLA?

- **Declarative manifests** — a single TOML file pins the AITER commit, target architectures, kernel modules, and MHA variant matrix
- **torch-free builds** — `cpp_itfs` mode eliminates the PyTorch build dependency for C-linkable libraries
- **Symbol isolation** — linker version scripts and C++ namespace wrapping prevent symbol collisions when multiple AITER-backed `.so` files coexist in one process
- **Patch-based AITER deltas** — `patches/aiter/*.patch` is reapplied on top of the pinned AITER commit on every build, so bumping AITER becomes a patch rebase rather than maintaining a parallel fork branch
- **No `import aiter`** — QoLA reconstructs AITER's build namespace from a source-tree path alone, avoiding `aiter/__init__.py` side effects and the torch import requirement

## Requirements

- Python >= 3.10
- ROCm / HIP toolchain (hipcc)
- AITER source tree (cloned on demand into `build/third_party/aiter/` — git-ignored, not a submodule; the manifest's `[qola] aiter_commit` pins the SHA)
- PyTorch (pybind mode only)

## Installation

```bash
pip install -e .
```

## Quick Start

### `qola build` — build kernels from a manifest

```bash
# Build all modules declared in a manifest (pybind mode).
# AITER is cloned into build/third_party/aiter/ on first use and checked out to the
# manifest's [qola] aiter_commit; --aiter-root is optional.
qola build \
  --manifest example/te-manifest.toml \
  --output-dir /tmp/qola-out

# Build in cpp_itfs mode (no PyTorch dependency)
qola build \
  --manifest example/te-manifest.toml \
  --output-dir /tmp/qola-out \
  --mode cpp_itfs
```

#### `qola build` options

| Option | Description |
|---|---|
| `--manifest` | Path to the TOML manifest file |
| `--aiter-root` | Path to the AITER source tree (default: `<QoLA repo>/build/third_party/aiter`, cloned on demand) |
| `--aiter-commit` | AITER SHA / tag / branch to fetch and checkout (overrides manifest's `[qola] aiter_commit`) |
| `--patches-dir` | Directory of `*.patch` files applied on top of the AITER checkout (overrides manifest's `[qola] patches_dir`; defaults to `<QoLA repo>/patches/aiter`) |
| `--output-dir` | Directory for build artifacts |
| `--arch` | Target GPU architecture (repeatable, e.g. `--arch gfx950`) |
| `--mode` | Build mode: `pybind` (default) or `cpp_itfs` |
| `--skip-checkout` | Build against whatever is currently at `--aiter-root` instead of running the checkout + patch step. `--aiter-commit` and `--patches-dir` are ignored when set. See *Skipping the checkout step* below |
| `--group` | Build only the `[[modules]]` entries whose `group` matches (repeatable, accepts a `;`-separated list). Ungrouped modules are excluded while filtering is active. Falls back to `$QOLA_BUILD_GROUPS` |
| `--verbose` | Enable verbose build output |

#### Skipping the checkout step

By default, every `qola build` runs the wipe-and-reapply checkout: `git reset --hard` to the manifest's pinned commit, force-resync submodules, then reapply `patches/aiter/*.patch`. Pass `--skip-checkout` to opt out:

```bash
# Run checkout once...
qola checkout --manifest example/te-manifest.toml

# ...then iterate on builds without the prep cost (or risk of clobbering local edits)
qola build --manifest example/te-manifest.toml --output-dir /tmp/qola-out --skip-checkout

# Or build against a custom AITER tree you've prepared yourself
qola build \
  --manifest example/te-manifest.toml \
  --output-dir /tmp/qola-out \
  --aiter-root /path/to/my/aiter \
  --skip-checkout
```

Hard-fails if `<aiter-root>/.git` doesn't exist — `--skip-checkout` requires a real checkout already in place.

### `qola checkout` — prepare an AITER source tree without building

Runs only the AITER-prep phase of `qola build`: clones (if needed), fetches and checks out the requested commit, force-syncs submodules, and applies `patches/aiter/*.patch`. Useful when downstream consumers want a patched AITER source tree to inspect, run their own builds against, or feed into another tool.

```bash
# Manifest-driven: pin the commit + patches via [qola] in the manifest
qola checkout --manifest example/te-manifest.toml

# Explicit overrides without a manifest
qola checkout --aiter-commit d32b0cb62 --patches-dir patches/aiter

# Re-apply patches to whatever is currently checked out
# (only valid if build/third_party/aiter/ already exists)
qola checkout
```

Prints `AITER ready at <abs-path>` on success. Hard-fails on patch conflict — same `git apply --3way` semantics as `qola build`.

#### `qola checkout` options

| Option | Description |
|---|---|
| `--manifest` | *Optional.* TOML manifest; `[qola] aiter_commit` and `[qola] patches_dir` are read as fallbacks for the corresponding flags |
| `--aiter-root` | Path to the AITER source tree (default: `<QoLA repo>/build/third_party/aiter`, cloned on demand) |
| `--aiter-commit` | AITER SHA / tag / branch to fetch and checkout (overrides manifest) |
| `--patches-dir` | Directory of `*.patch` files (overrides manifest; defaults to `<QoLA repo>/patches/aiter`; point at an empty dir to skip patching) |
| `--group` | Validate that the manifest declares these module group(s) and report which modules they cover (repeatable, `;`-separated). Requires `--manifest`. See *Checking out per group* below |

#### Checking out per group

Checkout and build are independent commands, so a consumer can prepare AITER when it needs the sources and defer each group's build to whenever it is ready:

```bash
# Phase 1 — check out once, naming the group(s) this consumer owns.
qola checkout --manifest manifest.toml --group aiter_gemm

# Phase 2 — build that group later, against the tree from phase 1.
qola build --manifest manifest.toml --output-dir out --group aiter_gemm --skip-checkout
```

A manifest pins one AITER commit and one patch set, so **every group in it shares a single checkout** — `--group` on `checkout` does not change what lands on disk. It exists so a per-group checkout fails fast on a bad group name (and prints the modules covered) rather than surfacing the mistake at build time:

```console
$ qola checkout --manifest manifest.toml --group aiter_gem
ValueError: Unknown module group(s) ['aiter_gem'] for manifest manifest.toml.
Declared groups: ['aiter_gemm', 'ck_fused_attn'].
```

Several groups can therefore be built from one checkout — run `qola checkout` once, then one `qola build --group … --skip-checkout` per group.

The same logic is exposed for programmatic use:

```python
from qola.build_tools import checkout_aiter

aiter_root = checkout_aiter(manifest_path="example/te-manifest.toml")
# aiter_root is now an absolute path to a clean, patched AITER checkout

# Optional group validation, same semantics as --group
aiter_root = checkout_aiter(manifest_path="manifest.toml", groups=["aiter_gemm"])
```

`qola build` itself routes through `checkout_aiter`, so the two commands are guaranteed to produce identical AITER trees from identical inputs.

### CMake integration

`cmake/QoLA.cmake` wraps both commands for C++ consumers. It exposes the two phases separately, plus a wrapper that runs both:

| Function | Phase |
|---|---|
| `qola_checkout_aiter()` | Checkout only — syncs the AITER tree named by a manifest, returns its path via `OUT_DIR`. Accepts `GROUPS` for the same fail-fast validation as `qola checkout --group` |
| `qola_build_modules()` | Build only — runs `qola build --skip-checkout` for one `GROUP` against a given `AITER_DIR`, and resolves the resulting headers / `.so`s. Hard-fails if `AITER_DIR` is missing or isn't an AITER tree |
| `qola_add_modules()` | Both — checks out into `<BUILD_DIR>/third_party/aiter` (unless `AITER_DIR` is passed), then builds the group |

Two-phase usage, for consumers that need AITER sources before the kernels are built, or that build several groups from one checkout:

```cmake
include(${QOLA_DIR}/cmake/QoLA.cmake)

qola_checkout_aiter(
  MANIFEST   ${CMAKE_CURRENT_LIST_DIR}/qola_manifest.toml
  AITER_DIR  ${CMAKE_CURRENT_BINARY_DIR}/qola/third_party/aiter
  GROUPS     aiter_gemm
  OUT_DIR    QOLA_AITER_SOURCE_DIR)

# ...anything that needs AITER headers at configure time...

qola_build_modules(
  GROUP      aiter_gemm
  MANIFEST   ${CMAKE_CURRENT_LIST_DIR}/qola_manifest.toml
  BUILD_DIR  ${CMAKE_CURRENT_BINARY_DIR}/qola
  AITER_DIR  ${QOLA_AITER_SOURCE_DIR}
  ARCHS      ${MY_ARCHS}
  OUT_INCLUDE_DIR QOLA_GEMM_INCLUDE_DIR
  OUT_LIB_DIR     QOLA_GEMM_LIB_DIR
  OUT_LIBS        QOLA_GEMM_LIBS)
```

Environment overrides:

- `QOLA_AITER_SOURCE_DIR` / `NVTE_AITER_SOURCE_DIR` — build against an existing AITER tree and skip checkout entirely.
- `QOLA_PREBUILT_DIR_<GROUP>` — skip both phases for that group and consume `<dir>/lib` + `<dir>/include`.

## Manifest Format

The manifest is a TOML file that declares what to build. See [`example/te-manifest.toml`](example/te-manifest.toml) for a full example.

```toml
[qola]
aiter_commit = "33f2e6a..."   # Pinned AITER commit
namespace = "te"               # C++ namespace and .so prefix
patches_dir = "patches/aiter"  # Optional; overrides the default <QoLA repo>/patches/aiter
rocm_versions = ["7.2"]

[build]
architectures = ["gfx950"]

# Static modules from AITER's optCompilerConfig.json
[[modules]]
name = "libmha_fwd"
mode = "cpp_itfs"
receipt = 700                       # CK codegen filter (default: optCompilerConfig value, typically 600)
drop_srcs = ["mha_fwd_split.cu", "mha_fwd_batch_prefill.cu"]
drop_directions = ["fwd_splitkv", "batch_prefill"]

[[modules]]
name = "libmha_bwd"
mode = "cpp_itfs"
receipt = 700

# MHA variant matrix — Cartesian expansion of CK codegen filters
[[mha_fwd_variants]]
dtype = ["bf16", "fp16"]
has_lse = true
has_skip = false

[[mha_bwd_variants]]
dtype = ["bf16", "fp16"]
```

## Build Modes

### pybind (default)

Produces pybind11 `.so` modules importable from Python. Requires PyTorch at both build and runtime.

### cpp_itfs

Produces torch-free C-linkable shared libraries. Each module exposes a C++ API under the configured namespace:

```cpp
#include "qola_mha_fwd.h"

// With namespace = "te":
float ret = qola::te::mha_fwd(args, stream_config);
```

Source replacement is driven by [`cpp_itfs/registry.toml`](qola/cpp_itfs/registry.toml): pybind entry points are swapped for thin C wrappers that expose a namespace-guarded C++ API.

## Build Output

```
output-dir/
  lib/                    # Compiled .so files
    te_libmha_fwd.so
    te_libmha_bwd.so
  configs/                # AITER tuning CSVs
  manifest.json           # Build metadata and per-module results
```

## Available Kernel Modules

| Module | Description | cpp_itfs API |
|---|---|---|
| `libmha_fwd` | Multi-head attention forward | `qola::te::mha_fwd()` |
| `libmha_bwd` | Multi-head attention backward | `qola::te::mha_bwd()` |

## Architecture

### Namespace Resolution

QoLA reconstructs AITER's build-time eval namespace from a source tree path alone, without ever running `import aiter`. This avoids AITER's `__init__.py` side effects and torch import requirements. See [`resolver.py`](qola/build_tools/resolver.py).

### Symbol Collision Prevention

Two layers prevent symbol leaks when multiple `.so` files coexist:

1. **C++ namespace wrapping** — `QOLA_NS_BEGIN`/`QOLA_NS_END` macros place all public symbols under `qola::<namespace>::`
2. **Linker version script** — [`qola_exports.lds`](qola/cpp_itfs/qola_exports.lds) forces all non-`qola::*` symbols local, including AITER symbols with explicit `visibility("default")`

### MHA Variant Matrix

The manifest's `[[mha_fwd_variants]]` / `[[mha_bwd_variants]]` sections declare option dimensions (dtype, has_bias, has_mask, etc.) that are expanded into CK codegen filter patterns. This controls which of the ~34K possible kernel instances are actually compiled. See [`variant_matrix.py`](qola/build_tools/variant_matrix.py). This is currently only support for pybind11 output.

For `cpp_itfs` static modules, kernel pruning is instead controlled by the `receipt` manifest field, which overrides the `--receipt N` argument passed to CK's `generate.py`. AITER's `optCompilerConfig.json` defaults to receipt 600 (the generic `aiter::mha_*` C++ API filter); setting `receipt = 700` selects the TransformerEngine-specific filter (fp16/bf16, row vlayout, has_lse, no skip/sink/logits/qscale), shrinking forward codegen by roughly 48×. See `_rewrite_receipt` in [`config.py`](qola/build_tools/config.py) for the implementation.

### HSA Blob Embedding

[`generate_embedded_hsa.py`](qola/build_tools/generate_embedded_hsa.py) converts binary `.co` ASM blobs into a C++ header with compile-time byte arrays, enabling kernel distribution without a runtime `AITER_ASM_DIR`.

## Roadmap

- [ ] CI support for building and publishing pre-built libraries from manifests
- [ ] Kernel filtering for `libmha` — prune CK codegen instances based on manifest variant declarations in `cpp_itfs` mode (currently pybind-only)
- [ ] C-level JIT for `libmha` — compile MHA variant `.so` files on first use at the C layer, avoiding ahead-of-time compilation of the full variant matrix

## License

MIT License. See `LICENSE` for more details.
