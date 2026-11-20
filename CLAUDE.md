# PVJ (PocketVJ) — notes for Claude Code

Start with `README.md`, then the spec for whatever you touch (`*_SPEC.md` at the top level, `docs/`). The specs cite internal session notes (`SESSION_NN_NOTES.md`) and planning docs that are not part of this repository; roadmap and unbuilt-feature specs stay in the maintainers' private repo, so don't add them here.

## What this is

PVJ, "Portable VJ Mixer": a Godot 4.6.3 (stable) app, **GDScript only**, GL Compatibility renderer, for Android phones driving a projector over USB-C → HDMI. One codebase, three builds:

| Build | Package | Export preset |
| --- | --- | --- |
| Public (Google Play) | `studio.cu.pvj` | `VJMIX Mobile` |
| Pro (sideloaded) | `com.pocketvj.app` | `VJMIX Mobile Pro` |
| Debug (device tests only) | `studio.cu.pvj.debug` | `VJMIX Mobile Debug` |

Pro-only code is gated by `FeaturesS.is_pro()` / `Features.*` (`core/features.gd`) and the Gradle `tier` flavor. The public build must never contain Pro network code: `tools/release_build.sh <v> check` enforces it (exit 4) along with the permission allowlist.

## Rules

- Work on a branch and open a pull request; don't push to `main` directly.
- Ask before pushing, merging, or uninstalling anything on a device.
- Never commit keystores, `.env` files or `secrets/drive_oauth.cfg`. Signing keys live outside the repo and reach the build through environment variables (`PVJ_KEYS_ENV`).
- `android/build/src/main/java/com/pocketvj/` (the Kotlin bridges) must stay tracked; Godot regenerates the rest of `android/build/`.
- OSC and other inputs drive the SAME functions the UI calls; no parallel state machines (`OSC_NAMESPACE_SPEC.md` §5).
- Version name and code live in `export_presets.cfg`, not in the build script.
- The pre-commit hook (`core.hooksPath = tools/hooks`) checks DDP drift; don't bypass it.
- Licences: code is MIT; the PVJ name, icons, ident and splash are not (`TRADEMARKS.md`); demo clips are CC BY-NC 4.0. Don't add code ported from Shadertoy or other non-commercial sources (that's why the HUD shaders are absent, `THIRD_PARTY.md`), and add any new third-party component to `THIRD_PARTY.md`.
- No personal paths, device serials, home IPs or account details in commits: use placeholders like `<you>`, `<P8-ip>`.

## Commands (from WSL)

- Machine paths: copy `tools/local.env.example` to `tools/local.env` (git-ignored) and fill in `GODOT`, `ANDROID_SDK`, `BUNDLETOOL`, `PVJ_KEYS_ENV`. The build script has no personal defaults.
- Headless checks: `"$GODOT" --headless --path . --script tools/verify_<name>.gd` (some are scenes: `"$GODOT" --headless --path . res://tools/verify_<name>.tscn`). Add or extend a `tools/verify_*.gd` for anything you change.
- Headless `--script` traps: autoload names (`Storage`, `ClipLibrary`, `BeatClock`) don't resolve, and naming the `ClipEngine` type compiles it too. Use untyped `Node` variables and `root.get_node("Storage")`; give locals explicit types. A headless run never cuts a clip (read the cued index) and never compiles shaders: after a shader edit run `"$GODOT" --path . --rendering-driver opengl3 res://tools/shader_probe.tscn` and grep for `SHADER ERROR`.
- Builds: `tools/release_build.sh <version> pro|debug|public|all|check` → `dist/`. Pro always exits 1 (the MediaPipe `.so` are 4 KB ELF, known); check for the `sha256` line instead. An export sometimes dies silently ("export produced no …apk"): retry once.
- Devices: tested on a Pixel 8 and a Pixel 9a (Android 13+). Launch with `adb shell am start --display 0 -n <package>/com.godot.game.GodotAppLauncher`. Device sessions: the `pvj-device-bench` skill in `.claude/skills/`.

## Device-testing traps (from past sessions)

- The auto-hiding editor strip eats the first tap: tap, capture, check, tap again.
- adb can't do multitouch; the nudge pad and NUM panels are the verification path.
- A keyguard-locked phone lets launches "succeed" with nothing rendering.
- With HDMI attached, look for the periodic `blit … fps` log line, not just `TEXTURE OUTPUT LINK: ok`.
- A USB-connected phone needs the Windows `adb.exe`, and goes `unauthorized` after every export (see the `pvj-device-bench` skill, §1).
- `M8Dialog.prompt` raises a numeric keypad, with no `:` and no letters, and `adb shell input text` silently loses those characters too. Call `set_keyboard()` for anything else, and check typed fields on a screenshot.

## Records

Say in the pull request what changed, what was verified on which device, and what is still owed.

## Neighbours

- [`c-ustudio/pvj-logos-link`](https://github.com/c-ustudio/pvj-logos-link): the Logos ⇄ OSC bridge, a separate repo that drives PVJ through its OSC namespace.
