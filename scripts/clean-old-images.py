#!/usr/bin/env python3
"""
Clean up old container image versions and untagged manifests in GitHub Container Registry (GHCR).
Safely protects active named tags (e.g. ubuntu, node-ts, java-jvm, etc.) and retains the latest N
commit-sha tagged versions for rollback, while purging stale SHA builds and untagged digests.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Set, Tuple

DEFAULT_PROTECTED_TAGS = {
    "ubuntu",
    "ubuntu-minimal",
    "base",
    "cpp-dotnet",
    "java-jvm",
    "node-ts",
    "python",
    "go",
    "rust",
    "php",
    "ruby",
    "latest",
}


def get_auth_token(token_arg: Optional[str] = None) -> str:
    """Retrieve GitHub token from argument, environment, or GitHub CLI."""
    if token_arg:
        return token_arg
    token = os.environ.get("PACKAGES_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        return token
    try:
        out = subprocess.check_output(["gh", "auth", "token"], stderr=subprocess.DEVNULL)
        token = out.decode("utf-8").strip()
        if token:
            return token
    except Exception:
        pass
    return ""


def get_default_owner_and_repo() -> Tuple[str, str]:
    """Derive owner and repo from environment or git remote."""
    full_repo = os.environ.get("GITHUB_REPOSITORY", "")
    if full_repo and "/" in full_repo:
        parts = full_repo.split("/", 1)
        return parts[0], parts[1]

    owner = os.environ.get("GITHUB_REPOSITORY_OWNER", "")
    try:
        remote_url = subprocess.check_output(
            ["git", "remote", "get-url", "origin"],
            stderr=subprocess.DEVNULL,
        ).decode("utf-8").strip()
        match = re.search(r"[:/]([^/]+)/([^/.]+)(?:\.git)?$", remote_url)
        if match:
            if not owner:
                owner = match.group(1)
            return owner, match.group(2)
    except Exception:
        pass

    return owner or "tesseractdigitainnovations", "dev-env"


def make_github_request(
    url: str,
    token: str,
    method: str = "GET",
) -> Tuple[int, Any, Dict[str, str]]:
    """Execute authenticated HTTP request to GitHub API."""
    req = urllib.request.Request(url, method=method)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "ghcr-image-cleanup-script")
    if token:
        req.add_header("Authorization", f"Bearer {token}")

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            status = resp.status
            headers = dict(resp.headers)
            body = resp.read().decode("utf-8")
            data = json.loads(body) if body else None
            return status, data, headers
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="ignore")
        try:
            data = json.loads(body)
        except Exception:
            data = {"message": body}
        return e.code, data, dict(e.headers)


def fetch_all_package_versions(
    owner: str,
    package_name: str,
    token: str,
) -> Tuple[List[Dict[str, Any]], str]:
    """Fetch all package versions for container package, checking org first then user."""
    package_enc = urllib.parse.quote(package_name.lower(), safe="")
    is_org = True

    # Probe whether org or user
    test_url = f"https://api.github.com/orgs/{owner}/packages/container/{package_enc}/versions?per_page=1"
    status, _, _ = make_github_request(test_url, token)
    if status == 404:
        is_org = False

    base_endpoint = "orgs" if is_org else "users"
    versions: List[Dict[str, Any]] = []
    page = 1

    while True:
        url = f"https://api.github.com/{base_endpoint}/{owner}/packages/container/{package_enc}/versions?per_page=100&page={page}"
        status, data, _ = make_github_request(url, token)
        if status != 200 or not isinstance(data, list):
            break
        if not data:
            break
        versions.extend(data)
        if len(data) < 100:
            break
        page += 1

    owner_type = "org" if is_org else "user"
    return versions, owner_type


def delete_package_version(
    owner: str,
    package_name: str,
    version_id: int,
    owner_type: str,
    token: str,
) -> bool:
    """Delete a single package version by ID."""
    package_enc = urllib.parse.quote(package_name.lower(), safe="")
    if owner_type == "org":
        url = f"https://api.github.com/orgs/{owner}/packages/container/{package_enc}/versions/{version_id}"
    else:
        url = f"https://api.github.com/user/packages/container/{package_enc}/versions/{version_id}"

    status, _, _ = make_github_request(url, token, method="DELETE")
    return status in (200, 204)


def prune_local_docker(until_hours: str = "168h"):
    """Prune unused docker images older than specified window."""
    try:
        print(f"::group::🧹 Pruning local unused Docker images (older than {until_hours})...")
        cmd = ["docker", "image", "prune", "-af", f"--filter=until={until_hours}"]
        res = subprocess.run(cmd, capture_output=True, text=True, check=False)
        print(res.stdout or res.stderr)
        print("::endgroup::")
    except Exception as e:
        print(f"Notice: local docker prune skipped ({e})")


def main():
    parser = argparse.ArgumentParser(description="Clean up old GHCR container image versions")
    parser.add_argument("--owner", help="GitHub org or username (defaults to repo owner)")
    parser.add_argument("--package", help="Package/repository name (defaults to current repo)")
    parser.add_argument("--token", help="GitHub token with packages:write permissions")
    parser.add_argument(
        "--keep",
        type=int,
        default=3,
        help="Number of recent SHA-tagged builds to retain per category (default: 3)",
    )
    parser.add_argument(
        "--delete-untagged",
        action="store_true",
        default=True,
        help="Delete untagged versions/manifests (default: True)",
    )
    parser.add_argument(
        "--keep-untagged",
        action="store_false",
        dest="delete_untagged",
        help="Preserve untagged versions",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print deletion plan without actually deleting any versions",
    )
    parser.add_argument(
        "--prune-local",
        action="store_true",
        help="Also run docker image prune for local runner cleanup",
    )
    args = parser.parse_args()

    default_owner, default_repo = get_default_owner_and_repo()
    owner = args.owner or default_owner
    package = args.package or default_repo
    token = get_auth_token(args.token)

    if args.prune_local:
        prune_local_docker()

    print(f"::group::🔍 GHCR Image Retention Inspection: {owner}/{package}")
    print(f"Target Owner:             {owner}")
    print(f"Target Package:           {package}")
    print(f"Keep Recent SHA Builds:   {args.keep} per category")
    print(f"Delete Untagged Manifests:{args.delete_untagged}")
    print(f"Dry Run Mode:             {args.dry_run}")

    if not token:
        print(
            "\n⚠️ Warning: No GitHub token provided or discovered. Package inspection may fail if private, "
            "and deletion will be skipped.",
            file=sys.stderr,
        )

    versions, owner_type = fetch_all_package_versions(owner, package, token)
    print(f"Owner Type Detected:      {owner_type}")
    print(f"Total Versions Found:     {len(versions)}")

    if not versions:
        print("\nNo package versions found or access denied. Exiting.")
        print("::endgroup::")
        return

    to_keep: List[Tuple[int, str, List[str], str]] = []
    to_delete: List[Tuple[int, str, List[str], str]] = []

    # 1. Process versions with active protected release tags
    remaining_versions = []
    for v in versions:
        vid = v.get("id")
        created = v.get("created_at", "")[:19]
        tags = v.get("metadata", {}).get("container", {}).get("tags", [])
        if any(t in DEFAULT_PROTECTED_TAGS for t in tags):
            matching = [t for t in tags if t in DEFAULT_PROTECTED_TAGS]
            to_keep.append((vid, f"Active primary release tag ({', '.join(matching)})", tags, created))
        elif not tags:
            if args.delete_untagged:
                to_delete.append((vid, "Untagged manifest", [], created))
            else:
                to_keep.append((vid, "Untagged (preserved by flag)", [], created))
        else:
            remaining_versions.append(v)

    # 2. Group ephemeral SHA builds by category prefix
    sha_by_cat: Dict[str, List[Dict[str, Any]]] = {}
    for v in remaining_versions:
        tags = v.get("metadata", {}).get("container", {}).get("tags", [])
        matched_cat = "other"
        for prot in sorted(DEFAULT_PROTECTED_TAGS, key=len, reverse=True):
            if any(t.startswith(f"{prot}-sha-") for t in tags):
                matched_cat = prot
                break
        sha_by_cat.setdefault(matched_cat, []).append(v)

    # 3. For each category, keep newest N, delete remainder
    for cat, cat_versions in sha_by_cat.items():
        cat_versions.sort(key=lambda x: x.get("created_at", ""), reverse=True)
        for idx, v in enumerate(cat_versions):
            vid = v.get("id")
            created = v.get("created_at", "")[:19]
            tags = v.get("metadata", {}).get("container", {}).get("tags", [])
            if idx < args.keep:
                to_keep.append((vid, f"{cat} recent build ({idx+1}/{args.keep})", tags, created))
            else:
                to_delete.append((vid, f"{cat} build older than {args.keep} most recent", tags, created))

    print(f"\nProtected / Retained Versions: {len(to_keep)}")
    print(f"Versions Marked for Deletion:  {len(to_delete)}")
    print("::endgroup::")

    # Display breakdown
    if to_delete:
        print(f"\n::group::🗑️ Deletion Plan ({len(to_delete)} versions to delete)")
        for vid, reason, tags, created in to_delete:
            tag_str = ", ".join(tags) if tags else "(untagged)"
            print(f"  - ID: {vid} | {created} | {tag_str} | Reason: {reason}")
        print("::endgroup::")

    deleted_count = 0
    failed_count = 0

    if to_delete and not args.dry_run:
        print(f"::group::🚀 Executing Deletions ({len(to_delete)} versions)...")
        for vid, reason, tags, _ in to_delete:
            tag_str = ", ".join(tags) if tags else "(untagged)"
            success = delete_package_version(owner, package, vid, owner_type, token)
            if success:
                deleted_count += 1
                print(f"  ✓ Deleted version {vid} [{tag_str}]")
            else:
                failed_count += 1
                print(f"  ✗ Failed to delete version {vid} [{tag_str}]")
        print("::endgroup::")
    elif args.dry_run and to_delete:
        print("\nℹ️ Dry run enabled: No versions were deleted.")

    # Write summary to GITHUB_STEP_SUMMARY
    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_file:
        try:
            with open(summary_file, "a", encoding="utf-8") as f:
                f.write(f"\n### 🧹 GHCR Container Image Cleanup Report: `{owner}/{package}`\n\n")
                f.write("| Status | Count |\n")
                f.write("| :--- | :--- |\n")
                f.write(f"| **Total Versions Inspected** | {len(versions)} |\n")
                f.write(f"| **Retained Versions** | {len(to_keep)} |\n")
                f.write(f"| **Versions Slated for Deletion** | {len(to_delete)} |\n")
                if not args.dry_run:
                    f.write(f"| **Successfully Deleted** | {deleted_count} |\n")
                    f.write(f"| **Failed to Delete** | {failed_count} |\n")
                else:
                    f.write("| **Mode** | *Dry Run (No files deleted)* |\n")
                f.write("\n")

                if to_delete:
                    f.write("<details><summary><b>Deleted / Stale Versions Breakdown</b></summary>\n\n")
                    f.write("| ID | Created | Tags | Reason |\n")
                    f.write("| :---: | :--- | :--- | :--- |\n")
                    for vid, reason, tags, created in to_delete:
                        tag_str = f"`{', '.join(tags)}`" if tags else "*untagged*"
                        f.write(f"| {vid} | {created} | {tag_str} | {reason} |\n")
                    f.write("\n</details>\n\n")

                if to_keep:
                    f.write("<details><summary><b>Retained Versions</b></summary>\n\n")
                    f.write("| ID | Created | Tags | Reason |\n")
                    f.write("| :---: | :--- | :--- | :--- |\n")
                    for vid, reason, tags, created in to_keep:
                        tag_str = f"`{', '.join(tags)}`" if tags else "*untagged*"
                        f.write(f"| {vid} | {created} | {tag_str} | {reason} |\n")
                    f.write("\n</details>\n\n")
        except Exception as e:
            print(f"Warning: Failed to write to GITHUB_STEP_SUMMARY: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
