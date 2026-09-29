#!/usr/bin/env python3
# VERSION=2026.9.29.4
"""Compare upstream Remote Falcon Dockerfile ARGs with an approved baseline."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path


ARG_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def logical_lines(path: Path) -> list[str]:
    lines: list[str] = []
    pending = ""
    for raw in path.read_text(encoding="utf-8").splitlines():
        stripped = raw.rstrip()
        pending += stripped[:-1] if stripped.endswith("\\") else stripped
        if stripped.endswith("\\"):
            pending += " "
            continue
        lines.append(pending)
        pending = ""
    if pending:
        lines.append(pending)
    return lines


def dockerfile_args(path: Path) -> dict[str, str | None]:
    result: dict[str, str | None] = {}
    for number, line in enumerate(logical_lines(path), start=1):
        stripped = line.lstrip()
        if not stripped.upper().startswith("ARG "):
            continue
        declaration = stripped[4:].strip()
        name, separator, default = declaration.partition("=")
        name = name.strip()
        if not ARG_NAME.fullmatch(name):
            raise ValueError(f"Unsupported ARG declaration in {path}:{number}: {line}")
        value = default.strip() if separator else None
        if name in result and result[name] != value:
            raise ValueError(f"ARG {name} has conflicting defaults in {path}")
        result[name] = value
    return result


def git_sha(root: Path) -> str:
    completed = subprocess.run(
        ["git", "-c", f"safe.directory={root.resolve()}", "-C", str(root), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    )
    return completed.stdout.strip()


def display_default(value: str | None) -> str:
    return "no default" if value is None else f"default `{value}`"


def compare(
    baseline: dict, upstream_root: Path, selected_services: list[str] | None
) -> tuple[list[str], str]:
    changes: list[str] = []
    sha = git_sha(upstream_root)
    services = baseline["services"]
    selected = selected_services or list(services)
    unknown = sorted(set(selected) - set(services))
    if unknown:
        raise ValueError(f"Unknown monitored services: {', '.join(unknown)}")
    for service in selected:
        contract = services[service]
        dockerfile = contract["dockerfile"]
        path = upstream_root / dockerfile
        if not path.is_file():
            changes.append(f"- **{service}:** Dockerfile missing: `{dockerfile}`")
            continue

        approved: dict[str, str | None] = contract["args"]
        current = dockerfile_args(path)
        provided = set(contract.get("provided_args", []))

        for name in sorted(current.keys() - approved.keys()):
            risk = (
                "**HIGH RISK: no default and not supplied by cloudflared-remotefalcon**"
                if current[name] is None and name not in provided
                else "review before publishing or rebuilding images"
            )
            changes.append(
                f"- **{service}:** added `{name}` ({display_default(current[name])}) — {risk}"
            )
        for name in sorted(approved.keys() - current.keys()):
            changes.append(f"- **{service}:** removed `{name}`")
        for name in sorted(approved.keys() & current.keys()):
            if approved[name] != current[name]:
                changes.append(
                    f"- **{service}:** `{name}` changed from "
                    f"{display_default(approved[name])} to {display_default(current[name])}"
                )
    return changes, sha


def write_outputs(path: str | None, status: str, sha: str = "") -> None:
    if not path:
        return
    with Path(path).open("a", encoding="utf-8") as output:
        output.write(f"status={status}\n")
        if sha:
            output.write(f"upstream_sha={sha}\n")


def write_report(path: Path, status: str, sha: str, changes: list[str]) -> None:
    commit_url = f"https://github.com/Remote-Falcon/remote-falcon-platform/commit/{sha}"
    lines = [
        "## Remote Falcon Docker build-argument contract",
        "",
        f"Upstream commit: [`{sha[:12]}`]({commit_url})",
        "",
    ]
    if status == "ok":
        lines.append("No Dockerfile `ARG` drift was detected for the monitored images.")
    else:
        lines.extend(
            [
                "Potentially image-breaking upstream build-argument drift was detected:",
                "",
                *changes,
                "",
                "Review the upstream Dockerfile changes and update "
                "`.github/upstream-build-args.json` only after compatibility is confirmed.",
            ]
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--upstream-root", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT"))
    parser.add_argument("--services", nargs="+")
    args = parser.parse_args()

    try:
        baseline = json.loads(args.baseline.read_text(encoding="utf-8"))
        changes, sha = compare(baseline, args.upstream_root, args.services)
        status = "drift" if changes else "ok"
        write_report(args.report, status, sha, changes)
        write_outputs(args.github_output, status, sha)
        print(args.report.read_text(encoding="utf-8"), end="")
        return 3 if changes else 0
    except Exception as error:  # Make workflow failures distinguishable from contract drift.
        write_outputs(args.github_output, "error")
        args.report.write_text(
            "## Remote Falcon Docker build-argument contract\n\n"
            f"Monitor error: `{type(error).__name__}: {error}`\n",
            encoding="utf-8",
        )
        print(f"ARG monitor failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
