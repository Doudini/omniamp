# OmniAmp

OmniAmp is a tiny, simple music player for macOS, inspired by Winamp.

It's written in Swift with AppKit and AVAudioEngine and has no third-party dependencies.

<p align="center">
  <img src="docs/modern.png" alt="OmniAmp's modern look: LCD display, album art, INFO drawer and playlist" width="430">
  &nbsp;&nbsp;
  <img src="docs/classic.png" alt="OmniAmp's classic look with the original Winamp 2.91 base skin: main window, equalizer and playlist" width="338">
</p>
<p align="center"><sub>The modern look (left) and the classic look with the original Winamp 2.91 skin (right).</sub></p>

## The modern look

A resizable native window with an LCD-style display, album art and the Hack Nerd Font. Pick one of five color themes inspired by old monochrome monitors:
- Green (default)
- Amber
- Blue
- Cyan/Teal
- Monochrome

The **INFO** drawer shows full tags, the file format, the album and cover art. The **EQ** drawer has the 10-band equalizer with presets.

<p align="center"><img src="docs/themes.png" alt="Amber, Blue, Cyan and Monochrome themes with the EQ and INFO drawers"></p>

## The classic look

Real Winamp 2.x skins: pixel-exact main, equalizer and playlist windows at 1×–4× size.
- **Built-in skin:** OmniAmp ships with the original Winamp 2.91 base skin.
- **Your own skins:** drag any `.wsz` onto the window, or use View → Skins → Load Skin….
- **Where to find more:** thousands of skins are at the [Winamp Skin Museum](https://skins.webamp.org).

## Internet radio

Press **RADIO** (or ⌘⌥R) to browse and search thousands of stations from [radio-browser.info](https://www.radio-browser.info). Filter by genre and country, star your favorites, and add stations to the playlist like any other track. Stations are saved in `.m3u`/`.pls` files along with their logos.
- **MP3/AAC/AAC+ (Icecast and SHOUTcast):** play through OmniAmp's own engine, so the EQ and visualizer work. The INFO drawer shows the song currently on air.
- **HLS and Ogg/Opus:** play through the macOS player.
- **Your own stations:** **+ URL** adds any stream or `.pls`/`.m3u` link from a station's website to Favorites.

<p align="center"><img src="docs/radio.png" alt="The Internet Radio window: popular stations with logos, genres, countries and formats" width="700"></p>

## Podcasts

Press **PODCASTS** (or ⌘⌥P) to browse the top shows in your country or search the [Apple Podcasts](https://podcasts.apple.com) directory. Pick a show to see its episodes, subscribe to it, and play or add episodes to the playlist like any other track.
- **Subscriptions:** new episodes are counted under SUBSCRIBED each time you open the window.
- **Resume:** episodes continue where you stopped, and finished ones are marked as played.
- **Playback:** episodes stream through the macOS player, so the EQ and visualizer don't apply to them.
- **Any feed:** **+ FEED** subscribes to shows that aren't in the directory, including private or paid feeds with a personal link.

## Add URL

**ADD → Add URL…** (or ⌘L) takes any link and works out what it is:
- a live stream or a `.pls`/`.m3u` station playlist is added as radio;
- a podcast feed or an Apple Podcasts link opens the show in Podcasts;
- an audio file on the web is added as a track you can seek and resume.

## All features

**Playback**
- **Formats:** MP3, FLAC, ALAC/AAC (M4A), WAV (including RF64), AIFF and CAF, with built-in tag readers. The display shows exactly what's playing, e.g. "FLAC 24-bit / 96 kHz".
- **Gapless playback** between tracks that share a sample format.
- **Bit-perfect mode** (Output menu):
  - Matches the output device to each file's sample rate.
  - Bypasses the EQ and software volume, and uses the device's hardware volume when it has one.
  - Optional exclusive (hog) access.
  - Restores the device's original rate on quit.
- **Output device picker:** play to any output, or follow the system default.
- **ReplayGain:** track or album mode, with clipping protection.
- **CUE sheets:** a single-file album rip plus its `.cue` shows up as separate tracks that play gaplessly. Old Windows-1252 cue files work too.
- **Timers and toggles:**
  - stop after current (⇧V)
  - a sleep timer that fades out
  - resume position for long files and audiobooks
  - always on top

**Playlist**
- **Large folders:** drop in a whole music library; the playlist is kept between launches.
- **Editing:** drag to reorder, a play queue (Q), sorting, and removal of duplicates and missing files.
- **Watched folders:** the playlist follows your music folders live. New files appear next to their folder-mates, deleted files disappear and edited files are re-tagged. Your folder structure is never touched.
- **ADD menu:** Add Files…, Add Folder… and Add URL…, in both looks.
- **Playlist files:** open and save `.m3u`/`.m3u8`/`.pls` files, plus a list of saved playlists.
- **Jump to file (J):** type to search. Enter plays the result and clears the search; ⇧Enter keeps the results.
- **Display options:** choose the playlist font (Hack, Hack Compact or the classic font) and toggle track numbers.

**Scrobbling**
- **[Last.fm](https://www.last.fm) and [ListenBrainz](https://listenbrainz.org)** (Settings, ⌘,): Now Playing updates, standard scrobble rules and an offline queue. Logins are stored in the macOS Keychain.

**Look and feel**
- **Visualizer:** click it to cycle spectrum (with peak hold) → oscilloscope → L/R level meters → off.
- **Time display:** click the time to switch between elapsed and remaining.
- **Now Playing and media keys:** macOS Now Playing and the keyboard media keys work.

## Keyboard shortcuts

| Key | Action | | Key | Action |
|---|---|---|---|---|
| `Z` | Previous | | `J` / ⌘F | Jump to track |
| `X` | Play | | `Q` | Queue selected track |
| `C` | Pause | | ⇧V | Stop after current |
| `V` | Stop | | ← / → | Seek |
| `B` | Next | | Space | Play / pause |
| ⌘O | Add files or folder | | ⌘⌥R | Internet radio |
| ⌘L | Add URL | | ⌘⌥P | Podcasts |

## Get it

OmniAmp is built from source for now; a signed download is planned. You need macOS 14 or later and Xcode (Swift 6).

```sh
git clone https://github.com/Doudini/omniamp.git
cd omniamp
./scripts/make-app.sh   # release build → OmniAmp.app
open OmniAmp.app
```

Drag `OmniAmp.app` into `/Applications` to keep it.

### Last.fm API key (optional)

Last.fm requires every app to have its own API key, so a build made from this repo has Last.fm scrobbling disabled until you add one. ListenBrainz works without a key.

1. Create a free API account at <https://www.last.fm/api/account/create>.
2. Put the key and secret in a `secrets.env` file in the repo root. Git ignores this file, so it is never committed:
   ```sh
   LASTFM_API_KEY=your_key
   LASTFM_SECRET=your_secret
   ```
3. Run `./scripts/make-app.sh`. The key is built into your `OmniAmp.app`.

## Development

```sh
swift build            # debug build
swift test             # unit tests
./scripts/make-app.sh  # release app bundle
```

The app icon's source is `Resources/AppIcon.icon`. Open it in Icon Composer or edit its SVG, then run `./scripts/make-icon.sh`. The ideas we're saving for later are in [BACKLOG.md](BACKLOG.md).

## Credits

- **Fonts:** [Hack](https://github.com/source-foundry/Hack) and [Fira Code](https://github.com/tonsky/FiraCode), bundled as [Nerd Fonts](https://www.nerdfonts.com). Their licenses are in `fonts/`.
- **Classic skin:** the base skin is Winamp 2.91's original skin by Nullsoft.
- **Radio directory:** provided by the community-run [radio-browser.info](https://www.radio-browser.info).
- **Podcast directory:** Apple's podcast search and charts.
- **Screenshots:** the albums shown are fictional; their audio and covers were generated for these images.

OmniAmp is an independent project and is not affiliated with Winamp or Nullsoft.
