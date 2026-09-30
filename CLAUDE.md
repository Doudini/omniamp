# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

OmniAmp is a Winamp-style music player for macOS 14+: Swift 6, AppKit, AVAudioEngine, system SQLite, **no third-party dependencies** (keep it that way). A single SwiftPM executable target (`Sources/OmniAmp`) plus one XCTest target. User-facing features are documented in README.md; deferred ideas are in BACKLOG.md.

## Commands

```sh
swift build                                  # debug build (a data race is a compile error: Swift 6 language mode)
swift build -c release                       # what CI also checks
./scripts/make-app.sh                        # release OmniAmp.app (icon, fonts as TTF, skin, Info.plist, signing)
./scripts/make-dmg.sh 0.4                    # dist/OmniAmp-0.4.dmg
./scripts/release.sh 0.4                     # maintainers: tag + GitHub release (needs the "OmniAmp Code Signing" cert)
./scripts/make-icon.sh                       # after editing Resources/AppIcon.icon
```

Tests — run them with the same environment CI uses, so the real playlist, prefs and Keychain are untouched and nothing is audible:

```sh
OMNIAMP_CACHE_DIR=$(mktemp -d) OMNIAMP_NO_AUTOPLAY=1 OMNIAMP_KEYCHAIN_SERVICE=OmniAmpTest swift test
swift test --filter CueTests                 # one test class
swift test --filter CueTests/testParse       # one test
```

