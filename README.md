# NowPlayingFullArt — Plexamp Edition

Dylib tweak that adds full-screen animated Lock Screen artwork to **Plexamp** on iOS 26.

Hooks `MPNowPlayingInfoCenter.setNowPlayingInfo:` and injects `MPMediaItemAnimatedArtwork`
with a 3:4 portrait preview (blurred background + centered cover) and a subtle zoom-loop video.

## How it works

1. Intercepts every now-playing update from Plexamp
2. Extracts the static album artwork
3. Composites a 3:4 portrait: blurred stretched background + centered square cover
4. Renders a 3-second H.264 zoom loop (cosine-eased so the seam is invisible)
5. Attaches both via `MPMediaItemAnimatedArtwork` under the `3x4` key
6. iOS 26 displays it full-screen on the Lock Screen with Liquid Glass

## Build (no Mac needed)

1. Fork this repo on GitHub
2. Go to **Actions** → **Build Dylib** → **Run workflow**
3. Download the `NowPlayingFullArt` artifact — it contains the `.dylib`

## Install

1. Get a **decrypted** Plexamp IPA (e.g. from decrypt.day)
2. Open **Sideloadly** on Windows
3. Load the Plexamp IPA
4. **Advanced Options** → **Tweak injection** → click **+** → select `NowPlayingFullArt.dylib`
5. Enter your Apple ID, connect your iPhone via USB
6. Click **Start** to sign and install

> **Note:** Free Apple ID signing expires every 7 days. Use AltStore's auto-refresh
> or a paid Apple Developer account ($99/year) for 1-year signing.

## Config (optional)

Edit `Sources/NowPlayingFullArt.swift` → `NPAConfig`:

| Setting        | Default   | Notes                                              |
|----------------|-----------|----------------------------------------------------|
| `animate`      | `true`    | `false` = static still, cheaper but still full-bleed |
| `loopSeconds`  | `3.0`     | Zoom loop duration                                 |
| `zoomAmplitude`| `0.05`    | 5% zoom swing                                      |
| `previewSize`  | 900×1200  | Must be 3:4                                        |
| `videoSize`    | 720×960   | Must be 3:4                                        |

## Requirements

- iOS 26 on the target device
- Xcode 26+ for building (GitHub Actions provides this)
- Decrypted Plexamp IPA for injection
- Sideloadly on Windows for installation

## Credits

Inspired by [NPFArt](https://github.com/chdc0/NPFArt). Rewritten from scratch for Plexamp.
