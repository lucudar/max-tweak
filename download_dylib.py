#!/usr/bin/env python3
import requests
import sys

repo = "lucudar/max-tweak"
print(f"Checking {repo} for builds...")

# Check releases
releases_url = f"https://api.github.com/repos/{repo}/releases"
r = requests.get(releases_url)

if r.status_code == 200:
    releases = r.json()
    if releases:
        print(f"\nFound {len(releases)} release(s):")
        for rel in releases[:5]:
            print(f"  - {rel['tag_name']}: {rel['name']}")
            for asset in rel['assets']:
                print(f"    * {asset['name']}: {asset['browser_download_url']}")
    else:
        print("No releases found yet.")
else:
    print(f"Cannot access releases (status {r.status_code})")

print("\nTo trigger a build, just make any change and push to master.")
print("The workflow will automatically create a release with the .dylib file.")