(CI also sets `OMNIAMP_VOLUME=0`; don't export that in a shell used for `OMNIAMP_RECORD` audio checks — it zeroes the mixer before the recording tap.) Test runs of the bare binary write the `OmniAmp` defaults domain (`defaults delete OmniAmp` afterwards); the `.app` uses `com.microbot.omniamp`.

There is no linter; the compiler's Swift 6 concurrency checking is the gate.

## Architecture

**Entry and shell.** `App/main.swift` preloads the playlist cache (`LibraryCache.preload()`) while AppKit starts, then `App/AppDelegate.swift` owns the menus, window switching and all `OMNIAMP_*` test hooks.

**One controller, two looks.** `Core/PlayerController` holds all playback and playlist logic (play order, shuffle history, play queue, gapless preloading, EQ settings, watched playlist folders via `FolderSync`). Each look implements the `PlayerUI` protocol (defined at the top of PlayerController.swift) and only renders: `UI/Modern/*` (custom-drawn, Hack Nerd Font, themes) and `UI/Classic/*` (pixel-exact Winamp 2.x `.wsz` skins parsed by `Skin/`). Put behavior in the controller, not in a look.

**Audio.** `Audio/AudioPlayer` is the AVAudioEngine graph: player node → converter → EQ → main mixer → device. Gapless = scheduling the next file on the same running node (same format) or on a pre-started `spare` node (different format). Bit-perfect mode switches the device sample rate per file, bypasses EQ and software volume, optionally hogs the device. Icecast/SHOUTcast MP3/AAC radio goes through `StreamSource` into the engine; HLS, Ogg/Opus and podcasts go through AVPlayer (no EQ/visualizer). Device queries live in `AudioDevices` (Core Audio HAL).

**Playlist side (`Library/`).** `PlaylistStore` + `Track`; `LibraryCache` is the fast binary cache that makes 10k+ track playlists open instantly (instant loading of huge folders is the project's original top priority — don't regress it). Own tag readers (`TagReader`, `ContainerTags`, `DetailsReader`), `TagWriter`, CUE sheets, m3u/pls, folder watching (FSEvents).

**Music Library (`Collection/`)** is separate from the playlist: `MusicCollection.shared` watches the user's library roots (often an NFS NAS), `CollectionScanner` reads new/changed files off the main thread and writes to `CollectionDB` (`<cache dir>/collection.sqlite`, via the thin `SQLite.swift` wrapper over `import SQLite3`) through one serial queue. `ReleaseClassifier` sorts official albums vs live shows/bootlegs/demos (etree-style `YYYY-MM-DD Venue` folders). **Bump `CollectionDB.contentVersion` whenever classifier or tag-reading rules change** so existing rows are re-read (a bump re-reads every file, which is slow over NFS). `LibraryWindow` + `*Page.swift` + `StatsViews` are the browser; `MetadataLookup`/`Discography`/`LiveArchive` hit MusicBrainz and archive.org (MusicBrainz is rate-limited through a shared ~1.25 s gate); `ListeningDB`/`ListeningHistory` import last.fm scrobbles.

**Other features:** `Radio/` (radio-browser.info), `Podcasts/` (Apple + fyyd directories, downloads, OPML), `Scrobbling/` (Last.fm, ListenBrainz, offline queue, Keychain), `App/Updater` (GitHub Releases, verifies checksum + code-signing requirement), `App/AddURL` + `Library/URLProbe` (classify a pasted URL).

**UI tokens.** `UI/Theme.swift` has palettes × finishes (`Finish`) and `ChartPalette`; `UI/Dash.swift` holds the library's dynamic design tokens (they repaint via `Dash.restyle`). Library charts draw data in `Dash.amount`/`Dash.compare`, never the theme's phosphor accent.

**Prefs.** Every UserDefaults key is in `Core/Pref.swift`; the strings are persisted on users' machines — never rename one without a migration.

## Rules that aren't obvious from the code

- **Concurrency (Swift 6 mode):** UI classes and controllers are `@MainActor`; pure helpers are nonisolated. Closures that Apple frameworks call on their own threads (audio render/tap/stream callbacks, KVO, `MPRemoteCommand` handlers, `MPMediaItemArtwork`) must be created outside main-actor code (a `nonisolated static` helper) or be `@Sendable`, then hop to main — otherwise they trap at runtime. Shared mutable statics go behind `OSAllocatedUnfairLock` or a small locked holder. Notification observers go in `Observers` (Core/Observers.swift), not a deinit. Network clients are `@MainActor` with an injectable `Sendable` `HTTPTransport` (Scrobbler.swift) — tests stub it. The Swift 6.4 checker has crashed on a closure chosen inline with `?:` inside a call; use plain statements.
- **Never call `AVAudioPlayerNode.lastRenderTime`** (or anything waiting for an IO cycle) on the main thread: it deadlocks against AVAudioEngine's config-change handler during rate switches/hog. Position comes from AudioPlayer's host-time clock; output latency from `AudioDevices.outputLatency`.
- **Music paths:** use `URL(exactPath:)`, `appendingExact` and `ExactPath.kind/exists/resolved` (Library/ExactPath.swift), never `URL(fileURLWithPath:)`/`appendingPathComponent`/FileManager path strings — those decompose NFC accents and the file on the NAS "doesn't exist". APFS can't reproduce this.
- **Untrusted downloads** (feeds, logos, anything from user-editable directories) go through `Core/BoundedFetch` with a size and time limit.
- **Tests:** `@MainActor` test classes use `override func setUp() async throws` / `tearDown() async throws`; results from callbacks go through a lock. Unit tests never use the real cache dir even without `OMNIAMP_CACHE_DIR`.
- **Test the `.app` for network features**, not just `.build/*/OmniAmp`: the bare binary has no Info.plist, so App Transport Security (plain-http radio) doesn't apply to it.
- **Launch test instances with `OMNIAMP_BACKGROUND=1`**: without it the app activates and takes the keyboard, and what the user is typing elsewhere lands in it. Screenshot by window id instead.
- **Never stop test instances by name** (`pkill -x OmniAmp`): the user's own OmniAmp may be running. Keep the test PID and kill that (SIGTERM is handled and restores the device rate/hog).
- After runtime tests, check `~/Library/Logs/DiagnosticReports` for new `OmniAmp*.ips` — that's how a main-actor isolation trap shows up.

## Test hooks (environment variables)

Read in AppDelegate/AudioPlayer; grep `OMNIAMP_` for the full list. Most useful:
- `OMNIAMP_CACHE_DIR` throwaway cache/DB dir · `OMNIAMP_NO_AUTOPLAY=1` · `OMNIAMP_KEYCHAIN_SERVICE=OmniAmpTest` (required with a last.fm key, or the dev binary blocks on a Keychain prompt)
- `OMNIAMP_MODE=classic|modern` · `OMNIAMP_THEME=color:finish` · `OMNIAMP_CHARTS=id[:cb]`
- `OMNIAMP_PLAY=<row>` · `OMNIAMP_VOLUME=0` · `OMNIAMP_RECORD=<file.caf>` (post-EQ audio to disk; per-rate files in bit-perfect) · `OMNIAMP_DEBUG=1` (engine start log) · `OMNIAMP_SETTLE_TIMEOUT`
- `OMNIAMP_LIBRARY=section[:entry]` (e.g. `shows:Grateful Dead`), `OMNIAMP_RADIO=favorites`, `OMNIAMP_PODCASTS`, `OMNIAMP_SETTINGS`, `OMNIAMP_ABOUT=1`, `OMNIAMP_BACKGROUND`
- `OMNIAMP_LASTFM_KEY` / `OMNIAMP_LASTFM_SECRET`; builds read them from `secrets.env` (git-ignored; never print or commit it)

## Conventions

- Comments explain *why* in plain sentences; match the existing density.
- Commit messages are a single descriptive prose line starting with the area (e.g. `Bit-perfect: …`, `Modern look: …`), describing the user-visible effect.
