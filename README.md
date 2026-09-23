# YouTube Search Select

![UI Sample](screenshot.png)

A mpv Lua script that searches YouTube with `yt-dlp`, displays the results in a selectable grid, loads thumbnails, and plays or queues the selected video.

## Requirements

- mpv with Lua script support
- `yt-dlp` installed and available in `PATH`
- `ffmpeg` installed and available in `PATH`
- Network access to YouTube

The script can also use explicit executable paths if the commands are not available in `PATH`.

## Installation

1. Copy `mpv-youtube-search.lua` into mpv's `portable_config/scripts` directory.
2. Restart mpv.
3. Press `Ctrl+s` to open the search prompt.

The script creates a `ytsearch_bgra` folder inside mpv's config directory for converted thumbnail frames.

## Configuration

The defaults are defined near the top of the Lua file:

```lua
local opts = {
    yt_dlp_path = "yt-dlp",
    ffmpeg_path = "ffmpeg",
    page_size   = 8,
    search_key  = "Ctrl+s",
}
```

You can override them through an mpv script-options file:

`portable_config/script-opts/mpv-youtube-search.conf`

Example:

```ini
yt_dlp_path=C:/Tools/yt-dlp.exe
ffmpeg_path=C:/Tools/ffmpeg.exe
page_size=8
search_key=Ctrl+s
```

Use forward slashes in Windows paths, or escape backslashes appropriately.

## Controls

| Key | Action |
| --- | --- |
| `Ctrl+s` | Open the YouTube search prompt |
| `Up`, `Down`, `Left`, `Right` | Move the selection |
| `Enter` | Play the selected result |
| `Shift+Enter` | Append the selected result to the playlist |
| `N` | Next page |
| `P` | Previous page |
| `Esc` | Close the results grid |

## Pagination

The default page size is 8 results.

Page 1 displays results 1-8. Page 2 requests enough results to display 9-16, so results are not skipped between pages. Change `page_size` to alter the number of results per page.

## Thumbnails

Thumbnails initially show `Loading...`. They are downloaded through `yt-dlp` and converted locally with `ffmpeg`. `No Image` is shown only when the download or conversion fails.

Thumbnails are cached as BGRA frames in:

```text
portable_config/ytsearch_bgra/
```

## Window behavior

When a search starts, a normal, non-maximized mpv window is resized to the grid layout size configured in the Lua file:

```lua
local GRID_WIDTH, GRID_HEIGHT = 1360, 900
```

The original window geometry is restored when the grid closes, a video is selected, or the search fails. Fullscreen and maximized windows are not resized.

## Troubleshooting

### Search fails with status `-2`

Check that mpv can start `yt-dlp`:

```bat
where yt-dlp
yt-dlp --version
```

If mpv was started before installing or changing `PATH`, fully restart mpv.

### Thumbnails do not appear

Check that ffmpeg is available:

```bat
where ffmpeg
ffmpeg -version
```

If it is not available through `PATH`, set an explicit `ffmpeg_path` in `mpv-youtube-search.conf`.

### Search works only after opening a video

The search subprocess is configured with `playback_only = false`, so it should work while mpv is idle. Restart mpv after updating the script if the old behavior persists.
