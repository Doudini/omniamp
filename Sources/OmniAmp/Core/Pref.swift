/// Every UserDefaults key OmniAmp uses, in one place (the strings are what existing installs have saved:
/// never change one without migrating it).
enum Pref {
    // Looks and windows
    static let uiMode = "uiMode"
    static let skinPath = "skinPath"
    static let modernTheme = "modernTheme"
    static let modernFinish = "modernFinish"
    /// The library's chart palette (ChartPalette.id), and whether its categories use the color-blind safe set.
    static let chartPalette = "chartPalette"
    static let colorBlindCharts = "colorBlindCharts"
    static let modernDrawer = "modernDrawer"
    static let modernInfoHeight = "modernInfoHeight"
    static let modernEQVisible = "modernEQVisible"
    static let modernRemaining = "modernRemaining"
    static let classicScale = "classicScale"
    static let classicRemaining = "classicRemaining"
    static let classicPlaylistVisible = "classicPlaylistVisible"
    static let classicPlaylistWidth = "classicPlaylistWidth"
    static let classicPlaylistHeight = "classicPlaylistHeight"
    static let classicEQVisible = "classicEQVisible"
    static let alwaysOnTop = "alwaysOnTop"
    static let analyzerMode = "analyzerMode"
    static let analyzerOn = "analyzerOn"
    static let playlistFont = "playlistFont"
    static let playlistNumbers = "playlistNumbers"
    // Playback and output
    static let outputDeviceUID = "outputDeviceUID"
    static let bitPerfect = "bitPerfect"
    static let exclusiveAccess = "exclusiveAccess"
    static let replayGain = "replayGain"
    /// The saved volume is a slider position (loudness curve), not a gain (set once converted).
    static let volumeIsPosition = "volumeIsPosition"
    static let resumeLongTracks = "resumeLongTracks"
    static let resumePositions = "resumePositions"
    static let resumeDates = "resumeDates"
    // Library
    static let watchedFolders = "watchedFolders"
    /// The music library's folders (the Library window), separate from the playlist's watched folders.
    static let libraryFolders = "libraryFolders"
    /// The Albums grid: how it's grouped (AlbumGrouping) and its cover size (0–2).
    static let libraryGridGroup = "libraryGridGroup"
    static let libraryGridSize = "libraryGridSize"
    /// Tracks: the column it's sorted by and which way ("artist:asc").
    static let libraryTracksSort = "libraryTracksSort"
    /// The library may look things up online in the background (artist countries from MusicBrainz).
    static let libraryOnlineLookups = "libraryOnlineLookups"
    /// Where Live Music Archive downloads go (a folder per artist inside).
    static let liveArchiveFolder = "liveArchiveFolder"
    /// Whose last.fm history the library shows (defaults to the connected account).
    static let lastfmHistoryUser = "lastfmHistoryUser"
    // Podcasts
    static let podcastSpeeds = "podcastSpeeds"
    static let podcastUnplayedOnly = "podcastUnplayedOnly"
    // Scrobbling (logins themselves are in the Keychain)
    static let lastfmUser = "lastfmUser"
    static let lastfmCustomKey = "lastfmCustomKey"
    static let listenbrainzUser = "listenbrainzUser"
}
