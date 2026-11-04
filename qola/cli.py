# SPDX-License-Identifier: MIT
# Copyright (C) 2026, Advanced Micro Devices, Inc. All rights reserved.
"""QoLA command-line interface."""

from __future__ import annotations

import argparse
import sys


def _split_list(entries: list[str] | None) -> list[str] | None:
    """Flatten repeatable ``;``-separated CLI values into a flat list.

    ``--group a --group "b;c"`` becomes ``["a", "b", "c"]``.  Returns
    ``None`` when the flag was never passed, so downstream precedence
    (manifest / env fallbacks) can distinguish "unset" from "empty".
    """
    if not entries:
        return None
    return [v for entry in entries for v in entry.split(";") if v]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="qola",
        description="QoLA's ahead-of-time AITER kernel builder",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    build_p = sub.add_parser("build", help="Build kernels from a manifest")
    build_p.add_argument(
        "--manifest",
        "-m",
        required=True,
        help="Path to the TOML consumer manifest",
    )
    build_p.add_argument(
        "--aiter-root",
        "-a",
        default=None,
        help="Path to the AITER source tree root. Defaults to "
        "<QoLA repo>/3rdparty/aiter, a git-ignored directory that QoLA "
        "clones into on first use.",
    )
    build_p.add_argument(
        "--aiter-commit",
        default=None,
        help="AITER git commit (full SHA, short SHA, tag, or branch) to "
        "fetch and checkout in --aiter-root before building. Overrides the "
        "manifest's [qola] aiter_commit. When unset everywhere, builds "
        "against whatever is currently checked out.",
    )
    build_p.add_argument(
        "--patches-dir",
        default=None,
        help="Directory of *.patch files to apply on top of the AITER "
        "checkout (lex order, git apply --3way, hard-fail on conflict). "
        "Overrides the manifest's [qola] patches_dir. Defaults to "
        "<QoLA repo>/patches/aiter; point at an empty directory to skip.",
    )
    build_p.add_argument(
        "--output-dir",
        "-o",
        required=True,
        help="Structured output directory",
    )
    build_p.add_argument(
        "--arch",
        action="append",
        dest="archs",
        help="GPU arch target (e.g. gfx942). Repeatable.",
    )
    build_p.add_argument(
        "--mode",
        choices=["pybind", "cpp_itfs"],
        default=None,
        help="Build mode: 'pybind' (torch-enabled Python modules) or "
        "'cpp_itfs' (torch-free C-linkable shared libraries). When set, "
        "overrides the manifest's [build].mode but per-module 'mode' entries "
        "in [[modules]] still win. Defaults to 'pybind' if unset everywhere.",
    )
    build_p.add_argument(
        "--skip-checkout",
        action="store_true",
        help="Skip the AITER checkout + patch step and build against "
        "whatever is currently at --aiter-root. Use after a prior "
        "`qola checkout`, or to build against a custom / locally-mutated "
        "AITER source tree. --aiter-commit and --patches-dir are ignored "
        "when this is set.",
    )
    build_p.add_argument(
        "--group",
        action="append",
        dest="groups",
        help="Build only the [[modules]] entries whose 'group' matches. "
        "Repeatable, and accepts a ';'-separated list. Lets one manifest "
        "(one AITER commit, one patch set, one checkout) serve several "
        "consumers that each build their own subset of kernels. When "
        "omitted, every module in the manifest is built.",
    )
    build_p.add_argument(
        "--verbose",
        "-v",
        action="store_true",
    )

    checkout_p = sub.add_parser(
        "checkout",
        help="Clone/fetch AITER, check out the requested commit, and apply "
        "patches — without building. Useful for downstream consumers that "
        "want a patched AITER source tree to inspect or build against.",
    )
    checkout_p.add_argument(
        "--manifest",
        "-m",
        default=None,
        help="Optional TOML consumer manifest. When provided, [qola] "
        "aiter_commit and [qola] patches_dir are read as fallbacks for the "
        "corresponding flags.",
    )
    checkout_p.add_argument(
        "--aiter-root",
        "-a",
        default=None,
        help="Path to the AITER source tree root. Defaults to "
        "<QoLA repo>/build/third_party/aiter (git-ignored, cloned on first use).",
    )
    checkout_p.add_argument(
        "--aiter-commit",
        default=None,
        help="AITER git commit (full SHA, short SHA, tag, or branch) to "
        "fetch and checkout. Overrides the manifest's [qola] aiter_commit. "
        "When unset everywhere, resets to whatever is currently checked out "
        "(only valid if the checkout already exists).",
    )
    checkout_p.add_argument(
        "--patches-dir",
        default=None,
        help="Directory of *.patch files to apply on top of the AITER "
        "checkout (lex order, git apply --3way, hard-fail on conflict). "
        "Overrides the manifest's [qola] patches_dir. Defaults to "
        "<QoLA repo>/patches/aiter; point at an empty directory to skip.",
    )
    checkout_p.add_argument(
        "--group",
        action="append",
        dest="groups",
        help="Validate that the manifest declares these module group(s) "
        "before checking out, and report which modules they cover. "
        "Repeatable, and accepts a ';'-separated list. Every group in a "
        "manifest shares one tree (one commit, one patch set), so this does "
        "not change what gets checked out — it lets a consumer that checks "
        "out per group fail fast on a bad group name instead of at "
        "`qola build --group` time. Requires --manifest.",
    )

    args = parser.parse_args(argv)

    groups = _split_list(getattr(args, "groups", None))

    if args.command == "build":
        from .build_tools import build_kernels

        archs = _split_list(args.archs)

        result = build_kernels(
            manifest_path=args.manifest,
            aiter_root=args.aiter_root,
            output_dir=args.output_dir,
            archs=archs,
            verbose=args.verbose,
            build_mode=args.mode,
            aiter_commit=args.aiter_commit,
            patches_dir=args.patches_dir,
            skip_checkout=args.skip_checkout,
            groups=groups,
        )
        s = result["summary"]
        print(
            f"Build complete: {s['success']}/{s['total']} succeeded"
            f", {s['failed']} failed."
        )
        if s["failed"]:
            for r in result["modules"]:
                if not r["success"]:
                    print(f"  FAILED: {r['md_name']}: {r['error']}")
            return 1
    elif args.command == "checkout":
        from .build_tools import checkout_aiter

        path = checkout_aiter(
            manifest_path=args.manifest,
            aiter_root=args.aiter_root,
            aiter_commit=args.aiter_commit,
            patches_dir=args.patches_dir,
            groups=groups,
        )
        print(f"AITER ready at {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
