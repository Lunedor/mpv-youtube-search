local input = require("mp.input")
local utils = require("mp.utils")
local msg = require("mp.msg")


--------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------


local opts = {
    yt_dlp_path = "yt-dlp",
    ffmpeg_path = "ffmpeg",
    cookie_path = "~~/cookies.txt",
    browser     = "firefox",
    browser_profile = "",
    page_size   = 8,
    search_key  = "Ctrl+s",
    feed_key    = "Ctrl+y",
}


(require "mp.options").read_options(opts, "mpv-youtube-search")


local function resolve_path(path)
    if path and path:sub(1, 3) == "~~/" then
        return mp.command_native({"expand-path", path})
    end
    return path
end


opts.yt_dlp_path = resolve_path(opts.yt_dlp_path)
opts.ffmpeg_path = resolve_path(opts.ffmpeg_path)


local THUMB_W, THUMB_H = 320, 180
local COLS = 4
local BASE_ID = 1
local EXPECTED_SIZE = THUMB_W * THUMB_H * 4
local GRID_WIDTH, GRID_HEIGHT = 1360, 900
local MAX_THUMB_CACHE_BYTES = 64 * 1024 * 1024


--------------------------------------------------------------------------
-- Paths & Cookie handling
--------------------------------------------------------------------------


local is_windows = package.config:sub(1,1) == "\\"
local thumb_dir = mp.command_native({"expand-path", "~~/"}) .. "/ytsearch_bgra"
thumb_dir = thumb_dir:gsub("\\", "/")


if is_windows then
    os.execute('mkdir "' .. thumb_dir:gsub("/", "\\") .. '" 2>nul')
else
    os.execute('mkdir -p "' .. thumb_dir .. '"')
end


local temp_cookie_file = nil

local function refresh_cookies_from_browser(callback)
    local tmp_base = mp.command_native({"expand-path", "~~/"})
    tmp_base = tmp_base:gsub("\\", "/")
    local tmp_path = tmp_base .. "/ytsearch_cookies.txt"

    local browser_arg = opts.browser or "firefox"
    if opts.browser_profile and opts.browser_profile ~= "" then
        browser_arg = browser_arg .. ":" .. opts.browser_profile
    end

    local args = {
        opts.yt_dlp_path,
        "--cookies-from-browser", browser_arg,
        "--cookies", tmp_path,
        "--no-warnings",
        "--simulate",
        "--no-playlist",
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    }

    msg.info("YT-Search: Refreshing cookies via yt-dlp --cookies-from-browser=" .. browser_arg)

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        args = args,
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, res)
        if not success or not res or res.status ~= 0 then
            msg.warn("Cookie refresh failed; keeping existing cookie file if present.")
            callback(nil)
            return
        end
        temp_cookie_file = tmp_path
        msg.info("YT-Search: Refreshed cookies -> " .. tmp_path)
        callback(tmp_path)
    end)
end


local function get_existing_cookie_file()
    if opts.cookie_path and opts.cookie_path ~= "" then
        return resolve_path(opts.cookie_path)
    end
    local cands = {
        mp.command_native({"expand-path", "~~/cookies.txt"}),
        mp.command_native({"expand-path", "~~/yt_cookies.txt"}),
        "cookies.txt",
        "yt_cookies.txt",
    }
    for _, path in ipairs(cands) do
        local f = io.open(path, "r")
        if f then f:close() return path end
    end
    return nil
end


temp_cookie_file = get_existing_cookie_file()
if temp_cookie_file then
    msg.info("YT-Search: Using existing cookie file: " .. temp_cookie_file)
else
    msg.warn("YT-Search: No cookie file found yet. Home/feed may not work until one is created.")
end


local page_cache = {}

local function clear_cache()
    page_cache = {}
end


local function cleanup_thumbnail_cache()
    local files = utils.readdir(thumb_dir, "files") or {}
    local cached = {}
    local total_size = 0

    for _, name in ipairs(files) do
        if name:match("%.bgra$") then
            local path = thumb_dir .. "/" .. name
            local info = utils.file_info(path)
            if info and info.size then
                total_size = total_size + info.size
                table.insert(cached, {
                    path = path,
                    size = info.size,
                    mtime = info.mtime or 0,
                })
            end
        end
    end

    if total_size <= MAX_THUMB_CACHE_BYTES then return end

    table.sort(cached, function(left, right)
        return left.mtime < right.mtime
    end)

    for _, file in ipairs(cached) do
        if total_size <= MAX_THUMB_CACHE_BYTES then break end
        if os.remove(file.path) then
            total_size = total_size - file.size
        end
    end
