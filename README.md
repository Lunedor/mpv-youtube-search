# YouTube Search Select

A cross-platform mpv Lua script that searches YouTube with `yt-dlp`, renders a selectable grid with asynchronous thumbnail pipelines, and handles playback or playlist appending.

## Requirements

* mpv with Lua script support
* `yt-dlp` installed and available in `PATH` (or configured via path options)
* `ffmpeg` installed and available in `PATH` (or configured via path options)
* Network access to YouTube

## Installation

1. Copy `mpv-youtube-search.lua` into mpv's script directory:
* **Windows (portable)**: `portable_config/scripts/`
* **Linux / macOS**: `~/.config/mpv/scripts/`


2. Restart mpv.
3. Press `Ctrl+s` to open the search prompt.

Thumbnail frames are cached inside mpv's config directory under `~~/ytsearch_bgra/`.

## Configuration

Defaults defined at the top of the Lua file:

```lua
local opts = {
    yt_dlp_path = "yt-dlp",
    ffmpeg_path = "ffmpeg",
    page_size   = 8,
    search_key  = "Ctrl+s",
}

```

Override via mpv script-options:

* **Windows**: `portable_config/script-opts/mpv-youtube-search.conf`
* **Linux/macOS**: `~/.config/mpv/script-opts/mpv-youtube-search.conf`

Example `.conf`:

```ini
yt_dlp_path=yt-dlp
ffmpeg_path=ffmpeg
page_size=8
search_key=Ctrl+s

```

*(Supports `~~/` path expansion, e.g., `yt_dlp_path = ~~/_bin/yt-dlp`)*

## Controls

| Key | Action |
| --- | --- |
| `Ctrl+s` | Open the YouTube search prompt |
| `Up`, `Down`, `Left`, `Right` | Move selection (4-column grid) |
| `Enter` | Play the selected result (replace) |
| `Shift+Enter` | Append/queue the selected result |
| `N` | Next page |
| `P` | Previous page |
| `Esc` | Close results grid and restore window geometry |

## Pagination

Default page size is `8` items (4 columns × 2 rows). Page calculation fetches `page * page_size` items sequentially to prevent offset skipping.

## Thumbnails

* Displays `Loading...` asynchronously while fetching/converting.
* Fetches poster via `yt-dlp`, converts to raw BGRA via `ffmpeg` (`320x180`), and caches per page (`<vid_id>_p<page>.bgra`).
* Falls back to `No Image` placeholder vector card if download/conversion fails.

## Window Behavior

Target layout dimensions:

```lua
local GRID_WIDTH, GRID_HEIGHT = 1360, 900

```

Non-fullscreen/non-maximized windows resize to fit the grid target footprint and restore previous geometry upon closing or playback execution.

## Troubleshooting

### Search fails with status `-2` or subprocess spawn error

* Check binary availability:
* Windows: `where yt-dlp` / `where ffmpeg`
* Linux/macOS: `which yt-dlp` / `which ffmpeg`


* If using conda/venv wrappers on Windows, point `yt_dlp_path` directly to the compiled `.exe` or ensure PATH inheritance reaches mpv GUI launcher.

### Thumbnails show `No Image` or stuck on `Loading...`

* Verify `ffmpeg` output stream / CLI availability.
* Check write permissions for `~~/ytsearch_bgra`.
