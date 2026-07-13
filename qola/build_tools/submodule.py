# SPDX-License-Identifier: MIT
# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
"""On-the-fly AITER checkout management.

AITER is *not* a submodule of QoLA — it is cloned on demand into a
git-ignored directory (``<QoLA repo>/build/third_party/aiter`` by
default).  The manifest's ``[qola] aiter_commit`` (or ``--aiter-commit``)
pins which commit the build runs against, and ``[qola] patches_dir``
(or ``--patches-dir``) carries QoLA-owned patches that are reapplied on
top of that commit on every build.
"""

from __future__ import annotations

import hashlib
import os
import subprocess
from pathlib import Path
from typing import Optional

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # type: ignore[no-redef]

# QoLA repo root: <repo>/qola/build_tools/submodule.py -> <repo>
_QOLA_ROOT = Path(__file__).resolve().parents[2]
_DEFAULT_AITER_ROOT = _QOLA_ROOT / "build" / "third_party" / "aiter"
_DEFAULT_PATCHES_DIR = _QOLA_ROOT / "patches" / "aiter"
_AITER_REPO_URL = "https://github.com/ROCm/aiter.git"


def default_aiter_root() -> str:
    """Default path for the AITER checkout (``<QoLA repo>/build/third_party/aiter``).

    Git-ignored at the QoLA level. The build system clones into it on first
    use; subsequent builds fetch and check out the requested commit.
    """
    return str(_DEFAULT_AITER_ROOT)


def default_patches_dir() -> str:
    """Default path for QoLA-owned AITER patches (``<QoLA repo>/patches/aiter``)."""
    return str(_DEFAULT_PATCHES_DIR)


def checkout_aiter(
    manifest_path: Optional[str] = None,
    aiter_root: Optional[str] = None,
    aiter_commit: Optional[str] = None,
    patches_dir: Optional[str] = None,
    force: bool = False,
) -> str:
    """Resolve the AITER checkout + patch step from manifest/CLI inputs.

    High-level entry point shared by ``qola checkout`` and downstream
    Python consumers that want a patched AITER tree without running a
    full kernel build.  Applies the same precedence as ``build_kernels``:

    - ``aiter_root``: argument > ``default_aiter_root()``
    - ``aiter_commit``: argument > manifest's ``[qola] aiter_commit`` >
      None (reset to current HEAD; only valid if the checkout exists)
    - ``patches_dir``: argument > manifest's ``[qola] patches_dir`` >
      ``default_patches_dir()``

    Returns the absolute path to the prepared AITER root.

    Raises
    ------
    RuntimeError
        If the checkout does not exist and no commit was specified
        anywhere, or if a patch fails to apply.
    """
    if aiter_root is None:
        aiter_root = default_aiter_root()
    aiter_root = str(Path(aiter_root).resolve())

    qola_section: dict = {}
    if manifest_path is not None:
        with open(manifest_path, "rb") as f:
            qola_section = tomllib.load(f).get("qola", {})

    effective_commit = aiter_commit or qola_section.get("aiter_commit")
    effective_patches_dir = (
        patches_dir
        or qola_section.get("patches_dir")
        or default_patches_dir()
    )

    ensure_aiter_commit(aiter_root, effective_commit, effective_patches_dir, force=force)
    return aiter_root


