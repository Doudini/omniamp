# OmniAmp backlog

Ideas we want but have deferred. Roughly ordered by value within each group.

## Follow-ups
- **Tag editor**: a Winamp-style File Info window to edit title, artist, album, year, genre, track number and cover; optionally rename files from their tags.
- **Synced lyrics**: show `.lrc` files that sit next to the tracks, scrolling in time with playback.
- **Global hotkeys**: control playback from any app.
- **Menu-bar mini player**: play/pause/next and the current track from the menu bar.
- **Podcasts, next steps**: download episodes for offline listening, playback speed (1.25×/1.5×/2×), chapters.

## Music library
- **Play history, next steps** (the basic history is in: every counted play is kept, Settings → Play History): import a ListenBrainz history like the last.fm one, export this Mac's plays (to last.fm/ListenBrainz or a file), and count plays per file where tags spell a song differently from last.fm.
- **Scrobble queue details**: Settings shows plays waiting and the oldest one's age; say when last.fm ignored plays older than its 14-day limit (it answers "ignored" and they're counted as sent today); optionally send the queue the moment the network returns (NWPathMonitor, no polling).
- **Background cover warm-up**: prepare the library's cover thumbnails for albums not scrolled to yet.
- **Save Ticket as Cover…**: an album-menu item for a show without a cover that writes its concert ticket (`TicketArt`) into the folder as `cover.jpg`, so other apps show it too. Only on request, never automatically: a written ticket can't be told apart from a real cover, doesn't follow later design changes, and writes to the NAS.

## Classic look
- **Shade mode**: double-click the title bar to collapse the window to a thin strip.
- **Window snapping**: EQ and playlist windows snap to each other and to screen edges.
- **Balance slider.**
- **Skin cursors.**
- **Shaped windows** for skins that ship a `region.txt`.

## Bigger items
- **Hardware finishes for the player**: make the modern player look like a small old-school stereo, as more finishes next to Tinted, Hardware and Studio: materials (brushed aluminium, black anodized, walnut side panels, 80s silver plastic), displays (VFD, backlit LCD with ghosted segments), button styles (piano keys, rubber, metal toggles, lit buttons), maybe layouts of their own. Needs the remaining inline highlight, shadow and knob values in `UI/Modern/*` turned into finish tokens first.
- **Milkdrop visualizations** (projectM).
- **More formats**: Ogg Vorbis/Opus, APE/WavPack, and tracker/chiptune formats (MOD/XM/IT/SID). These need external libraries.
- **Playlist tabs**: several open playlists, foobar2000-style.
- **Crossfade**: an optional alternative to gapless.
- **DSD**: DoP plus DSD→PCM conversion. On hold until it can be tested on a DSD-capable DAC.

## Distribution
- **Notarized release**: a Developer ID signature and notarization (needs a paid Apple Developer account) would remove the "Open Anyway" step at first install. Builds are self-signed with the OmniAmp certificate for now (README → Signing), and updates are manual (OmniAmp → Check for Updates…).
- **Homebrew cask.**
