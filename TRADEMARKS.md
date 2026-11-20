# Name, logo and branding

The PVJ code is MIT-licensed (see [LICENSE](LICENSE)). The PVJ **brand** is not part of that licence. It belongs to Collective Unconscious (c-u.studio) and covers:

- the name **PVJ** and "PVJ: Portable VJ Mixer";
- the PVJ logo and app icons: `icon.svg`, `branding/*.png`, the launcher icons generated from them;
- the PVJ ident and splash: `demo_clips/pvj-ident-720.mp4`, `demo_clips/pvj-splash-720.mp4`, `branding/pvj-splash-1080.png`;
- the names "Collective Unconscious" and "c-u.studio", and the splash credit that shows them.

The scripts that generate these (`branding/make_icons.py`, `branding/make_ident_icons.py`, `tools/ident/`) are code and come under the MIT licence. The images and clips they produced for PVJ don't.

## What this means in practice

- **Build, study and change PVJ as much as you like.** Private builds and test builds for your own use are fine as they are.
- **If you publish a build** (on an app store, a website, or handed out at events), give it your own name, icon and package ID, and leave out the PVJ ident and splash. It must not look like the official PVJ app.
- **Saying where it comes from is welcome**, e.g. "based on PVJ by Collective Unconscious" in an about screen or README.
- The packages `studio.cu.pvj`, `studio.cu.pvj.debug` and `com.pocketvj.app` are the official builds. Use your own package IDs.

Questions: hello@c-u.studio
