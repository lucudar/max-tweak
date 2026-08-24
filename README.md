# MAXMods

Tweak for MAX messenger (ru.oneme.app) — ghost mode, anti-delete, force save media, remove ads.

## Features

- **Ghost Mode** — hide read receipts, typing indicators, online status
- **Anti-Delete** — intercept remotely deleted messages, keep them locally
- **Force Save Media** — bypass download/forward restrictions
- **Remove Ads** — hide banners, promoted content, suggested chats

## Build

Builds automatically via GitHub Actions on push to `main`.
Download `MAXMods.dylib` from workflow artifacts.

## Install

1. Download `MAXMods.dylib` from [Actions](../../actions) artifacts
2. Run: `python inject_dylib.py path/to/MAX.app/MAX MAXMods.dylib`
3. Re-sign IPA with ESign
4. Install via AltStore/SideStore

## Settings

Shake your phone while in MAX to open the MAXMods settings menu.
