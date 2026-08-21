#!/usr/bin/env python3

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import subprocess


def git(*args):
    return subprocess.check_output(("git",) + args, text=True).strip()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as package:
        for chunk in iter(lambda: package.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description="Create metadata for a Renode CI package")
    parser.add_argument("--platform", required=True)
    parser.add_argument("--architecture", required=True)
    parser.add_argument("--runtime-identifier", required=True)
    parser.add_argument("--package-directory", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()

    packages = sorted(
        path for path in args.package_directory.iterdir()
        if path.is_file() and path.resolve() != args.output.resolve()
    )
    if not packages:
        parser.error("package directory is empty")

    revision = git("rev-parse", "HEAD")
    repository = os.environ.get("GITHUB_REPOSITORY", "ArduPilot/renode")
    server_url = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    metadata = {
        "schema_version": 1,
        "renode_version": pathlib.Path("tools/version").read_text(encoding="utf-8").strip(),
        "source": {
            "repository": repository,
            "revision": revision,
            "revision_short": git("rev-parse", "--short=9", "HEAD"),
            "ref": os.environ.get("GITHUB_REF", ""),
            "url": f"{server_url}/{repository}/commit/{revision}",
        },
        "target": {
            "platform": args.platform,
            "architecture": args.architecture,
            "runtime_identifier": args.runtime_identifier,
        },
        "build": {
            "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "workflow": os.environ.get("GITHUB_WORKFLOW", ""),
            "run_id": os.environ.get("GITHUB_RUN_ID", ""),
            "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", ""),
            "runner_image": os.environ.get("ImageOS", ""),
        },
        "packages": [
            {
                "filename": package.name,
                "size": package.stat().st_size,
                "sha256": sha256(package),
            }
            for package in packages
        ],
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
