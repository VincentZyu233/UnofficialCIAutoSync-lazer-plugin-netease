#!/usr/bin/env python3
"""
Synchronizes the upstream NetEase plugin distribution from Lazer Plugin Index.
Zero third-party dependencies: strictly uses Python 3 standard library.
"""

import hashlib
import io
import json
import os
import shutil
import sys
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = REPO_ROOT / "manifest.json"

PRIMARY_INDEX_URL = "https://lazer.naominet.dev/plugin/plugins.json"
BACKUP_INDEX_URL = "https://raw.githubusercontent.com/chuxuehaocai/lazer-web/main/public/plugin/plugins.json"

PROTECTED_ENTRIES = {
    ".git",
    ".github",
    "scripts",
    ".gitignore",
    "LICENSE",
}


def fetch_url(url: str, timeout: int = 30) -> bytes:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return response.read()


def fetch_plugin_index() -> dict:
    for url, label in [(PRIMARY_INDEX_URL, "primary"), (BACKUP_INDEX_URL, "backup")]:
        try:
            print(f"Fetching plugin index from {label} source: {url}")
            data = fetch_url(url)
            return json.loads(data.decode("utf-8"))
        except Exception as err:
            print(f"Failed to fetch {label} index ({err}), trying next...", file=sys.stderr)
    raise RuntimeError("All plugin index sources failed.")


def set_github_output(key: str, value: str) -> None:
    output_file = os.environ.get("GITHUB_OUTPUT")
    if output_file:
        with open(output_file, "a", encoding="utf-8") as f:
            f.write(f"{key}={value}\n")
    print(f"[Action Output] {key}={value}")


def sync_readme(src_readme: Path, dest_readme: Path) -> None:
    header_marker = "<!-- UPSTREAM_README_START -->"
    upstream_content = src_readme.read_text(encoding="utf-8", errors="replace")
    if dest_readme.exists():
        current_content = dest_readme.read_text(encoding="utf-8", errors="replace")
        if header_marker in current_content:
            print("Updating upstream section in README.md while preserving custom disclaimer/header...")
            header = current_content.split(header_marker)[0]
            dest_readme.write_text(f"{header}{header_marker}\n\n{upstream_content}", encoding="utf-8")
            return
    dest_readme.write_text(upstream_content, encoding="utf-8")


def main() -> int:
    print("=== Checking for Upstream NetEase Plugin Updates (Python) ===")

    if not MANIFEST_PATH.exists():
        print(f"Error: manifest.json not found at {MANIFEST_PATH}", file=sys.stderr)
        return 1

    with open(MANIFEST_PATH, "r", encoding="utf-8") as f:
        current_manifest = json.load(f)

    current_version = current_manifest.get("version", "0.0.0")
    print(f"Current local version: {current_version}")

    index = fetch_plugin_index()
    plugins = index.get("plugins", index) if isinstance(index, dict) else index
    netease = next((p for p in plugins if p.get("id") == "lazer.netease"), None)

    if not netease:
        print("Error: lazer.netease not found in upstream plugins.json", file=sys.stderr)
        return 1

    upstream_version = netease["version"]
    download_url = netease["download"]
    expected_sha256 = netease.get("sha256", "")

    print(f"Upstream version: {upstream_version}")
    print(f"Download URL: {download_url}")

    set_github_output("current_version", current_version)
    set_github_output("upstream_version", upstream_version)

    if current_version == upstream_version:
        print(f"✓ Up to date! Local version ({current_version}) matches upstream version ({upstream_version}).")
        set_github_output("has_update", "false")
        return 0

    print(f"🚀 New version available: {current_version} -> {upstream_version}")
    set_github_output("has_update", "true")
    set_github_output("download_url", download_url)
    set_github_output("sha256", expected_sha256)

    print(f"Downloading {download_url}...")
    zip_bytes = fetch_url(download_url)

    if expected_sha256:
        actual_sha256 = hashlib.sha256(zip_bytes).hexdigest()
        if actual_sha256.lower() != expected_sha256.lower():
            raise ValueError(f"SHA256 mismatch! Expected {expected_sha256}, got {actual_sha256}")
        print(f"✓ SHA256 verified: {actual_sha256}")

    # Isolated temp extraction directory
    temp_extract_dir = REPO_ROOT / ".tmp_upstream_extract"
    if temp_extract_dir.exists():
        shutil.rmtree(temp_extract_dir, ignore_errors=True)
    temp_extract_dir.mkdir(parents=True, exist_ok=True)

    try:
        print("Unpacking upstream zip using standard library zipfile (pure Python)...")
        with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zf:
            zf.extractall(temp_extract_dir)

        print("Synchronizing plugin files to repository root...")
        for entry in temp_extract_dir.iterdir():
            if entry.name in PROTECTED_ENTRIES:
                print(f"[PROTECTED] Skipping entry {entry.name}")
                continue

            dest_path = REPO_ROOT / entry.name

            if entry.name == "README.md":
                sync_readme(entry, dest_path)
                print(f"Updated: {entry.name}")
                continue

            if dest_path.exists():
                if dest_path.is_dir():
                    shutil.rmtree(dest_path)
                else:
                    dest_path.unlink()

            if entry.is_dir():
                shutil.copytree(entry, dest_path)
            else:
                shutil.copy2(entry, dest_path)

            print(f"Updated: {entry.name}")

    finally:
        if temp_extract_dir.exists():
            shutil.rmtree(temp_extract_dir, ignore_errors=True)

    print("✓ Successfully synchronized upstream files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
