# PVJ

**PVJ, a portable VJ mixer for Android.** Clip banks play through live GLSL shaders on a BPM sequencer, with projection masks and warps, and the phone drives a projector over USB-C → HDMI while keeping its own screen for the controls. By [Collective Unconscious](https://c-u.studio).

- Public app on Google Play: "PVJ: Portable VJ Mixer" (`studio.cu.pvj`), page at [c-u.studio/tools/pvj](https://c-u.studio/tools/pvj).
- **Open source** under the MIT licence (the PVJ name and branding excepted, see below). It started as the code shared with the Logos developers building [pvj-logos-link](https://github.com/c-ustudio/pvj-logos-link).

## Builds

One codebase, three Android builds, chosen by export preset and Gradle flavor:

| Build | Package | Export preset | What's in it |
| --- | --- | --- | --- |
| Public | `studio.cu.pvj` | `VJMIX Mobile` | The Play Store app: no network code, camera + microphone only |
| Pro | `com.pocketvj.app` | `VJMIX Mobile Pro` | Adds OSC in/out, the phone ⇄ TouchDesigner video link, LED/DDP output, MediaPipe tracking, Google Drive import |
| Debug | `studio.cu.pvj.debug` | `VJMIX Mobile Debug` | For device tests; installs next to the real app |

Pro-only code is gated by `core/features.gd` (`FeaturesS.is_pro()`), and `tools/release_build.sh <version> check` fails if network code ends up in a public artifact.

## Build it

- **Godot 4.6.3 stable**, GDScript only, GL Compatibility renderer. Android export needs the Android SDK, JDK 17 and Godot's Android build template (**Project → Install Android Build Template**). Keep `android/build/src/main/java/com/pocketvj/`: those are PVJ's Kotlin plugins (HDMI presentation, EGL bridge, storage, video link, tracking).
- Video decoding uses the bundled [GDE GoZen](addons/gde_gozen) extension (FFmpeg).
- **Machine paths:** copy `tools/local.env.example` to `tools/local.env` (git-ignored) and fill in your Godot binary, Android SDK and bundletool. Or export the same variables in your shell.
- **Debug build** (easiest, signed with the editor's debug keystore): `tools/release_build.sh <version> debug` → `dist/`. `<version>` must match `version/name` in `export_presets.cfg`.
- **Release builds** (`public`, `pro`) need your own release keystore. Point `PVJ_KEYS_ENV` at a file outside the repo that exports `GODOT_ANDROID_KEYSTORE_RELEASE_PATH`, `_USER` and `_PASSWORD`. Publish under your own package ID, name and icon ([TRADEMARKS.md](TRADEMARKS.md)).
- Headless checks: `"$GODOT" --headless --path . --script tools/verify_<name>.gd`.

### First build from a fresh clone

Steps the list above takes for granted (checked on a fresh clone, Windows 11 + WSL Ubuntu):

1. **Run the build script from WSL** (or Linux). It calls `wslpath`, `taskkill.exe`, `python3`, `unzip` and `sha256sum`; Git Bash and PowerShell won't do. On WSL, point `GODOT` at the Windows `*_console.exe`.
2. **`tools/local.env` also wants `JAVA`** (apksigner and bundletool run on it; Android Studio's bundled `jbr` is fine), and the SDK needs **build-tools 37.0.0** exactly.
3. **Godot's editor settings** (Editor Settings → Export → Android) need the Android SDK path and the Java SDK path (JDK 17). A headless export reads them from the editor settings, not from `local.env`.
4. **Install the Android build template, then restore PVJ's files.** The clone tracks `android/.build_version` and PVJ's hand-edited `android/build/build.gradle`, so it already *looks* installed to Godot, but the Gradle project isn't there. Install it (Project → Install Android Build Template; or unzip `android_source.zip` from your 4.6.3 export templates into `android/build/` and add an empty `android/build/.gdignore`). That overwrites `android/build/build.gradle` and `android/build/src/main/AndroidManifest.xml`; put them back with `git checkout -- android/build`. `git status` should then be clean.
5. **Turn on the pre-commit hook:** `git config core.hooksPath tools/hooks`.
6. **The first export takes longer:** with no `.godot/` yet, Godot imports every asset first. If an export dies silently ("export produced no …apk"), run it once more.
7. **Expected exit codes:** `debug` exits 0. `pro` and `check` exit 1 on `ELF NOT 16 KB` for the MediaPipe `libmediapipe_tasks_vision_jni.so` / `libimage_processing_util_jni.so` (upstream, known); look for the `sha256` line. Exit 3 or 4 is a real failure.
- **Google Drive import (Pro)** needs your own OAuth client: copy `secrets/drive_oauth.example.cfg` to `secrets/drive_oauth.cfg` (git-ignored). Without it everything else works and Drive sign-in says it isn't configured.

## Where things are

```
scenes/, scripts/        the app (pipeline.gd is the main scene script)
core/                    features (public/Pro), shared services
shaders/                 the effect shaders
android/                 Kotlin plugins, tracking assets
addons/gde_gozen/        video decoding (LGPL-2.1, FFmpeg)
third_party/             GoZen + FFmpeg source info and licence texts (LGPL)
td/                      TouchDesigner side of the phone ⇄ TD link
tools/                   build script, headless verify scripts, helpers
*_SPEC.md, docs/         design specs
```

The specs describe features that are built. They sometimes reference internal session notes (`SESSION_NN_NOTES.md`) and planning documents that are not included here.

**Not included:** the Pro build's HUD and HUD Rings effects. Their shaders port non-commercial Shadertoy code, so the app simply leaves them out of the FX list when the files are missing (see [THIRD_PARTY.md](THIRD_PARTY.md)).

## Control PVJ from outside

PVJ Pro listens for OSC on UDP 4855 and can send its state back (`/pvj/out/...`). The namespace is in [OSC_NAMESPACE_SPEC.md](OSC_NAMESPACE_SPEC.md): tempo, sequence slots, modes, crossfader, lane B, clip next/previous/pick, ASCII text. [pvj-logos-link](https://github.com/c-ustudio/pvj-logos-link) uses it to drive PVJ from Logos Basecamp Chat.

## Contributing

Issues and pull requests are welcome. Keep changes on a branch, say what you verified and on which phone, and add or extend a `tools/verify_*.gd` check for what you change. Please don't add code ported from Shadertoy or other non-commercial sources; add any new third-party component to [THIRD_PARTY.md](THIRD_PARTY.md). Security issues: hello@c-u.studio rather than a public issue.

## Licence

- **Code and docs:** [MIT](LICENSE), © 2026 Collective Unconscious (c-u.studio).
- **Name and branding:** the PVJ name, icons, ident and splash are not covered by the MIT licence. Builds you publish need their own name and icon, see [TRADEMARKS.md](TRADEMARKS.md).
- **Demo clips:** [CC BY-NC 4.0](demo_clips/LICENSE.md), like the PVJ starter packs.
- **Third-party components** keep their own licences: [THIRD_PARTY.md](THIRD_PARTY.md).
