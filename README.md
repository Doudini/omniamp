# OmniAmp

A small, fast, Winamp-inspired MP3/FLAC player for macOS, written in Swift with AppKit and AVAudioEngine. It has no third-party dependencies.

## Features

- **Instant playlists:** drop a folder and 10,000 tracks show up in about 0.2 s. Tags are read in parallel in the background, and the playlist is cached, so relaunching restores it in about 20 ms.
- **Two looks,** switchable from the View menu:
  - **Modern:** a resizable native window with an LCD-style display and the Hack Nerd Font.
  - **Classic:** loads real Winamp 2.x `.wsz` skins with pixel-exact main, equalizer and playlist windows at 1×–4× size.
- **Gapless playback** between tracks that share a sample format.
- **10-band equalizer** with preamp and presets, available in both looks.
- **Playlists:** open and save `.m3u`/`.m3u8`/`.pls` files, plus a list of saved playlists.
- **Winamp keys** (`Z X C V B`, `J` to jump to a file), media keys and Now Playing.

## Build

Requires macOS 14+ and Xcode / Swift 6.

```sh
swift build            # debug build
swift test             # unit tests
./scripts/make-app.sh  # release build → OmniAmp.app (icon: `swift scripts/make-icon.swift` after editing omniamp.svg)
open OmniAmp.app
```

To use classic skins, drag any `.wsz` onto the window or use View → Skins → Load Skin…. Thousands of skins are available at the [Winamp Skin Museum](https://skins.webamp.org).

## Fonts

This repo bundles [Hack](https://github.com/source-foundry/Hack) and [Fira Code](https://github.com/tonsky/FiraCode) as [Nerd Fonts](https://www.nerdfonts.com). Their licenses are in `fonts/`.