end


local function get_bgra_path(vid_id, page)
    return thumb_dir .. "/" .. tostring(vid_id) .. "_p" .. tostring(page) .. ".bgra"
end


local function get_thumb_key(vid_id, page)
    return tostring(vid_id) .. "_p" .. tostring(page)
end


--------------------------------------------------------------------------
-- InnerTube helpers
--------------------------------------------------------------------------


local function get_sapisid_from_cookies(cookie_file)
    if not cookie_file then return nil end
    local f = io.open(cookie_file, "r")
    if not f then return nil end
    for line in f:lines() do
        if not line:match("^#") and line:match("%S") then
            local fields = {}
            for field in line:gmatch("%S+") do
                table.insert(fields, field)
            end
            if #fields >= 7 then
                local name, value = fields[6], fields[7]
                if name == "SAPISID" or name == "__Secure-3PAPISID" or name == "__Secure-1PAPISID" then
                    f:close()
                    return value
                end
            end
        end
    end
    f:close()
    return nil
end


local function compute_sapisid_hash(sapisid, origin, callback)
    local now = tostring(os.time())
    local raw_str = now .. " " .. sapisid .. " " .. origin

    local cmd
    if is_windows then
        local ps_script = string.format(
            "$s='%s'; $h=[System.Security.Cryptography.SHA1]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s)); [System.BitConverter]::ToString($h).Replace('-','').ToLower()",
            raw_str:gsub("'", "''")
        )
        cmd = { "powershell", "-NoProfile", "-NonInteractive", "-Command", ps_script }
    else
        cmd = { "sh", "-c", string.format("printf '%%s' '%s' | sha1sum | awk '{print $1}'", raw_str) }
    end

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        args = cmd,
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, res)
        if success and res and res.stdout and res.stdout ~= "" then
            local hash = res.stdout:gsub("%s+", "")
            callback(now .. "_" .. hash)
        else
            msg.error("InnerTube: SHA1 generation failed: " .. tostring(res and res.stderr))
            callback(nil)
        end
    end)
end


local function find_continuation(node)
    if type(node) ~= "table" then return nil end
    if node.continuationCommand and node.continuationCommand.token then
        return node.continuationCommand.token
    end
    for _, v in pairs(node) do
        if type(v) == "table" then
            local t = find_continuation(v)
            if t then return t end
        end
    end
    return nil
end


