"""Fetch only a trusted, completed build of this exact main commit.

Validate GitHub's outer artifact digest before reading the App ZIP. This is
separate from the signing job's credentials and never downloads private CAD
fixtures. A successful build alone is not a successful visible smoke test.
"""
import argparse
import json
import os
from pathlib import Path
import posixpath
import re
import shutil
import stat
import subprocess
import sys
import zipfile

PROJECT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT / "scripts"))
import sign_app

REPOSITORY = "NikoWeaver/macsw-solidworks"


def validate_run(run, sha):
    required = {"status": "completed", "conclusion": "success",
                "head_sha": sha, "head_branch": "main",
                "path": ".github/workflows/build-app.yml"}
    if (any(run.get(key) != value for key, value in required.items())
            or run.get("event") not in ("push", "workflow_dispatch")
            or run.get("repository", {}).get("full_name") != REPOSITORY
            or run.get("head_repository", {}).get("full_name") != REPOSITORY):
        raise RuntimeError("Signing requires a successful trusted build of this exact main commit")


def validate_jobs(jobs):
    builds = [job for job in jobs if job.get("name") == "Build & package"]
    if len(builds) != 1 or builds[0].get("conclusion") != "success":
        raise RuntimeError("Required build job did not pass")
    matches = [job for job in jobs if job.get("name") == "SOLIDWORKS installation & runtime"]
    if len(matches) != 1 or matches[0].get("conclusion") != "success":
        raise RuntimeError("Signing requires visible smoke: missing or failed runtime job")
    steps = [step for step in matches[0].get("steps", []) if step.get("name") ==
             "Lightweight visible SOLIDWORKS smoke"]
    if len(steps) != 1 or steps[0].get("conclusion") != "success":
        raise RuntimeError("Signing requires visible smoke; installation-only or diagnostic runs are insufficient")


def validate_artifact(artifacts):
    matches = [item for item in artifacts if item.get("name") == "MacSW-macOS-App"]
    if len(matches) != 1 or matches[0].get("expired") is not False:
        raise RuntimeError("Exactly one unexpired MacSW App artifact is required")
    artifact = matches[0]
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", artifact.get("digest", "")):
        raise RuntimeError("GitHub artifact SHA-256 is missing")
    if not isinstance(artifact.get("id"), int) or artifact["id"] <= 0:
        raise RuntimeError("Invalid artifact ID")
    return artifact


def api(route):
    result = subprocess.run(["gh", "api", route], capture_output=True, timeout=60)
    if result.returncode:
        raise RuntimeError("GitHub provenance request failed")
    return json.loads(result.stdout)


def validate_app_zip(path):
    # ditto understands symlinks; validate those before extracting, not after
    # a malicious link could redirect a later member outside the staging root.
    with zipfile.ZipFile(path) as archive:
        for item in archive.infolist():
            name = item.filename.rstrip("/")
            parts = name.split("/")
            if (any(part in ("", ".", "..") for part in parts) or "\\" in name
                    or not (name == "MacSW.app" or name.startswith("MacSW.app/")
                            or name == "__MACOSX" or name.startswith("__MACOSX/MacSW.app/"))):
                raise RuntimeError("Unsafe App ZIP member")
            mode = item.external_attr >> 16
            kind = stat.S_IFMT(mode)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK):
                raise RuntimeError("Special file in App ZIP")
            if stat.S_ISLNK(mode):
                if item.file_size > 4096:
                    raise RuntimeError("Oversized bundle link")
                target = archive.read(item).decode("utf-8")
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
                if (posixpath.isabs(target) or not resolved.startswith("MacSW.app/")
                        or "\\" in target or "\x00" in target):
                    raise RuntimeError("Unsafe App ZIP symlink")


def fetch(run_id, sha, destination):
    if not re.fullmatch(r"[1-9][0-9]*", run_id) or not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise RuntimeError("Invalid build run ID or commit")
    if (os.environ.get("GITHUB_REPOSITORY") != REPOSITORY
            or os.environ.get("GITHUB_REF") != "refs/heads/main"
            or os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch"):
        raise RuntimeError("Signing input is restricted to manual main CI")
    run = api(f"repos/{REPOSITORY}/actions/runs/{run_id}")
    validate_run(run, sha)
    # More than 100 jobs is unexpected for this workflow; fail rather than
    # silently accepting a partial page.
    job_data = api(f"repos/{REPOSITORY}/actions/runs/{run_id}/jobs?per_page=100")
    if job_data.get("total_count") != len(job_data["jobs"]):
        raise RuntimeError("Unexpected paginated build jobs")
    validate_jobs(job_data["jobs"])
    data = api(f"repos/{REPOSITORY}/actions/runs/{run_id}/artifacts?per_page=100")
    if data.get("total_count") != len(data["artifacts"]):
        raise RuntimeError("Unexpected paginated build artifacts")
    artifact = validate_artifact(data["artifacts"])
    destination.mkdir(parents=True, exist_ok=False)
    outer = destination / "github-artifact.zip"
    with outer.open("xb") as output:
        result = subprocess.run(["gh", "api", f"repos/{REPOSITORY}/actions/artifacts/{artifact['id']}/zip"],
                                stdout=output, stderr=subprocess.PIPE, timeout=600)
    if result.returncode or "sha256:" + sign_app.digest(outer) != artifact["digest"]:
        raise RuntimeError("GitHub App artifact digest mismatch; nothing extracted or signed")
    with zipfile.ZipFile(outer) as archive:
        apps = [item for item in archive.infolist()
                if re.fullmatch(r"build/archive/MacSW-[A-Za-z0-9._-]+-macOS.zip", item.filename)]
        if len(apps) != 1:
            raise RuntimeError("Expected exactly one App ZIP in the verified artifact")
        item = apps[0]
        # Do not extract arbitrary paths from the service archive.
        with archive.open(item) as source, (destination / "app.zip").open("xb") as target:
            shutil.copyfileobj(source, target)
    validate_app_zip(destination / "app.zip")
    (destination / "provenance.json").write_text(json.dumps({
        "format": 1, "repository": REPOSITORY, "build_run_id": run_id,
        "source_commit": sha, "artifact_id": artifact["id"],
        "artifact_digest": artifact["digest"], "app_archive": item.filename,
        "app_sha256": sign_app.digest(destination / "app.zip"),
    }, indent=2) + "\n")
    print("Trusted build and visible smoke verified; App artifact digest verified.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--destination", required=True, type=Path)
    args = parser.parse_args()
    fetch(args.run_id, args.sha, args.destination)