def ensure_aiter_commit(
    aiter_root: str,
    commit: Optional[str],
    patches_dir: Optional[str] = None,
    force: bool = False,
) -> None:
    """Ensure *aiter_root* is a clean checkout of *commit* with patches applied.

    Clones ``ROCm/aiter`` into *aiter_root* if no git tree exists there.
    When the tree is not already in the requested state, the resync runs:

    1. Fetches *commit* from origin if it isn't already present locally.
    2. ``git reset --hard`` to *commit* — wipes any local edits.
    3. ``git submodule update --init --recursive --force`` — resyncs CK
       and any other AITER submodules to the recorded commits.
    4. Applies every ``*.patch`` file in *patches_dir* in lexicographic
       order via ``git apply --3way``. The first failing patch aborts the
       build with a pointer at the offending file.

    Idempotency
    -----------
    Steps 2-4 rewrite working-tree files, which bumps their mtimes even when
    the resulting content is identical. That defeats incremental rebuilds for
    every downstream consumer: a reconfigure (e.g. every ``pip install``)
    would re-touch the patched AITER/CK headers and force recompiles. To
    avoid that, a stamp recording ``(target commit + patch-set fingerprint)``
    is written under the AITER git dir after a successful resync. On later
    calls, if ``HEAD`` already equals *target* and the stamp matches, the
    resync is skipped entirely so no files are touched.

    The stamp is keyed on the resolved commit and the content of every patch,
    so bumping the manifest pin or editing/adding/removing a patch triggers a
    full resync. Pass ``force=True`` (or set ``QOLA_FORCE_AITER_CHECKOUT=1``)
    to bypass the stamp and force the destructive resync — the only way to
    clear out-of-band local edits to the checkout.

    Local edits to the AITER checkout are not sanctioned — patches are the
    only supported way to carry deltas. To skip the patch step, point
    *patches_dir* at an empty directory or ``/dev/null``.

    *commit* may be ``None`` only when the checkout already exists; in
    that case the function targets the current HEAD.
    """
    root = Path(aiter_root)
    is_checkout = (root / ".git").exists()

    if not is_checkout:
        if commit is None:
            raise RuntimeError(
                f"AITER checkout at {aiter_root!r} does not exist and no "
                f"commit was specified. Set [qola] aiter_commit in the "
                f"manifest or pass --aiter-commit so QoLA can clone."
            )
        _clone(aiter_root)

    if commit is None:
        target = _git(aiter_root, "rev-parse", "HEAD").strip()
    else:
        target = _resolve_commit(aiter_root, commit)

    force = force or os.environ.get("QOLA_FORCE_AITER_CHECKOUT", "0") not in ("", "0")

    # Skip the destructive (mtime-bumping) resync when the tree is already at
    # `target` with this exact patch set applied. See the docstring's
    # "Idempotency" note for why this matters for incremental rebuilds.
    stamp_path = _checkout_stamp_path(aiter_root)
    desired_key = _checkout_key(target, patches_dir)
    head = _git(aiter_root, "rev-parse", "HEAD").strip()
    if not force and head == target and _read_stamp(stamp_path) == desired_key:
        return

    if head != target:
        print(f"[QoLA] Checking out AITER {target} (was {head})")
    _git(aiter_root, "reset", "--hard", target)
    _git(aiter_root, "submodule", "update", "--init", "--recursive", "--force")

    _apply_patches(aiter_root, patches_dir)

    _write_stamp(stamp_path, desired_key)


def _checkout_stamp_path(aiter_root: str) -> Path:
    """Return the path of the checkout stamp inside the AITER git dir.

    The stamp lives under the git dir (not the working tree) so it is never
    tracked, patched, or clobbered by ``git reset``/``git submodule update``.
    ``git rev-parse --absolute-git-dir`` resolves both a real ``.git``
    directory (fresh clone) and a ``.git`` file pointing elsewhere (worktree
    or submodule-style checkout).
    """
    git_dir = _git(aiter_root, "rev-parse", "--absolute-git-dir").strip()
    return Path(git_dir) / "qola_checkout.stamp"


def _checkout_key(target: str, patches_dir: Optional[str]) -> str:
    """Fingerprint the desired checkout state: target commit + patch contents.

    Any change to the resolved commit or to the name/content of any applied
    patch changes the digest, which invalidates the stamp and forces a resync.
    """
    h = hashlib.sha256()
    h.update(target.encode())
    if patches_dir is not None:
        patches_root = Path(patches_dir)
        if patches_root.is_dir():
            for patch in sorted(patches_root.glob("*.patch")):
                h.update(b"\0")
                h.update(patch.name.encode())
                h.update(b"\0")
                h.update(patch.read_bytes())
    return h.hexdigest()


def _read_stamp(stamp_path: Path) -> Optional[str]:
    """Return the stored checkout key, or ``None`` if the stamp is absent."""
    try:
        return stamp_path.read_text().strip()
    except OSError:
        return None