local function fetch_innertube_feed(browse_id, continuation_token, callback)
    local cookie_file = temp_cookie_file
    if not cookie_file then
        msg.error("InnerTube: No cookie file available.")
        callback(nil, nil)
        return
    end

    local sapisid = get_sapisid_from_cookies(cookie_file)
    if not sapisid then
        msg.error("InnerTube: SAPISID cookie not found in " .. tostring(cookie_file))
        callback(nil, nil)
        return
    end

    local origin = "https://www.youtube.com"
    compute_sapisid_hash(sapisid, origin, function(sapisid_hash)
        if not sapisid_hash then
            msg.error("InnerTube: Failed to compute SAPISIDHASH")
            callback(nil, nil)
            return
        end

        local api_url = "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false"

        local payload
        if continuation_token then
            payload = utils.format_json({
                context = {
                    client = {
                        clientName = "WEB",
                        clientVersion = "2.20240901.00.00",
                        originalUrl = origin,
                        mainAppWebInfo = {
                            graftUrl = "https://www.youtube.com/"
                        }
                    }
                },
                continuation = continuation_token
            })
        else
            payload = utils.format_json({
                context = {
                    client = {
                        clientName = "WEB",
                        clientVersion = "2.20240901.00.00",
                        originalUrl = origin,
                        mainAppWebInfo = {
                            graftUrl = "https://www.youtube.com/"
                        }
                    }
                },
                browseId = browse_id
            })
        end

        local args = {
            "curl", "-s", "-X", "POST", api_url,
            "-H", "Content-Type: application/json",
            "-H", "Authorization: SAPISIDHASH " .. sapisid_hash,
            "-H", "X-Origin: " .. origin,
            "-H", "Origin: " .. origin,
            "-H", "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36",
            "-b", cookie_file,
            "-d", payload
        }

        mp.command_native_async({
            name = "subprocess",
            playback_only = false,
            args = args,
            capture_stdout = true,
            capture_stderr = true,
        }, function(success, res)
            if not success or not res.stdout or res.stdout == "" then
                msg.error("InnerTube: curl request failed: " .. tostring(res and res.stderr))
                callback(nil, nil)
                return
            end

            local ok, data = pcall(utils.parse_json, res.stdout)
            if not ok or not data then
                msg.error("InnerTube: JSON parsing failed")
                callback(nil, nil)
                return
            end

            local entries = {}
            local seen_ids = {}

            local function extract_text(node)
                if not node then return "" end
                if type(node) == "string" then return node end
                if node.simpleText then return node.simpleText end
                if node.runs and #node.runs > 0 then
                    local acc = {}
                    for _, r in ipairs(node.runs) do
                        if r.text then table.insert(acc, r.text) end
                    end
                    return table.concat(acc, "")
                end
                if node.content then return extract_text(node.content) end
                return ""
            end

            local function is_valid_video_id(id)
                if not id or type(id) ~= "string" then return false end
                if id:find("^RD") or #id ~= 11 then return false end
                return true
            end

            local function add_video(vr)
                if type(vr) == "table" and vr.videoId and is_valid_video_id(vr.videoId) and not seen_ids[vr.videoId] then
                    seen_ids[vr.videoId] = true
                    local title = extract_text(vr.title)
                    if title == "" then title = "Untitled" end

                    local channel = extract_text(vr.ownerText or vr.shortBylineText or vr.longBylineText)
                    local dur_str = extract_text(vr.lengthText)

                    table.insert(entries, {
                        id = vr.videoId,
                        title = title,
                        channel = channel,
                        uploader = channel,
                        dur_str = dur_str ~= "" and dur_str or "VIDEO",
                        url = "https://www.youtube.com/watch?v=" .. vr.videoId
                    })
                end
            end

            local function walk_tree(node)
                if type(node) ~= "table" then return end

                if node.videoRenderer then add_video(node.videoRenderer) end
                if node.gridVideoRenderer then add_video(node.gridVideoRenderer) end
                if node.compactVideoRenderer then add_video(node.compactVideoRenderer) end

                if node.richItemRenderer and node.richItemRenderer.content then
                    if node.richItemRenderer.content.videoRenderer then
                        add_video(node.richItemRenderer.content.videoRenderer)
                    end
                end

                if node.lockupViewModel and node.lockupViewModel.contentId then
                    local lvm = node.lockupViewModel
                    if is_valid_video_id(lvm.contentId) and not seen_ids[lvm.contentId] then
                        seen_ids[lvm.contentId] = true
                        local title = extract_text(lvm.metadata and lvm.metadata.lockupMetadataViewModel and lvm.metadata.lockupMetadataViewModel.title)
                        local channel = extract_text(lvm.metadata and lvm.metadata.lockupMetadataViewModel and lvm.metadata.lockupMetadataViewModel.metadata)
                        table.insert(entries, {
                            id = lvm.contentId,
                            title = title ~= "" and title or "Untitled",
                            channel = channel,
                            uploader = channel,
                            dur_str = "VIDEO",
                            url = "https://www.youtube.com/watch?v=" .. lvm.contentId
                        })
                    end
                end

                for _, v in pairs(node) do
                    if type(v) == "table" then walk_tree(v) end
                end
            end

            walk_tree(data)
            local cont_token = find_continuation(data)
            msg.info("InnerTube: Extracted " .. tostring(#entries) .. " valid video recommendation items, continuation=" .. tostring(cont_token))
            callback(entries, cont_token)
        end)
    end)
end


--------------------------------------------------------------------------
-- State & UI
--------------------------------------------------------------------------


local state = {
    active = false,
    mode = "search",
    query = nil,
    page = 1,
    results = {},
    raw_entries = {},
    cursor = 1,
    fetching = false,
    thumbnail_status = {},
    saved_geometry = nil,
    feedback = nil,
    feedback_timer = nil,
    continuation = nil,
}


local ov_ass = mp.create_osd_overlay("ass-events")


local function clear_overlays()
    for i = 1, opts.page_size do
        mp.commandv("overlay-remove", BASE_ID + i)
    end
end


local function resize_for_grid()
    if state.saved_geometry or mp.get_property_bool("fullscreen", false)
        or mp.get_property_bool("window-maximized", false) then
        return
    end

    local window_width = mp.get_property_number("osd-width") or mp.get_property_number("window-width")
    local window_height = mp.get_property_number("osd-height") or mp.get_property_number("window-height")
    if window_width and window_height and window_width >= GRID_WIDTH and window_height >= GRID_HEIGHT then
        return
    end

    local target_width = math.max(GRID_WIDTH, window_width or GRID_WIDTH)
    local target_height = math.max(GRID_HEIGHT, window_height or GRID_HEIGHT)
    state.saved_geometry = mp.get_property("geometry") or ""
    mp.set_property("geometry", target_width .. "x" .. target_height)
end


local function restore_window()
    if state.saved_geometry then
        mp.set_property("geometry", state.saved_geometry)
        state.saved_geometry = nil
    end
end


local function show_feedback(text)
    state.feedback = text
    if state.feedback_timer then state.feedback_timer:kill() end
    state.feedback_timer = mp.add_timeout(2.5, function()
        state.feedback = nil
        state.feedback_timer = nil
        if state.active then draw_grid() end
    end)
    draw_grid()
end


local function escape_ass(str)
    if not str then return "" end
    return str:gsub("{", "\\{"):gsub("}", "\\}")
end


local function fmt_duration(sec)
    if not sec then return "" end
    sec = math.floor(sec)
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end


local function entry_url(entry)
    if entry.url and entry.url:match("^https?://") then return entry.url end
    if entry.id then
        if entry.ie_key == "YoutubePlaylist" or entry._type == "playlist" then
            return "https://www.youtube.com/playlist?list=" .. entry.id
        end
        return "https://www.youtube.com/watch?v=" .. entry.id
    end
    return entry.webpage_url or entry.url
end


--------------------------------------------------------------------------
-- Thumbnails
--------------------------------------------------------------------------


local function fetch_thumbnail(vid_id, page)
    if not vid_id or not page then return end
    local out_file = get_bgra_path(vid_id, page)

    local f = io.open(out_file, "r")
    if f then 
        local size = f:seek("end")
        f:close()
        if size and size >= EXPECTED_SIZE then
            state.thumbnail_status[get_thumb_key(vid_id, page)] = "ready"
            if state.active and state.page == page then draw_grid() end
            return
        end
    end

    state.thumbnail_status[get_thumb_key(vid_id, page)] = "loading"

    local thumb_base = thumb_dir .. "/" .. tostring(vid_id) .. "_p" .. tostring(page)
    local thumb_jpg = thumb_base .. ".jpg"

    local img_url = "https://i.ytimg.com/vi/" .. vid_id .. "/hqdefault.jpg"
    local curl_args = { "curl", "-s", "-L", "-o", thumb_jpg, img_url }

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = false,
        capture_stderr = true,
        args = curl_args,
    }, function(success, res)
        if not success or not res or res.status ~= 0 then
            state.thumbnail_status[get_thumb_key(vid_id, page)] = "failed"
            if state.active and state.page == page then draw_grid() end
            return
        end

        local ffmpeg_args = {
            opts.ffmpeg_path,
            "-y", "-hide_banner", "-loglevel", "error",
            "-i", thumb_jpg,
            "-vf", "scale=" .. THUMB_W .. ":" .. THUMB_H,
            "-f", "rawvideo", "-pix_fmt", "bgra", out_file,
        }
        mp.command_native_async({
            name = "subprocess",
            playback_only = false,
            capture_stdout = false,
            capture_stderr = true,
            args = ffmpeg_args,
        }, function(ffmpeg_success, ffmpeg_res)
            os.remove(thumb_jpg)
            if not ffmpeg_success or not ffmpeg_res or ffmpeg_res.status ~= 0 then
                state.thumbnail_status[get_thumb_key(vid_id, page)] = "failed"
                if state.active and state.page == page then draw_grid() end
            elseif state.active and state.page == page then
                state.thumbnail_status[get_thumb_key(vid_id, page)] = "ready"
                draw_grid()
            else
                state.thumbnail_status[get_thumb_key(vid_id, page)] = "ready"
            end
        end)
    end)
