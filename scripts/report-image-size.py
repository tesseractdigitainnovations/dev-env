#!/usr/bin/env python3
"""
Report Docker image sizes, layers, and digest for GitHub Actions workflows.
Outputs to console logs and appends a markdown summary to GITHUB_STEP_SUMMARY.
"""

import argparse
import json
import os
import subprocess
import sys


def format_size(num_bytes: float) -> str:
    """Format bytes into a human-readable size string."""
    if num_bytes is None or num_bytes < 0:
        return "N/A"
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if abs(num_bytes) < 1024.0:
            return f"{num_bytes:.2f} {unit}"
        num_bytes /= 1024.0
    return f"{num_bytes:.2f} PB"


def get_manifest_info(image_ref: str, digest: str = ""):
    """Inspect the registry manifest using docker buildx imagetools inspect."""
    target = f"{image_ref.split('@')[0]}@{digest}" if digest else image_ref
    raw_output = None

    # First try by digest if available, else by tag
    for ref_to_try in ([target, image_ref] if digest else [image_ref]):
        try:
            raw_output = subprocess.check_output(
                ["docker", "buildx", "imagetools", "inspect", "--raw", ref_to_try],
                stderr=subprocess.DEVNULL,
            ).decode("utf-8", errors="ignore")
            if raw_output:
                break
        except Exception:
            continue

    if not raw_output:
        return None, []

    try:
        manifest_data = json.loads(raw_output)
    except Exception:
        return None, []

    # If it is an index or manifest list, resolve platform manifest (prefer amd64)
    if "manifests" in manifest_data:
        manifests = manifest_data.get("manifests", [])
        chosen = None
        for m in manifests:
            arch = m.get("platform", {}).get("architecture")
            ann = m.get("annotations", {})
            ref_type = ann.get("vnd.docker.reference.type")
            if arch == "amd64" and not ref_type:
                chosen = m
                break
        if not chosen and manifests:
            # fallback to first non-attestation manifest
            chosen = next(
                (m for m in manifests if not m.get("annotations", {}).get("vnd.docker.reference.type")),
                manifests[0],
            )

        if chosen and "digest" in chosen:
            p_digest = chosen["digest"]
            base_name = image_ref.split("@")[0]
            try:
                p_raw = subprocess.check_output(
                    ["docker", "buildx", "imagetools", "inspect", "--raw", f"{base_name}@{p_digest}"],
                    stderr=subprocess.DEVNULL,
                ).decode("utf-8", errors="ignore")
                manifest_data = json.loads(p_raw)
            except Exception:
                pass

    layers = manifest_data.get("layers", [])
    total_compressed = sum(layer.get("size", 0) for layer in layers) if layers else None

    layer_breakdown = []
    for idx, layer in enumerate(layers, 1):
        dgst = layer.get("digest", "")
        sz = layer.get("size", 0)
        layer_breakdown.append(
            {
                "index": idx,
                "digest": dgst[:19] + "..." if len(dgst) > 22 else dgst,
                "full_digest": dgst,
                "size_bytes": sz,
                "size_formatted": format_size(sz),
            }
        )

    return total_compressed, layer_breakdown


def get_uncompressed_size(image_tag: str):
    """Attempt to pull and inspect image for uncompressed size."""
    try:
        subprocess.run(
            ["docker", "pull", "-q", image_tag],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=180,
        )
    except Exception:
        pass

    try:
        inspect_out = subprocess.check_output(
            ["docker", "image", "inspect", image_tag, "--format", "{{.Size}}"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        if inspect_out.isdigit():
            return int(inspect_out)
    except Exception:
        pass
    return None


def main():
    parser = argparse.ArgumentParser(description="Report final Docker image sizes")
    parser.add_argument("--image", required=True, help="Base image name (e.g. ghcr.io/owner/repo)")
    parser.add_argument("--tag", default="", help="Specific tag name")
    parser.add_argument("--tags", default="", help="Newline or comma separated list of tags")
    parser.add_argument("--digest", default="", help="Image sha256 digest")
    args = parser.parse_args()

    # Determine tags list
    raw_tags = []
    if args.tags:
        raw_tags = [t.strip() for t in args.tags.replace(",", "\n").splitlines() if t.strip()]
    if args.tag and args.tag not in raw_tags:
        raw_tags.insert(0, args.tag)

    primary_tag = raw_tags[0] if raw_tags else args.image

    print(f"::group::📊 Final Image Size Report: {primary_tag}")

    compressed_size, layers = get_manifest_info(primary_tag, args.digest)
    uncompressed_size = get_uncompressed_size(primary_tag)

    print(f"\nImage:                    {primary_tag}")
    if args.digest:
        print(f"Digest:                   {args.digest}")
    if raw_tags and len(raw_tags) > 1:
        print("All Tags:")
        for t in raw_tags:
            print(f"  - {t}")

    if compressed_size is not None:
        print(f"Compressed Download Size: {format_size(compressed_size)} ({compressed_size:,} bytes)")
    else:
        print("Compressed Download Size: Not available")

    if uncompressed_size is not None:
        print(f"Uncompressed Disk Size:   {format_size(uncompressed_size)} ({uncompressed_size:,} bytes)")
    else:
        print("Uncompressed Disk Size:   (skipped or unavailable)")

    print(f"Total Layer Count:        {len(layers)}")

    if layers:
        print("\nLayer Breakdown (Compressed):")
        for layer in layers:
            print(f"  Layer {layer['index']:02d}: {layer['digest']:<23} | {layer['size_formatted']:>10} ({layer['size_bytes']:,} B)")

    print("::endgroup::")

    # Write to GitHub Step Summary if running inside GHA
    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_file:
        try:
            with open(summary_file, "a", encoding="utf-8") as f:
                f.write(f"\n### 📦 Docker Image Size Report: `{primary_tag}`\n\n")
                f.write("| Metric | Value |\n")
                f.write("| :--- | :--- |\n")
                f.write(f"| **Target Image** | `{primary_tag}` |\n")
                if args.digest:
                    f.write(f"| **Image Digest** | `{args.digest}` |\n")
                if compressed_size is not None:
                    f.write(f"| **Compressed Size (Download)** | **{format_size(compressed_size)}** ({compressed_size:,} bytes) |\n")
                if uncompressed_size is not None:
                    f.write(f"| **Uncompressed Size (Disk)** | **{format_size(uncompressed_size)}** ({uncompressed_size:,} bytes) |\n")
                f.write(f"| **Total Layers** | {len(layers)} |\n\n")

                if len(raw_tags) > 1:
                    f.write("<details><summary><b>Pushed Tags</b></summary>\n\n")
                    for t in raw_tags:
                        f.write(f"- `{t}`\n")
                    f.write("\n</details>\n\n")

                if layers:
                    f.write("<details><summary><b>Layer Size Breakdown</b></summary>\n\n")
                    f.write("| # | Layer Digest | Compressed Size |\n")
                    f.write("| :---: | :--- | :---: |\n")
                    for layer in layers:
                        f.write(f"| {layer['index']} | `{layer['digest']}` | {layer['size_formatted']} |\n")
                    f.write("\n</details>\n\n")
        except Exception as e:
            print(f"Warning: Failed to write to GITHUB_STEP_SUMMARY: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
