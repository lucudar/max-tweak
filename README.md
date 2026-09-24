# MAXMods — «Потужно»

A [Theos](https://theos.dev/) tweak that rebrands and privacy-hardens the **MAX**
messenger (`ru.oneme.app`), shipped as `MAXMods.dylib` and injected into a
re-signed IPA. The rebranded build is called **Потужно**.

> Personal app-modding project. Everything runs client-side via Objective-C
> runtime swizzling of the app's own `@objc` methods; no server component.

## Features

### Privacy (the «Моды» screen)
Long-press the tab bar to open **Моды**. Toggles are stored on-device and take
effect immediately:

- **Не отправлять «прочитано»** (`mod.read`) — the other side never sees your
  read receipts (dedicated original-IMP hooks on `OKMChatHandler` so turning it
  OFF actually sends them again).
- **Скрывать «печатает…»** (`mod.typing`) — swallow the typing indicator so the
  other side doesn't see you composing.

### Anti-tracking / anonymity
- **All telemetry blocked.** Every MyTracker path (`MRMainTracker`,
  `MREventTracker`, `MRMyTrackerService`) and the central `OKMStatisticsService`
  aggregator that every `*StatService` feeds are hooked to no-ops. Ad/promo
  banners, suggested chats, advertising identifier, install/launch/update
  events, push stats and location writes are all neutralized. (Audit: the app
  bundles **no** third-party analytics SDK — MyTracker is the only family.)
- **Госуслуги / Цифровой ID removed.** The native entry points on `OKMRouter`
  (`_openDigitalIdTabWithReload:…`, `_digitalIdWebAppContainerController`,
  `_showDigitalidTooltipIfNeeded:`) are killed, so the tab never opens and the
  Госуслуги web-app (`goskey.gosuslugi.ru`) is never built. Login (phone+SMS /
  2FA) is a separate flow and is untouched.
- **Calls tab, microphone and camera** are disabled (chat-only messenger); the
  mic/camera usage keys are stripped at repack time so iOS auto-denies access.

### Settings cleanup
Junk / unwanted rows are collapsed to zero height (self-sizing `OMFormKit`
cells via `-preferredLayoutAttributesFittingAttributes:`), so rows below shift
up with no gap: **Цифровой ID**, **Госуслуги** banner, **Потужно for Business**,
**Invite Friends**, **Вернуть уведомления**, **Семейная защита**, **Уведомления**.

### UI / branding
- In-app `MAX`/`Макс` strings rebranded to **Потужно** at runtime (word-boundary
  regex), incl. the CallKit active-call pill.
- Custom **Telegram-style context menu** for chat messages (blur panel, icons,
  haptics, a lifted rounded-corner message snapshot) — replaces the stock
  `UIContextMenuInteraction`, which deadlocked the whole app on delete under
  iOS 26/27 (old-SDK binary vs new iOS). Any interception failure falls back to
  the system menu.
  Lifting the finger that opened the menu is swallowed, so it never "taps" the
  message underneath (e.g. opening the photo viewer).
- Session-persistence fixes for re-signed builds (keychain team group, app-group
  container, `NSUserDefaults` suite).

### Debug
- **Отладка** section: view / share / clear the log, plus a **Запись логов**
  switch (`mod.logs`) that gates all file logging (honored from the first line
  of the constructor — OFF is truly silent).

## Repository layout

| File | Purpose |
|------|---------|
| `Tweak.m` | The entire tweak (single translation unit). |
| `control` | Debian package metadata / version. |
| `Makefile` | Theos build (`ARCHS=arm64`, ARC). |
| `.github/workflows/build.yml` | CI: builds `MAXMods.dylib` on push, publishes a Release. |
| `pack_ipa.py` | Swap the dylib into a base IPA, rebrand display/usage plist keys, inject opaque icons. Produces the final `Potuzhno_*.ipa`. |

> `pack_ipa.py` never touches `CFBundleExecutable` or bundle identifiers — only
> user-visible display / usage-description keys are rebranded.

## Build

Pushing to `master` triggers GitHub Actions (`macos-14` + Theos), which builds
`MAXMods.dylib` and attaches it to a new Release.

```bash
# local Theos build (if you have the toolchain)
make package
```

## Pack the IPA

```bash
python pack_ipa.py <base.ipa> <MAXMods.dylib> <out.ipa>
```

This replaces `Frameworks/Mods.dylib` with the built dylib, rebrands the
display/usage plist keys to «Потужно», and writes opaque-RGB home-screen icons.

## Install

1. Download `MAXMods.dylib` from [Releases](../../releases).
2. Pack it into an IPA with `pack_ipa.py` (or replace `Frameworks/Mods.dylib`
   in an already-injected IPA).
3. Re-sign and install via ESign / AltStore / SideStore.

> **Note:** push notifications cannot work on a re-signed build — APNS requires
> the original App Store provisioning profile's `aps-environment` entitlement
> for `ru.oneme.app`, which is stripped on re-sign. This is a code-signing
> limitation, not a bug.
