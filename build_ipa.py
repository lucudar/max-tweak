#!/usr/bin/env python3
"""
Auto-build MAX messenger IPA with MAXMods tweak injected.
Downloads latest dylib from GitHub releases, injects into IPA, re-signs.
"""
import os
import sys
import json
import shutil
import zipfile
import subprocess
import urllib.request
from pathlib import Path

REPO = "lucudar/max-tweak"
DYLIB_NAME = "MAXMods.dylib"
FRAMEWORKS_DIR = "Payload/MAX.app/Frameworks"

def download_latest_dylib(output_path="MAXMods.dylib"):
    """Download the latest dylib from GitHub releases."""
    print("📥 Downloading latest MAXMods.dylib from GitHub...")

    api_url = f"https://api.github.com/repos/{REPO}/releases/latest"

    try:
        with urllib.request.urlopen(api_url) as response:
            release_data = json.loads(response.read().decode())

        dylib_url = None
        for asset in release_data.get("assets", []):
            if asset["name"] == DYLIB_NAME:
                dylib_url = asset["browser_download_url"]
                break

        if not dylib_url:
            print(f"❌ {DYLIB_NAME} not found in latest release")
            return False

        print(f"   Release: {release_data['tag_name']}")
        print(f"   URL: {dylib_url}")

        urllib.request.urlretrieve(dylib_url, output_path)
        print(f"✅ Downloaded to {output_path}")
        return True

    except Exception as e:
        print(f"❌ Failed to download: {e}")
        return False

def find_max_ipa():
    """Find MAX IPA file in current directory or Downloads."""
    candidates = []

    # Check current directory
    for f in Path(".").glob("*.ipa"):
        if "MAX" in f.name or "oneme" in f.name.lower():
            candidates.append(f)

    # Check Desktop
    desktop = Path.home() / "Desktop"
    if desktop.exists():
        for f in desktop.glob("*.ipa"):
            if "MAX" in f.name or "oneme" in f.name.lower():
                candidates.append(f)

    # Check Downloads
    downloads = Path.home() / "Downloads"
    if downloads.exists():
        for f in downloads.glob("*.ipa"):
            if "MAX" in f.name or "oneme" in f.name.lower():
                candidates.append(f)

    if candidates:
        return candidates[0]
    return None

def inject_dylib_into_ipa(ipa_path, dylib_path, output_ipa="MAX_Modded.ipa"):
    """Inject dylib into IPA and add LC_LOAD_DYLIB to Mach-O."""
    print(f"\n🔧 Injecting {dylib_path} into {ipa_path}...")

    # Create temp directory
    temp_dir = Path("temp_ipa_build")
    if temp_dir.exists():
        shutil.rmtree(temp_dir)
    temp_dir.mkdir()

    try:
        # 1. Extract IPA
        print("   Extracting IPA...")
        with zipfile.ZipFile(ipa_path, 'r') as zip_ref:
            zip_ref.extractall(temp_dir)

        # 2. Find .app bundle
        payload_dir = temp_dir / "Payload"
        app_bundles = list(payload_dir.glob("*.app"))
        if not app_bundles:
            print("❌ No .app bundle found in IPA")
            return False

        app_bundle = app_bundles[0]
        print(f"   Found app: {app_bundle.name}")

        # 3. Create Frameworks directory if needed
        frameworks_dir = app_bundle / "Frameworks"
        frameworks_dir.mkdir(exist_ok=True)

        # 4. Copy dylib
        target_dylib = frameworks_dir / dylib_path.name
        shutil.copy2(dylib_path, target_dylib)
        print(f"   ✅ Copied dylib to Frameworks/")

        # 5. Find main executable
        exec_name = app_bundle.stem
        executable = app_bundle / exec_name
        if not executable.exists():
            print(f"❌ Executable not found: {executable}")
            return False

        # 6. Add LC_LOAD_DYLIB to Mach-O (using optool if available, otherwise manual)
        dylib_load_path = f"@executable_path/Frameworks/{dylib_path.name}"
        print(f"   Adding load command: {dylib_load_path}")

        # Try optool first
        try:
            subprocess.run([
                "optool", "install", "-c", "load",
                "-p", dylib_load_path, "-t", str(executable)
            ], check=True, capture_output=True)
            print("   ✅ Added LC_LOAD_DYLIB via optool")
        except (FileNotFoundError, subprocess.CalledProcessError):
            print("   ⚠️  optool not found - you'll need to add LC_LOAD_DYLIB manually")
            print(f"      Or use: insert_dylib '{dylib_load_path}' '{executable}'")

        # 7. Repackage IPA
        print(f"   Repackaging to {output_ipa}...")
        with zipfile.ZipFile(output_ipa, 'w', zipfile.ZIP_DEFLATED) as zip_out:
            for root, dirs, files in os.walk(temp_dir):
                for file in files:
                    file_path = Path(root) / file
                    arcname = file_path.relative_to(temp_dir)
                    zip_out.write(file_path, arcname)

        print(f"✅ Created: {output_ipa}")
        return True

    finally:
        # Cleanup
        if temp_dir.exists():
            shutil.rmtree(temp_dir)

def main():
    print("=" * 60)
    print("  MAX Messenger IPA Builder with MAXMods Tweak")
    print("=" * 60)

    # Step 1: Download dylib from GitHub
    dylib_path = Path(DYLIB_NAME)
    if not dylib_path.exists():
        if not download_latest_dylib(dylib_path):
            sys.exit(1)
    else:
        print(f"✅ Found existing {DYLIB_NAME}")

    # Step 2: Find MAX IPA
    if len(sys.argv) > 1:
        ipa_path = Path(sys.argv[1])
    else:
        ipa_path = find_max_ipa()

    if not ipa_path or not ipa_path.exists():
        print("\n❌ MAX IPA not found!")
        print("   Usage: python build_ipa.py <path_to_max.ipa>")
        print("   Or place MAX IPA in current directory/Desktop/Downloads")
        sys.exit(1)

    print(f"\n📦 Using IPA: {ipa_path}")

    # Step 3: Inject and build
    output_ipa = f"MAX_Modded_{dylib_path.stem}.ipa"
    if inject_dylib_into_ipa(ipa_path, dylib_path, output_ipa):
        print("\n" + "=" * 60)
        print(f"✅ SUCCESS! Modded IPA ready: {output_ipa}")
        print("=" * 60)
        print("\n📝 Next steps:")
        print("   1. Sign with your certificate (ESign/AltStore/Sideloadly)")
        print("   2. Install via AltStore/SideStore")
        print("   3. Check logs: Settings → MaxMods → View Logs")
    else:
        print("\n❌ Build failed")
        sys.exit(1)

if __name__ == "__main__":
    main()
