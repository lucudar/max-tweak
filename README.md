# MAXMods

Tweak for MAX messenger (ru.oneme.app) — session persistence fixes + custom
Telegram-style context menu for chat messages.

## Why

Long-press → «Удалить» froze the whole app on iOS 26/27: the stock system
context menu (`UIContextMenuInteraction` on every `MessageCell`) deadlocks when
the message is removed from the collection while the menu dismissal transition
is still running (old-SDK binary vs new iOS).

## What v4.0 does

- Replaces the **system** context menu for chat messages with a custom
  Telegram-style overlay (blur panel, icons, lifted message snapshot, haptics):
  iOS never starts a system context menu for message cells, so the deadlock
  path is gone entirely.
- Menu items and their handlers are the app's own actions (`provideActionsForMessage:`),
  so delete/edit/reply/pin/forward — including confirmation alerts — work
  unchanged.
- Any interception failure falls back to the stock system menu.
- Session persistence fixes for re-signed builds (keychain team group,
  app-group container, `NSUserDefaults` suite).

## Build

Builds automatically via GitHub Actions on push to `master`.
Download `MAXMods.dylib` from the latest Release.

## Install

1. Download `MAXMods.dylib` from [Releases](../../releases)
2. Inject it into the app binary with a local `inject_dylib.py` helper
   (kept outside this repo; it copies the dylib to `Frameworks/` and adds
   `LC_LOAD_DYLIB` to the Mach-O header — or just replace
   `Frameworks/MAXMods.dylib` if already injected)
3. Re-sign IPA with ESign
4. Install via AltStore/SideStore

> **Important:** do not ship this together with the old `Mods.dylib` (v6) —
> its mass-swizzle hooks `_deleteMessage:context:` across all classes and
> blocks deletion by default.
