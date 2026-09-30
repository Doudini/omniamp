# OmniAmp

OmniAmp is a music player for macOS inspired by Winamp, made for collectors of bootlegs and live recordings. Its music library tells official albums apart from live shows, bootlegs and demos, and sorts shows by date and venue.

It's written in Swift with AppKit and AVAudioEngine and has no third-party dependencies.

<p align="center">
  <img src="docs/modern.png" alt="OmniAmp's modern look in the Green theme: 7-segment time display, spectrum, album art, hi-fi keys and playlist" width="330">
  &nbsp;&nbsp;
  <img src="docs/classic.png" alt="OmniAmp's classic look with the original Winamp 2.91 base skin: main window, equalizer and playlist" width="337">
</p>
<p align="center"><sub>The modern look (left) and the classic look with the original Winamp 2.91 skin (right).</sub></p>

**Highlights**
- **Simplicity first:** if you just want to listen to your music, drag folders in and play, like in the old days. No library to set up, no account, no subscription, and no full-screen app for 10,000 files. It's free.
- **Made for bootlegs:** official albums, live albums, shows and bootlegs, and demos are kept apart. Browse by show (date and venue) instead of by artist.
- **See what you're missing:** each artist page lists the official albums you don't have yet and the bootlegs known to exist on [MusicBrainz](https://musicbrainz.org).
- **Download live shows:** for artists who allow taping (Sharon Van Etten, for example), get missing shows from the [Live Music Archive](https://archive.org/details/etree).
- **Fix your tags:** finds unknown artists, missing years and genres, artists spelled several ways and duplicate releases. **Find Missing Info** looks a release up and writes the tags and cover art into the files.
- **Watched folders:** files added to a folder in your music library show up in the library by themselves. No need to sync or refresh.
- **Stats and listening history:** your collection at a glance, and your whole Last.fm history with a world map of where your music comes from.
- **Huge folders:** the player opens folders with thousands of files instantly.
- **Scrobbling** to Last.fm and ListenBrainz.
- **Internet radio and podcasts** built in.
- **Winamp skins:** real Winamp 2.x `.wsz` skins, next to a modern look.

## The player

A small window with a playlist and controls, like Winamp. That's all it takes to play albums, podcasts and radio. A music player shouldn't need your whole screen.

For browsing your whole collection, the Music Library opens in its own window (**LIBRARY** or ⌘4). Anything you play there plays in the player. An album already in the playlist plays from there instead of being added twice.

**View → Theme** sets the look:
- **Color:** Green, Amber, Blue, Cyan/Teal or Monochrome.
- **Finish:** Tinted, Hardware or Studio.
- **Chart colors:** soft pixel-art palettes from [Lospec](https://lospec.com) for the library's graphs, with color-blind safe colors as an option.

<p align="center"><img src="docs/themes.png" alt="Four themes: Green and Amber with the Tinted finish, Blue with Studio and Monochrome with Hardware, with the INFO and EQ drawers"></p>

## The classic look

Real Winamp 2.x skins, pixel-exact at 1×–4×. OmniAmp ships with the original Winamp 2.91 skin. Drag any `.wsz` onto the window to use your own; the [Winamp Skin Museum](https://skins.webamp.org) has thousands.

## Music Library

Add your music folders, on your Mac or on a NAS, and press **LIBRARY** (or ⌘4). OmniAmp turns them into a collection you can browse, even when it's big and loosely organized.

<p align="center"><img src="docs/library-artist.png" alt="An artist page: photo and bio, every release on a timeline above your own plays, your top songs" width="820"></p>

- **Tracks:** the whole library as one list, like Winamp's: length, title, artist, album, track, genre, year, format and date added. Click a header to sort (again to reverse), drag columns around, right-click the header to show or hide them; filters and search narrow the list. Double-click plays the track's album from there, several selected tracks play just those, and rows drag to the playlist.
- **Artist pages:** every release on a timeline next to your own listening, your top songs, and the albums you don't have yet. Including live recordings and bootlegs.
- **Albums:** all your covers in a grid, A–Z or grouped by artist, year, decade, kind or when they were added, in three sizes. Click one to see its tracks under it, double-click to play. Shows without a cover get a printed concert ticket (artist, date, venue and city) in one of six styles picked by the era of the show, as a small ticket with the year in the lists.
- **Shows and bootlegs:** live recordings are recognized and sorted by date and venue, apart from the official albums. Missing shows can be downloaded from the [Live Music Archive](https://archive.org/details/etree).
- **Browse** by artist, show, year or genre, see what's new, and search artists, albums, songs, venues, genres and folder names. Dates work in any spelling (1977-05-08, 8.5.77, 5/8/1977), "quotes" match exact words, and a typo gets a "Search for …" with the spelling your library uses.
- **Stats:** your collection at a glance, from the newest addition to what's lossless.
- **Listening:** connect [Last.fm](https://www.last.fm) to see your whole history: your most played artist, plays per year, your top artists through the years, and where your music comes from.
- **Needs Attention:** finds files with missing tags, duplicates and artists spelled several ways, and helps you fix them.

<p align="center">
  <img src="docs/library-browse.png" alt="Browsing an artist: releases as a cover shelf by year, albums and tracks" width="49%">
  <img src="docs/library-shows.png" alt="Shows: an artist's live recordings by date and venue (Blue theme)" width="49%">
</p>
<p align="center"><img src="docs/library-stats.png" alt="Collection stats: the newest release and key figures, release years, kinds of recordings (Blue theme)" width="700"></p>
<p align="center">
  <img src="docs/library-listening.png" alt="Listening history from Last.fm: your most played artist and key figures, plays per year, how much of what you play you own, your top artists through the years" width="49%">
  <img src="docs/library-map.png" alt="Where the music you play comes from: a world map of your artists' countries, top countries and their artists" width="49%">
</p>

## Internet radio

Press **RADIO** (or ⌘2) to browse and search thousands of stations from [radio-browser.info](https://www.radio-browser.info). Filter by genre and country, star your favorites, and add stations to the playlist like any other track. Stations are saved in `.m3u`/`.pls` files along with their logos.
- **MP3/AAC/AAC+ (Icecast and SHOUTcast):** play through OmniAmp's own engine, so the EQ and visualizer work. The INFO drawer shows the song currently on air.
- **HLS and Ogg/Opus:** play through the macOS player.
- **Your own stations:** **+ URL** adds any stream or `.pls`/`.m3u` link from a station's website to Favorites.

<p align="center"><img src="docs/radio.png" alt="The Internet Radio window: popular stations with logos, genres, countries and formats" width="700"></p>

## Podcasts

Press **PODCASTS** (or ⌘3) to browse the top shows in your country, or search both the [Apple Podcasts](https://podcasts.apple.com) and [fyyd](https://fyyd.de) directories at once. Pick a show to see its episodes, subscribe to it, and play or add episodes to the playlist like any other track.

<p align="center"><img src="docs/podcasts.png" alt="The Podcasts window: subscriptions with Continue listening, a show's episodes with thumbnails and played markers, and the show notes pane" width="700"></p>

- **Subscriptions:** new episodes are counted under SUBSCRIBED each time you open the window.
- **Continue listening:** episodes you've started (more than 30 seconds) are pinned at the top, from any show.
- **Resume:** episodes continue where you stopped, and finished ones are marked as played.
- **Show notes:** a resizable pane with the episode's notes and links (⌘I).
- **Filter:** type to filter a show's episodes by title (⇧⌘F), or show only the ones you haven't played (UNPLAYED, ⇧⌘U).
- **Downloads:** download episodes to play offline (⌘D). They're kept in a folder you choose in Settings; right-click → Show in Finder.
- **OPML:** import your subscriptions from another podcast app, or export them as a backup (in the + FEED menu).
- **Speed:** 1× to 2× (Controls → Podcast Speed), remembered per show, without changing the pitch.
- **Playback:** episodes stream through the macOS player, so the EQ and visualizer don't apply to them.
- **Any feed:** **+ FEED** subscribes to shows that aren't in the directory, including private or paid feeds with a personal link.
- **Keyboard:** arrows move between shows and episodes, Return plays, ⌃Tab switches between top shows and subscriptions.

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
- **Live playlist folders:** the playlist follows your music folders live. New files appear next to their folder-mates, deleted files disappear and edited files are re-tagged. Your folder structure is never touched.
- **ADD menu:** Add Files…, Add Folder… and Add URL…, in both looks.
- **Playlist files:** open and save `.m3u`/`.m3u8`/`.pls` files, plus a list of saved playlists.
- **Jump to file (J):** type to search. Enter plays the result and clears the search; ⇧Enter keeps the results.
- **Display options:** choose the playlist font (Hack, Hack Compact or the classic font) and toggle track numbers.

**Scrobbling**
- **[Last.fm](https://www.last.fm) and [ListenBrainz](https://listenbrainz.org)** (Settings, ⌘,): Now Playing updates, standard scrobble rules and an offline queue. Logins are stored in the macOS Keychain.

**Look and feel**
- **Visualizer:** click it to cycle spectrum (with peak hold) → oscilloscope → L/R level meters → off.
- **Time display:** click the time to switch between elapsed and remaining.
- **Now Playing and media keys:** OmniAmp shows up in macOS Now Playing (menu bar and Control Center) with cover art, and the media keys work. Podcasts get 15 s back / 30 s forward buttons there.

## Keyboard shortcuts

OmniAmp works without a mouse. **Help → Keyboard Shortcuts (⌘/)** lists every key; the main ones:

| Key | Action | | Key | Action |
|---|---|---|---|---|
| `Z` / `B` | Previous / next | | ↑ / ↓ | Move in the playlist |
| `X` / `C` / `V` | Play / pause / stop | | ⌘↑ / ⌘↓ | Move 10 rows (⌘⇧: 100) |
| Space | Play / pause | | Return | Play the selected track |
| ← / → | Seek 5 s (⇧: 30 s) | | `J` / ⌘F | Jump to track |
| `+` / `−` | Volume | | `L` | Show the playing track |
| `S` / `R` | Shuffle / repeat | | `Q` | Queue selected track |
| ⇧V | Stop after current | | `I` / `E` | INFO drawer / equalizer |
| ⌘1 / ⌘2 / ⌘3 / ⌘4 | Player / radio / podcasts / library | | ⌘O / ⌘L | Add files / add URL |
| ⌃⌘1 / ⌃⌘2 | Modern / classic look | | ⌘/ | All shortcuts |
| ⌘, | Settings | | | |

## Get it

### Download

Download the latest `OmniAmp-x.y.dmg` from [Releases](https://github.com/Doudini/omniamp/releases), open it and drag OmniAmp into Applications. Requires macOS 14 or later.

OmniAmp isn't signed with a paid Apple Developer certificate, so macOS blocks it the first time:

1. Open OmniAmp. When macOS says it can't check it, click **Done**.
2. Open **System Settings → Privacy & Security**, scroll down to the message about OmniAmp and click **Open Anyway**.

After that it opens normally. The DMG includes these steps as a text file. In the Terminal, `xattr -dr com.apple.quarantine /Applications/OmniAmp.app` does the same.

Last.fm and ListenBrainz scrobbling work out of the box (Settings, ⌘,).

**Updates:** choose **OmniAmp → Check for Updates…**. OmniAmp never checks by itself. When a newer release is available, it downloads it, checks it against GitHub's checksum and its code signature, installs it and relaunches. (0.2 has no updater yet, so get 0.3 from the Releases page once.)

### Build from source

You need macOS 14 or later and Xcode (Swift 6).

```sh
git clone https://github.com/Doudini/omniamp.git
cd omniamp
./scripts/make-app.sh   # release build → OmniAmp.app
open OmniAmp.app
```

Drag `OmniAmp.app` into `/Applications` to keep it.

### Last.fm API key (optional)

Last.fm requires every app to have its own API key, so a build made from this repo needs one for Last.fm scrobbling. ListenBrainz works without a key. Either enter your own key in **Settings → Last.fm → Use my own Last.fm API key**, or build it into the app:

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
./scripts/make-dmg.sh 0.2   # dist/OmniAmp-0.2.dmg for sharing
```

The app icon's source is `Resources/AppIcon.icon`. Open it in Icon Composer or edit its SVG, then run `./scripts/make-icon.sh`. The ideas we're saving for later are in [BACKLOG.md](BACKLOG.md).

### Signing and releases (maintainers)

`make-app.sh` signs with a self-signed **OmniAmp Code Signing** certificate when it's in your login keychain, and falls back to ad-hoc signing otherwise. With the certificate, every build counts as the same app. macOS then stops asking for the password before OmniAmp can read its saved logins, and Check for Updates only installs updates signed with the same certificate. To create it:

1. Open **Keychain Access** and choose **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name **OmniAmp Code Signing**, Identity Type **Self-Signed Root**, Certificate Type **Code Signing**, and tick **Let me override defaults**. Continue.
3. Set **Validity Period** to **3650** days, keep the other defaults and continue to **Create** (keychain: **login**).
4. Check: `security find-identity -p codesigning` lists "OmniAmp Code Signing".
5. Back up the certificate with its private key (**File → Export Items…** as .p12). Releases have to keep using this certificate.

Then `./scripts/release.sh 0.3` builds the DMG and publishes the GitHub release that Check for Updates finds.

## Credits

- **Fonts:** [Hack](https://github.com/source-foundry/Hack) and [Fira Code](https://github.com/tonsky/FiraCode), bundled as [Nerd Fonts](https://www.nerdfonts.com). Their licenses are in `fonts/`.
- **Classic skin:** the base skin is Winamp 2.91's original skin by Nullsoft.
- **Radio directory:** provided by the community-run [radio-browser.info](https://www.radio-browser.info).
- **Podcast directory:** Apple's podcast search and charts.
- **Screenshots:** the albums in the player screenshots are fictional; their audio and covers were generated for these images. The Music Library screenshots show a real collection.

OmniAmp is an independent project and is not affiliated with Winamp or Nullsoft.