end


--------------------------------------------------------------------------
-- Grid rendering
--------------------------------------------------------------------------


function draw_grid()
    if not state.active then return end

    local osd_w = mp.get_property_number("osd-width") or 1280
    local osd_h = mp.get_property_number("osd-height") or 720

    ov_ass.res_x = osd_w
    ov_ass.res_y = osd_h

    local PAD_X = math.floor((osd_w - (COLS * THUMB_W)) / (COLS + 1))
    if PAD_X < 10 then PAD_X = 10 end
    local START_X = PAD_X

    local PAD_Y = 100
    local TOTAL_H = (2 * THUMB_H) + PAD_Y
    local START_Y = math.floor((osd_h - TOTAL_H) / 2) + 10

    local ass = string.format("{\\an7\\pos(0,0)}{\\1a&H15&}{\\1c&H000000&}{\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}\n", osd_w, osd_w, osd_h, osd_h)

    local head_y = math.max(10, START_Y - 70)

    local title_text = state.mode == "search" and ("⌕ Search: " .. escape_ass(state.query)) or "🏠 Personal Home Recommendations"
    ass = ass .. string.format("{\\an7\\pos(%d,%d)}{\\fs40\\b1\\1a&H00&\\1c&HFFFFFF&}%s (Page %d){\\b0}\n", START_X, head_y, title_text, state.page)

    if state.feedback then
        ass = ass .. string.format("{\\an8\\pos(%d,55)}{\\fs24\\b1\\1c&HFFFFFF&\\3c&H0088CC&\\bord3} %s {\\b0}\n", osd_w / 2, escape_ass(state.feedback))
    end

    clear_overlays()

    for i = 1, math.min(#state.results, opts.page_size) do
        local e = state.results[i]
        local col = (i - 1) % COLS
        local row = math.floor((i - 1) / COLS)

        local x = START_X + col * (THUMB_W + PAD_X)
        local y = START_Y + row * (THUMB_H + PAD_Y)

        local has_image = false
        if e.id then
            local bgra_path = get_bgra_path(e.id, state.page)
            local f = io.open(bgra_path, "r")
            if f then
                local size = f:seek("end")
                f:close()
                if size and size >= EXPECTED_SIZE then
                    mp.commandv("overlay-add", BASE_ID + i, math.floor(x), math.floor(y), bgra_path, 0, "bgra", THUMB_W, THUMB_H, THUMB_W * 4)
                    has_image = true
                end
            end
        end

        if not has_image then
            local thumb_status = e.id and state.thumbnail_status[get_thumb_key(e.id, state.page)] or "failed"
            local placeholder = thumb_status == "loading" and "Loading..." or "No Image"
            ass = ass .. string.format("{\\an7\\pos(%d,%d)}{\\1a&H00&}{\\1c&H222222&}{\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}\n", x, y, THUMB_W, THUMB_W, THUMB_H, THUMB_H)
            ass = ass .. string.format("{\\an7\\pos(%d,%d)}{\\fs26\\1c&H777777&}%s\n", x + (THUMB_W/2) - 45, y + (THUMB_H/2) - 15, placeholder)
        end

        local title = e.title or "(no title)"
        if #title > 38 then title = title:sub(1, 35) .. "..." end
        title = escape_ass(title)

        local clip_tag = string.format("\\clip(%d,%d,%d,%d)", x, 0, x + THUMB_W - 5, osd_h)
        ass = ass .. string.format("{\\an7\\pos(%d,%d)%s}{\\fs18\\b1\\1a&H00&\\1c&HFFFFFF&}%s\n", x, y + THUMB_H + 10, clip_tag, title)

        local channel = e.channel or e.uploader or ""
        if #channel > 20 then channel = channel:sub(1, 17) .. "..." end
        channel = escape_ass(channel)

        local dur = e.dur_str or (e.duration and e.duration > 0 and fmt_duration(e.duration)) or "VIDEO"
        ass = ass .. string.format("{\\an7\\pos(%d,%d)%s}{\\fs14\\b0\\1c&HAAAAAA&}👤 %s   |   ⏱ %s\n", x, y + THUMB_H + 35, clip_tag, channel, dur)

        if i == state.cursor then
            local bx, by = x - 4, y - 4
            local bw, bh = THUMB_W + 8, THUMB_H + 8
            ass = ass .. string.format("{\\an7\\pos(%d,%d)}{\\3c&H00FFFF&}{\\bord4}{\\1a&HFF&}{\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}\n", bx, by, bw, bw, bh, bh)
        end
    end

    local footer_y = START_Y + (2 * (THUMB_H + PAD_Y)) - 15
    ass = ass .. string.format("{\\an7\\pos(%d,%d)}{\\fs18\\1a&H00&\\1c&HAAAAAA&}⌨  [Arrows] Navigate   [Enter] Play   [Shift+Enter] Append   [N] Next Page   [P] Prev Page   [ESC] Close\n", START_X, footer_y)

    ov_ass.data = ass
    ov_ass:update()
end


--------------------------------------------------------------------------
-- Navigation & control
--------------------------------------------------------------------------


local function close_grid()
    state.active = false
    ov_ass:remove()
    clear_overlays()
    if state.feedback_timer then state.feedback_timer:kill() end
    state.feedback = nil
    state.feedback_timer = nil
    restore_window()
    mp.remove_key_binding("grid-up")
    mp.remove_key_binding("grid-down")
    mp.remove_key_binding("grid-left")
    mp.remove_key_binding("grid-right")
    mp.remove_key_binding("grid-enter")
    mp.remove_key_binding("grid-append")
    mp.remove_key_binding("grid-esc")
    mp.remove_key_binding("grid-next")
    mp.remove_key_binding("grid-prev")
end


local function move_cursor(dx, dy)
    local idx = state.cursor - 1
    local col = idx % COLS
    local row = math.floor(idx / COLS)

    col = (col + dx) % COLS

    local max_rows = math.ceil(#state.results / COLS)
    if max_rows == 0 then return end
    row = (row + dy) % max_rows

    local new_idx = row * COLS + col + 1
    if new_idx > #state.results then
        new_idx = #state.results
    end

    state.cursor = new_idx
    draw_grid()
end


local function execute_selection(append)
    local e = state.results[state.cursor]
    if not e then return end

    local url = entry_url(e)
    if append then
        mp.commandv("loadfile", url, "append-play")
        show_feedback("Added to playlist: " .. (e.title or url))
    else
        mp.commandv("loadfile", url, "replace")
        close_grid()
    end
end


local fetch_and_render


local function bind_keys()
    mp.add_forced_key_binding("UP", "grid-up", function() move_cursor(0, -1) end)
    mp.add_forced_key_binding("DOWN", "grid-down", function() move_cursor(0, 1) end)
    mp.add_forced_key_binding("LEFT", "grid-left", function() move_cursor(-1, 0) end)
    mp.add_forced_key_binding("RIGHT", "grid-right", function() move_cursor(1, 0) end)
    mp.add_forced_key_binding("ENTER", "grid-enter", function() execute_selection(false) end)
    mp.add_forced_key_binding("Shift+ENTER", "grid-append", function() execute_selection(true) end)
    mp.add_forced_key_binding("ESC", "grid-esc", close_grid)

    mp.add_forced_key_binding("n", "grid-next", function()
        if not state.active then return end
        state.page = state.page + 1
        fetch_and_render(state.mode, state.query, state.page)
    end)
    mp.add_forced_key_binding("p", "grid-prev", function()
        if not state.active then return end
        if state.page > 1 then
            state.page = state.page - 1
            fetch_and_render(state.mode, state.query, state.page)
        end
    end)
end


function fetch_and_render(mode, query, page)
    if state.fetching then return end

    local cache_key = mode .. ":" .. tostring(query)

    local function render_page_from_entries(all_entries)
        state.raw_entries = all_entries
        local start_idx = (page - 1) * opts.page_size + 1
        local end_idx = math.min(page * opts.page_size, #all_entries)

        local page_results = {}
        for i = start_idx, end_idx do
            table.insert(page_results, all_entries[i])
        end

        state.results = page_results
        state.mode = mode
        state.query = query
        state.page = page
        state.cursor = 1
        state.active = true

        clear_overlays()
        bind_keys()
        draw_grid()

        for _, e in ipairs(state.results) do
            if e.id then fetch_thumbnail(e.id, state.page) end
        end
    end

    -- Home / feed mode
    if mode == "feed" then
        -- If we already have entries in cache
        if page_cache[cache_key] then
            local start_idx = (page - 1) * opts.page_size + 1

            -- Enough items for this page?
            if start_idx <= #page_cache[cache_key] then
                render_page_from_entries(page_cache[cache_key])
                state.fetching = false
                return
            end

            -- Need more items
            if not state.continuation then
                state.fetching = false
                show_feedback("No more recommendations")
                render_page_from_entries(page_cache[cache_key])
                return
            end

            -- Fetch next batch
            state.fetching = true
            clear_overlays()

            local osd_w = mp.get_property_number("osd-width") or 1280
            local osd_h = mp.get_property_number("osd-height") or 720
            ov_ass.res_x, ov_ass.res_y = osd_w, osd_h

            ov_ass.data = string.format("{\\an5}{\\pos(%d,%d)}{\\fs50\\b1}Loading More...{\\b0}", osd_w/2, osd_h/2)
            ov_ass:update()

            fetch_innertube_feed(nil, state.continuation, function(entries, cont)
                state.fetching = false
                if not entries or #entries == 0 then
                    show_feedback("No more recommendations")
                    render_page_from_entries(page_cache[cache_key])
                    return
                end
                local all = page_cache[cache_key]
                for _, e in ipairs(entries) do
                    table.insert(all, e)
                end
                page_cache[cache_key] = all
                state.continuation = cont
                render_page_from_entries(all)
            end)
            return
        end

        -- First load
        state.fetching = true
        clear_overlays()

        local osd_w = mp.get_property_number("osd-width") or 1280
        local osd_h = mp.get_property_number("osd-height") or 720
        ov_ass.res_x, ov_ass.res_y = osd_w, osd_h

        ov_ass.data = string.format("{\\an5}{\\pos(%d,%d)}{\\fs50\\b1}Fetching Results...{\\b0}", osd_w/2, osd_h/2)
        ov_ass:update()

        fetch_innertube_feed("FEwhat_to_watch", nil, function(entries, cont)
            state.fetching = false
            if not entries or #entries == 0 then
                ov_ass.data = string.format("{\\an5}{\\pos(%d,%d)}{\\fs40\\1c&H0000FF&}InnerTube Feed Failed. Check cookies.", osd_w/2, osd_h/2)
                ov_ass:update()
                restore_window()
                return
            end
            page_cache[cache_key] = entries
            state.continuation = cont
            msg.info("Home: stored continuation = " .. tostring(cont))
            render_page_from_entries(entries)
        end)
        return
    end

    -- Search mode (yt-dlp)
    local want = 40
    local args = { opts.yt_dlp_path, "--no-warnings", "-J", "--flat-playlist", "ytsearch" .. tostring(want) .. ":" .. query }

    if temp_cookie_file then
        table.insert(args, 3, "--cookies")
        table.insert(args, 4, temp_cookie_file)
    else
        msg.warn("YT-Search: No cookie file; running search without authentication.")
    end

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        args = args,
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, res, err)
        state.fetching = false

        if not success or not res or res.status ~= 0 or not res.stdout or res.stdout == "" then
            msg.error("yt-dlp failed: status=" .. tostring(res and res.status) .. " stderr=" .. tostring(res and res.stderr))
            ov_ass.data = string.format("{\\an5}{\\pos(%d,%d)}{\\fs40\\1c&H0000FF&}Search Failed. Check console.", osd_w/2, osd_h/2)
            ov_ass:update()
            restore_window()
            return
        end

        local ok, data = pcall(utils.parse_json, res.stdout)
        local entries = data and data.entries or {}

        page_cache[cache_key] = entries
        render_page_from_entries(entries)
    end)
end


--------------------------------------------------------------------------
-- Init & bindings
--------------------------------------------------------------------------


mp.observe_property("osd-dimensions", "native", function(name, val)
    if state.active then draw_grid() end
end)


-- Initial cookie refresh (non-blocking)
refresh_cookies_from_browser(function(new_file)
    if new_file then
        msg.info("YT-Search: Initial cookie refresh succeeded.")
    else
        if not temp_cookie_file then
            msg.error("YT-Search: No cookie file available after initial refresh.")
        else
            msg.warn("YT-Search: Initial cookie refresh failed; using existing cookies.")
        end
    end
end)


mp.add_key_binding(opts.search_key, "mpv-youtube-search", function()
    if state.active then
        close_grid()
        return
    end

    clear_cache()

    input.get({
        prompt = "Search YouTube:",
        submit = function(query)
            if query == nil or query:match("^%s*$") then return end
            cleanup_thumbnail_cache()
            resize_for_grid()
            fetch_and_render("search", query, 1)
        end,
    })
end)


mp.add_key_binding(opts.feed_key, "mpv-youtube-feed", function()
    if state.active then
        close_grid()
        return
    end

    clear_cache()
    cleanup_thumbnail_cache()
    resize_for_grid()
    fetch_and_render("feed", "home", 1)
end)