def _write_stamp(stamp_path: Path, key: str) -> None:
    """Record the checkout key. Non-fatal on failure (worst case: resync next time)."""
    try:
        stamp_path.write_text(key + "\n")
    except OSError:
        pass


def _apply_patches(aiter_root: str, patches_dir: Optional[str]) -> None:
    """Apply every ``*.patch`` in *patches_dir* on top of *aiter_root*.

    Patches are applied in sorted filename order. Each patch is first
    tried with ``git apply --3way`` so that small context drifts can be
    auto-resolved against the parent index. If that fails, we retry
    with plain ``git apply`` — this covers patches whose targets live
    inside an AITER submodule (e.g. ``3rdparty/composable_kernel/...``):
    ``--3way`` rejects those upfront with "does not exist in index"
    because the parent's index only carries a 160000 gitlink for the
    submodule path, while plain apply reads files from the working
    tree and tolerates submodule paths. The first patch that fails
    both attempts raises ``RuntimeError`` so the build surfaces the
    breakage instead of running with a half-patched tree.

    No-op when *patches_dir* is ``None``, missing, or contains no
    ``*.patch`` files.
    """
    if patches_dir is None:
        return
    patches_root = Path(patches_dir)
    if not patches_root.is_dir():
        return

    patches = sorted(patches_root.glob("*.patch"))
    if not patches:
        return

    print(f"[QoLA] Applying {len(patches)} patch(es) from {patches_dir}")
    for patch in patches:
        print(f"[QoLA]   - {patch.name}")
        # Resolve to absolute — git apply -C <dir> looks up relative paths
        # under <dir>, not under our CWD.
        patch_abs = str(patch.resolve())
        try:
            _git(aiter_root, "apply", "--3way", "--whitespace=nowarn", patch_abs)
        except subprocess.CalledProcessError as exc_3way:
            try:
                _git(aiter_root, "apply", "--whitespace=nowarn", patch_abs)
            except subprocess.CalledProcessError as exc_plain:
                raise RuntimeError(
                    f"Failed to apply QoLA patch {patch} to AITER at "
                    f"{aiter_root!r}.\n"
                    f"git apply --3way stderr:\n{exc_3way.stderr}\n"
                    f"git apply (plain) stderr:\n{exc_plain.stderr}\n"
                    f"Either rebase the patch against the current AITER "
                    f"commit, or pin the manifest back to a compatible commit."
                ) from exc_plain


def _clone(aiter_root: str) -> None:
    """Partial-clone ``ROCm/aiter`` into *aiter_root*."""
    root = Path(aiter_root)
    root.parent.mkdir(parents=True, exist_ok=True)
    print(f"[QoLA] Cloning {_AITER_REPO_URL} -> {aiter_root}")
    subprocess.run(
        ["git", "clone", "--filter=blob:none", _AITER_REPO_URL, str(root)],
        check=True,
    )


def _resolve_commit(aiter_root: str, commit: str) -> str:
    """Return the full SHA for *commit*, fetching from origin if necessary."""
    try:
        return _git(aiter_root, "rev-parse", "--verify", f"{commit}^{{commit}}").strip()
    except subprocess.CalledProcessError:
        pass

    # Commit not present locally — try a targeted fetch first, then a full
    # fetch as a fallback (some servers reject arbitrary-SHA fetches without
    # uploadpack.allowAnySHA1InWant).
    try:
        _git(aiter_root, "fetch", "origin", commit)
    except subprocess.CalledProcessError:
        _git(aiter_root, "fetch", "--tags", "origin")

    try:
        return _git(aiter_root, "rev-parse", "--verify", f"{commit}^{{commit}}").strip()
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(
            f"AITER commit {commit!r} not found in {aiter_root!r} even after "
            f"fetching from origin. Check the manifest's [qola] aiter_commit "
            f"or --aiter-commit value."
        ) from exc


def _git(cwd: str, *args: str) -> str:
    """Run ``git <args>`` inside *cwd*, returning stdout. Raises on non-zero exit."""
    result = subprocess.run(
        ["git", "-C", cwd, *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise subprocess.CalledProcessError(
            result.returncode,
            result.args,
            output=result.stdout,
            stderr=result.stderr,
        )
    return result.stdout
