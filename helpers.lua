--[[
Copyright: Ajatt-Tools and contributors; https://github.com/Ajatt-Tools
License: GNU GPL, version 3 or later; http://www.gnu.org/licenses/gpl.html

Various helper functions.
]]

local mp = require('mp')
local msg = require('mp.msg')
local utils = require('mp.utils')
local this = {}

this.unpack = unpack and unpack or table.unpack

this.remove_all_spaces = function(str)
    return str:gsub('%s*', '')
end

this.as_callback = function(fn, ...)
    --- Convenience utility.
    local args = { ... }
    return function()
        return fn(this.unpack(args))
    end
end

this.table_get = function(table, key, default)
    if table[key] == nil then
        return default or 'nil'
    else
        return table[key]
    end
end

this.max_num = function(table)
    local max = table[1]
    for _, value in ipairs(table) do
        if value > max then
            max = value
        end
    end
    return max
end

this.get_last_n_added_notes = function(note_ids, n)
    table.sort(note_ids)
    return { this.unpack(note_ids, math.max(#note_ids - n + 1, 1), #note_ids) }
end

this.contains = function(table, element)
    for _, value in pairs(table) do
        if value == element then
            return true
        end
    end
    return false
end

this.minutes_ago = function(m)
    return (os.time() - 60 * m) * 1000
end

this.is_wayland = function()
    return os.getenv('WAYLAND_DISPLAY') ~= nil
end

this.is_win = function()
    return mp.get_property('options/vo-mmcss-profile') ~= nil
end

this.is_mac = function()
    return mp.get_property('options/macos-force-dedicated-gpu') ~= nil
end

local function map(tab, func)
    local t = {}
    for k, v in pairs(tab) do
        t[k] = func(v)
    end
    return t
end

local function args_as_str(args)
    local function single_quote(str)
        return string.format("'%s'", str)
    end
    return table.concat(map(args, single_quote), " ")
end

this.subprocess = function(args, completion_fn, override_settings)
    -- if `completion_fn` is passed, the command is ran asynchronously,
    -- and upon completion, `completion_fn` is called to process the results.
    msg.info("Executing: " .. args_as_str(args))
    local command_native = type(completion_fn) == 'function' and mp.command_native_async or mp.command_native
    local command_table = {
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args
    }
    if not this.is_empty(override_settings) then
        for k, v in pairs(override_settings) do
            command_table[k] = v
        end
    end
    return command_native(command_table, completion_fn)
end

this.subprocess_detached = function(args, completion_fn)
    local overwrite_settings = {
        detach = true,
        capture_stdout = false,
        capture_stderr = false,
    }
    return this.subprocess(args, completion_fn, overwrite_settings)
end

-- 双语过滤状态
-- filter_enabled: 总开关
-- subtitle_type: nil(未判定), "bilingual"(双语), "monolingual"(纯日语)
-- jp_position: "top"(日语在上), "bottom"(日语在下)
local filter_enabled = true
local subtitle_type = nil
local jp_position = nil
local monolingual_streak = 0  -- 纯日语证据计数
local bilingual_streak = 0    -- 双语证据计数
local jp_top_count = 0        -- 日语在上的次数
local jp_bottom_count = 0     -- 日语在下的次数
local LOCK_THRESHOLD = 5      -- 锁定阈值

local function reset_detection()
    subtitle_type = nil
    jp_position = nil
    monolingual_streak = 0
    bilingual_streak = 0
    jp_top_count = 0
    jp_bottom_count = 0
end

this.toggle_bilingual_filter = function()
    if not filter_enabled then
        -- 关闭状态 → 开启并重置判定
        filter_enabled = true
        reset_detection()
        mp.osd_message("双语过滤: 开启 (重新检测)", 2)
    elseif subtitle_type == nil then
        -- 开启且未锁定 → 关闭
        filter_enabled = false
        mp.osd_message("双语过滤: 关闭", 2)
    else
        -- 开启且已锁定 → 重置判定
        reset_detection()
        mp.osd_message("双语过滤: 重置检测", 2)
    end
end

-- 调试面板状态
local debug_panel_active = false
local debug_observer_registered = false

-- UTF-8 安全的字符串截断（按字符数而非字节数）
local function utf8_truncate(str, max_chars)
    if str == nil or str == "" then
        return ""
    end
    
    local char_count = 0
    local byte_pos = 1
    local len = #str
    
    while byte_pos <= len and char_count < max_chars do
        local byte = string.byte(str, byte_pos)
        local char_len
        if byte < 128 then
            char_len = 1      -- ASCII
        elseif byte < 224 then
            char_len = 2      -- 2字节 UTF-8
        elseif byte < 240 then
            char_len = 3      -- 3字节 UTF-8 (中日韩等)
        else
            char_len = 4      -- 4字节 UTF-8 (emoji等)
        end
        
        -- 确保不会越界
        if byte_pos + char_len - 1 > len then
            break
        end
        
        byte_pos = byte_pos + char_len
        char_count = char_count + 1
    end
    
    if byte_pos <= len then
        return str:sub(1, byte_pos - 1) .. "..."
    else
        return str
    end
end

-- 更新调试面板显示
local function update_debug_panel()
    if not debug_panel_active then
        return
    end
    
    local raw_text = mp.get_property("sub-text") or ""
    local filtered_text = this.filter_bilingual_subtitle(raw_text)
    
    -- 将换行符替换为可见的标记
    local raw_display = raw_text:gsub("\n", " ⏎ ")
    local filtered_display = filtered_text:gsub("\n", " ⏎ ")
    
    -- UTF-8 安全截断（按字符数）
    local max_chars = 40
    raw_display = utf8_truncate(raw_display, max_chars)
    filtered_display = utf8_truncate(filtered_display, max_chars)
    
    local msg = string.format(
        "═══ 双语过滤调试面板 ═══\n【原始】%s\n【过滤】%s\n【状态】%s\n(Alt+d 关闭)",
        raw_display ~= "" and raw_display or "(空)",
        filtered_display ~= "" and filtered_display or "(空)",
        this.get_bilingual_filter_status()
    )
    -- 使用较长的显示时间，会被下一次更新覆盖
    mp.osd_message(msg, 9999)
end

-- 字幕变化时的回调
local function on_sub_text_change(name, value)
    if debug_panel_active then
        update_debug_panel()
    end
end

-- 切换调试面板
this.debug_subtitle_filter = function()
    debug_panel_active = not debug_panel_active
    
    if debug_panel_active then
        -- 注册字幕变化监听（只注册一次）
        if not debug_observer_registered then
            mp.observe_property("sub-text", "string", on_sub_text_change)
            debug_observer_registered = true
        end
        -- 立即显示当前状态
        update_debug_panel()
    else
        -- 关闭面板，清除 OSD
        mp.osd_message("", 0)
    end
end

-- 获取双语过滤状态信息（用于菜单显示）
this.get_bilingual_filter_status = function()
    if not filter_enabled then
        return "关闭"
    elseif subtitle_type == nil then
        return string.format("检测中 (单语:%d/双语:%d)", monolingual_streak, bilingual_streak)
    elseif subtitle_type == "monolingual" then
        return "纯日语"
    else
        local pos_str = jp_position == "top" and "上" or "下"
        return string.format("双语 (日语在%s)", pos_str)
    end
end

-- 从两行中提取日语行（根据位置或假名检测）
local function extract_jp_from_pair(line1, line2)
    local line1_is_jp = this.isJapanese(line1)
    local line2_is_jp = this.isJapanese(line2)
    
    -- 如果只有一行有假名，直接返回那行（最可靠）
    if line1_is_jp and not line2_is_jp then
        return line1
    elseif line2_is_jp and not line1_is_jp then
        return line2
    end
    
    -- 两行都有假名或都没有假名时，按位置返回
    if jp_position == "top" then
        return line1
    elseif jp_position == "bottom" then
        return line2
    else
        -- 无法区分，返回两行
        return line1 .. "\n" .. line2
    end
end

-- 只做过滤，不做检测（用于已经检测过的文本）
this.filter_bilingual_subtitle = function(text)
    if text == nil or text == "" then
        return ""
    end
    
    if not filter_enabled then
        return text
    end
    
    if subtitle_type == "monolingual" then
        return text
    end
    
    local lines = {}
    for line in string.gmatch(text, "[^\n]+") do
        table.insert(lines, line)
    end
    
    local line_count = #lines
    if line_count == 0 then
        return text
    end
    
    if subtitle_type == "bilingual" then
        if line_count == 1 then
            -- 单行：如果有假名就是日语，否则是翻译文字，过滤掉
            if this.isJapanese(lines[1]) then
                return lines[1]
            else
                return ""
            end
        elseif line_count == 2 then
            return extract_jp_from_pair(lines[1], lines[2])
        elseif line_count == 3 then
            -- 3行：从中找出有假名的日语行
            local jp_lines = {}
            for _, line in ipairs(lines) do
                if this.isJapanese(line) then
                    table.insert(jp_lines, line)
                end
            end
            if #jp_lines > 0 then
                return table.concat(jp_lines, "\n")
            else
                -- 三行都没假名，无法区分，返回原文
                return text
            end
        elseif line_count == 4 then
            -- 4行通常是两个人的对话，各自带翻译
            -- 过滤后用全角空格分隔，表示不同说话人
            local jp1 = extract_jp_from_pair(lines[1], lines[2])
            local jp2 = extract_jp_from_pair(lines[3], lines[4])
            return jp1 .. "　" .. jp2
        end
    end
    
    -- 未锁定或超过4行：按假名检测
    local jp_lines = {}
    for _, line in ipairs(lines) do
        if this.isJapanese(line) then
            table.insert(jp_lines, line)
        end
    end
    if #jp_lines > 0 and #jp_lines < line_count then
        return table.concat(jp_lines, "\n")
    end
    
    return text
end

-- 检查是否为标注行（如 (男)、[音楽]、（効果音） 等）
local function is_annotation_line(line)
    -- 整行被括号包裹的情况
    if line:match("^%(.+%)$") then return true end      -- (xxx)
    if line:match("^（.+）$") then return true end      -- （xxx）
    if line:match("^%[.+%]$") then return true end      -- [xxx]
    if line:match("^［.+］$") then return true end      -- ［xxx］
    return false
end

-- 完整的检测+过滤（只在 Subtitle:now() 中调用）
this.get_japanese_from_subtext = function(text)
    if text == nil or text == "" then
        return ""
    end
    
    -- 总开关关闭时，直接返回原文
    if not filter_enabled then
        return text
    end
    
    -- 已锁定，直接调用过滤函数
    if subtitle_type ~= nil then
        return this.filter_bilingual_subtitle(text)
    end
    
    -- 未锁定：先收集证据，再过滤
    local lines = {}
    for line in string.gmatch(text, "[^\n]+") do
        table.insert(lines, line)
    end
    
    local line_count = #lines
    if line_count == 0 then
        return text
    end
    
    -- 过滤掉标注行后再判断（仅用于证据收集）
    local effective_lines = {}
    for _, line in ipairs(lines) do
        if not is_annotation_line(line) then
            table.insert(effective_lines, line)
        end
    end
    local effective_count = #effective_lines
    
    local first_is_jp = effective_count >= 1 and this.isJapanese(effective_lines[1])
    local second_is_jp = effective_count >= 2 and this.isJapanese(effective_lines[2])
    
    -- 收集证据（基于有效行数）
    if effective_count == 1 and first_is_jp then
        -- 单行有假名 → 纯日语证据
        monolingual_streak = monolingual_streak + 1
    elseif effective_count == 2 then
        if first_is_jp and second_is_jp then
            -- 两行都有假名 → 纯日语证据
            monolingual_streak = monolingual_streak + 1
        elseif first_is_jp and not second_is_jp then
            -- 两行，第一行有假名第二行没有 → 双语证据（日语在上）
            bilingual_streak = bilingual_streak + 1
            jp_top_count = jp_top_count + 1
        elseif not first_is_jp and second_is_jp then
            -- 两行，第二行有假名第一行没有 → 双语证据（日语在下）
            bilingual_streak = bilingual_streak + 1
            jp_bottom_count = jp_bottom_count + 1
        end
        -- 两行都没假名：不计入证据
    end
    -- 有效行数为0、1行无假名、3行及以上：不计入证据
    
    -- 检查是否达到锁定条件
    if monolingual_streak >= LOCK_THRESHOLD then
        subtitle_type = "monolingual"
        mp.osd_message("检测到纯日语字幕", 1.5)
        return text
    elseif bilingual_streak >= LOCK_THRESHOLD then
        subtitle_type = "bilingual"
        -- 确定日语位置模式
        if jp_top_count > jp_bottom_count then
            jp_position = "top"
            mp.osd_message("检测到双语字幕 (日语在上)", 1.5)
        else
            jp_position = "bottom"
            mp.osd_message("检测到双语字幕 (日语在下)", 1.5)
        end
        return this.filter_bilingual_subtitle(text)
    end
    
    -- 未锁定时的返回逻辑：两行有效行时按假名返回，其他返回原文
    if effective_count == 2 then
        if first_is_jp and not second_is_jp then
            return effective_lines[1]
        elseif not first_is_jp and second_is_jp then
            return effective_lines[2]
        end
    end
    
    return text
end

-- 检查3字节UTF-8字符是否为假名
this.isKana = function(byte1, byte2, byte3)
    -- 平假名范围: ぁ (U+3041) 到 み (U+307F)
    -- UTF-8: E3 81 81 - E3 81 BF, byte2=129, byte3=129-191
    if byte1 == 227 and byte2 == 129 and (byte3 >= 129 and byte3 <= 191) then
        return true
    end
    -- 平假名范围续: む (U+3080) 到 ゖ (U+3096)
    -- UTF-8: E3 82 80 - E3 82 96, byte2=130, byte3=128-150
    if byte1 == 227 and byte2 == 130 and (byte3 >= 128 and byte3 <= 150) then
        return true
    end
    -- 平假名迭代符号: ゝ (U+309D) 到 ゟ (U+309F)
    -- UTF-8: E3 82 9D - E3 82 9F, byte2=130, byte3=157-159
    if byte1 == 227 and byte2 == 130 and (byte3 >= 157 and byte3 <= 159) then
        return true
    end
    -- 片假名范围: ァ (U+30A1) 到 ン (U+30BF)
    -- UTF-8: E3 82 A1 - E3 82 BF, byte2=130, byte3=161-191
    if byte1 == 227 and byte2 == 130 and (byte3 >= 161 and byte3 <= 191) then
        return true
    end
    -- 片假名范围续: ヴ (U+30C0) 到 ヺ (U+30FA)
    -- UTF-8: E3 83 80 - E3 83 BA, byte2=131, byte3=128-186
    if byte1 == 227 and byte2 == 131 and (byte3 >= 128 and byte3 <= 186) then
        return true
    end
    return false
end

-- 检查字符串是否为日语（通过检测假名）
this.isJapanese = function(str)
    if str == nil or str == "" then
        return false
    end
    local i = 1
    local len = #str
    while i <= len do
        local byte1 = string.byte(str, i)
        if byte1 >= 224 and byte1 <= 239 and i + 2 <= len then
            -- 3字节UTF-8字符
            local byte2 = string.byte(str, i + 1)
            local byte3 = string.byte(str, i + 2)
            if this.isKana(byte1, byte2, byte3) then
                return true
            end
            i = i + 3
        elseif byte1 >= 192 and byte1 <= 223 then
            i = i + 2  -- 2字节UTF-8
        elseif byte1 >= 240 then
            i = i + 4  -- 4字节UTF-8
        else
            i = i + 1  -- 1字节ASCII
        end
    end
    return false
end

this.is_empty = function(var)
    return var == nil or var == '' or (type(var) == 'table' and next(var) == nil)
end

this.contains_non_latin_letters = function(str)
    return str:match("[^%c%p%s%w—]")
end

this.capitalize_first_letter = function(string)
    return string:gsub("^%l", string.upper)
end

this.remove_leading_trailing_spaces = function(str)
    return str:gsub('^%s*(.-)%s*$', '%1')
end

this.remove_leading_trailing_dashes = function(str)
    return str:gsub('^[%-_]*(.-)[%-_]*$', '%1')
end

this.remove_text_in_parentheses = function(str)
    -- Remove text like （泣き声） or （ドアの開く音）
    -- No deletion is performed if the entire string is wrapped in parentheses.
    return str:gsub('%b()', function(s)
        if s == str then
            -- 如果整个字符串被括号包裹，保留不变
            return s
        else
            -- 否则，删除括号和其中的内容
            return ''
        end
    end):gsub('（.-）', function(s)
        if s == str then
            return s
        else
            return ''
        end
    end)
end

this.remove_newlines = function(str)
    -- 直接删除换行符，不替换为空格
    return str:gsub('[\n\r]+', '')
end

this.normalize_spaces = function(str)
    -- replace sequences of ASCII spaces or full-width ideographic spaces with a single ASCII space
    return str:gsub('　+', ' '):gsub('  +', " ")
end

this.trim = function(str)
    str = this.remove_leading_trailing_spaces(str)
    str = this.remove_text_in_parentheses(str)
    str = this.remove_newlines(str)
    str = this.normalize_spaces(str)
    return str
end

this.escape_special_characters = (function()
    local entities = {
        ['&'] = '&amp;',
        ['"'] = '&quot;',
        ["'"] = '&apos;',
        ['<'] = '&lt;',
        ['>'] = '&gt;',
    }
    return function(s)
        return s:gsub('[&"\'<>]', entities)
    end
end)()

this.remove_extension = function(filename)
    return filename:gsub('%.%w+$', '')
end

this.remove_special_characters = function(str)
    return str:gsub('[%c%p%s]', ''):gsub('　', '')
end

this.remove_text_in_brackets = function(str)
    return str:gsub('%b[]', ''):gsub('【.-】', '')
end

this.remove_filename_text_in_parentheses = function(str)
    return str:gsub('%b()', ''):gsub('（.-）', '')
end

this.remove_common_resolutions = function(str)
    -- Also removes empty leftover parentheses and brackets.
    return str:gsub("2160p", ""):gsub("1080p", ""):gsub("720p", ""):gsub("576p", ""):gsub("480p", ""):gsub("%(%)", ""):gsub("%[%]", "")
end

this.human_readable_time = function(seconds)
    if type(seconds) ~= 'number' or seconds < 0 then
        return 'empty'
    end

    local parts = {
        h = math.floor(seconds / 3600),
        m = math.floor(seconds / 60) % 60,
        s = math.floor(seconds % 60),
        ms = math.floor((seconds * 1000) % 1000),
    }

    local ret = string.format("%02dm%02ds%03dms", parts.m, parts.s, parts.ms)

    if parts.h > 0 then
        ret = string.format('%dh%s', parts.h, ret)
    end

    return ret
end

this.get_episode_number = function(filename)
    -- Reverses the filename to start the search from the end as the media title might contain similar numbers.
    local filename_reversed = filename:reverse()

    local ep_num_patterns = {
        "[%s_](%d?%d?%d)[pP]?[eE]", -- Starting with E or EP (case-insensitive). "Example Series S01E01 [94Z295D1]"
        "^(%d?%d?%d)[pP]?[eE]", -- Starting with E or EP (case-insensitive) at the end of filename. "Example Series S01E01"
        "%)(%d?%d?%d)%(", -- Surrounded by parentheses. "Example Series (12)"
        "%](%d?%d?%d)%[", -- Surrounded by brackets. "Example Series [01]"
        "%s(%d?%d?%d)%s", -- Surrounded by whitespace. "Example Series 124 [1080p 10-bit]"
        "_(%d?%d?%d)_", -- Surrounded by underscores. "Example_Series_04_1080p"
        "^(%d?%d?%d)[%s_]", -- Ending to the episode number. "Example Series 124"
        "(%d?%d?%d)%-edosipE", -- Prepended by "Episode-". "Example Episode-165"
    }

    local s, e, episode_num
    for _, pattern in pairs(ep_num_patterns) do
        s, e, episode_num = string.find(filename_reversed, pattern)
        if not this.is_empty(episode_num) then
            return #filename - e, #filename - s, episode_num:reverse()
        end
    end
end

this.notify = function(message, level, duration)
    level = level or 'info'
    duration = duration or 1
    msg[level](message)
    mp.osd_message(message, duration)
end

this.get_active_track = function(track_type)
    -- track_type == audio|sub
    for _, track in pairs(mp.get_property_native('track-list')) do
        if track.type == track_type and track.selected == true then
            return track
        end
    end
    return nil
end

this.has_video_track = function()
    return mp.get_property_native('vid') ~= false
end

this.has_audio_track = function()
    return mp.get_property_native('aid') ~= false
end

this.str_contains = function(str, pattern, search_plain)
    --- Return True if 'pattern' can be found in 'str'.
    --- Matching is case-insensitive.
    --- If 'search_plain' is True, turns off the pattern matching facilities.
    return not this.is_empty(str) and string.find(string.lower(str), string.lower(pattern), 1, search_plain) ~= nil
end

this.is_substr = function(str, substr)
    --- Return True if 'substr' is a substring of 'str'.
    --- Matching is case-insensitive.
    --- Plain search is used == turns off the pattern matching facilities.
    return this.str_contains(str, substr, true)
end

this.filter = function(arr, func)
    local filtered = {}
    for _, elem in ipairs(arr) do
        if func(elem) == true then
            table.insert(filtered, elem)
        end
    end
    return filtered
end

this.file_exists = function(filepath)
    if not this.is_empty(filepath) then
        local info = utils.file_info(filepath)
        if info and info.is_file and info.size > 0 then
            return true
        end
    end
    return false
end

this.equal = function(first, last)
    --- Test whether two values are equal
    if type(last) == 'table' then
        return (utils.format_json(first) == utils.format_json(last))
    else
        return (first == last)
    end
end

this.get_loaded_tracks = function(track_type)
    --- Return all sub tracks, audio tracks, etc.
    local function tracks_equal(track)
        return track.type == track_type
    end
    return this.filter(mp.get_property_native('track-list'), tracks_equal)
end

this.assert_equals = function(actual, expected)
    if this.equal(actual, expected) == false then
        mp.commandv("quit")
        error(string.format("TEST FAILED: Expected '%s', got '%s'", expected, actual))
    end
end

this.deep_copy = function(obj, seen)
    -- Handle non-tables and previously-seen tables.
    if type(obj) ~= 'table' then
        return obj
    end
    if seen and seen[obj] then
        return seen[obj]
    end

    -- New table; mark it as seen and copy recursively.
    local s = seen or {}
    local res = {}
    s[obj] = res
    for k, v in pairs(obj) do
        res[this.deep_copy(k, s)] = this.deep_copy(v, s)
    end
    return setmetatable(res, getmetatable(obj))
end

this.shallow_copy = function(from, to)
    if type(from) ~= 'table' then
        return from
    end
    to = to or {}
    for key, value in pairs(from) do
        to[key] = value
    end
    return to
end

this.maybe_require = function(module_name)
    -- ~/.config/mpv/scripts/ and the mpvacious dir
    local parent, child = utils.split_path(mp.get_script_directory())
    -- ~/.config/mpv/ and "scripts"
    parent, child = utils.split_path(parent:gsub("/$", ""))
    -- ~/.config/mpv/subs2srs_sub_filter
    local external_scripts_path = utils.join_path(parent, "subs2srs_sub_filter")

    local search_template = external_scripts_path .. "/?.lua;"
    local module_path = package.searchpath(module_name, search_template)

    if not module_path then
        return nil
    end

    local original_package_path = package.path
    package.path = search_template .. package.path

    local ok, loaded_module = pcall(require, module_name)

    package.path = original_package_path

    if not ok then
        error(
                string.format(
                        "Failed to load module '%s' from '%s'. Error: %s",
                        module_name,
                        module_path,
                        tostring(loaded_module)
                )
        )
    end

    return loaded_module
end

this.combine_lists = function(...)
    -- take many lists and output one list.
    local output = {}
    for _, list in ipairs({ ... }) do
        for _, item in ipairs(list) do
            table.insert(output, item)
        end
    end
    return output
end

this.run_tests = function()
    this.assert_equals(this.is_substr("abcd", "bc"), true)
    this.assert_equals(this.is_substr("abcd", "xyz"), false)
    this.assert_equals(this.is_substr("abcd", "^.*d.*$"), false)
    this.assert_equals(this.str_contains("abcd", "^.*d.*$"), true)
    this.assert_equals(this.str_contains("abcd", "^.*z.*$"), false)

    local ep_num_to_filename = {
        { nil, "A Whisker Away.mkv" },
        { nil, "[Placeholder] Gekijouban SHIROBAKO [Ma10p_1080p][x265_flac]" },
        { "06", "[Placeholder] Sono Bisque Doll wa Koi wo Suru - 06 [54E495D0]" },
        { "02", "(Hi10)_Kobayashi-san_Chi_no_Maid_Dragon_-_02_(BD_1080p)_(Placeholder)_(12C5D2B4)" },
        { "01", "[Placeholder] Koi to Yobu ni wa Kimochi Warui - 01 (1080p) [D517C9F0]" },
        { "01", "[Placeholder] Tsukimonogatari 01 [BD 1080p x264 10-bit FLAC] [5CD88145]" },
        { "01", "[Placeholder] 86 - Eighty Six - 01 (1080p) [1B13598F]" },
        { "00", "[Placeholder] Fate Stay Night - Unlimited Blade Works - 00 (BD 1080p Hi10 FLAC) [95590B7F]" },
        { "01", "House, M.D. S01E01 Pilot - Everybody Lies (1080p x265 Placeholder)" },
        { "165", "A Generic Episode-165" }
    }

    for _, case in pairs(ep_num_to_filename) do
        local expected, filename = this.unpack(case)
        local _, _, episode_num = this.get_episode_number(filename)
        this.assert_equals(episode_num, expected)
    end

    this.assert_equals(this.combine_lists({ 1, 2 }, { 3 }, {}, { 4, 5 }), { 1, 2, 3, 4, 5 })

    local t1 = {1,2,3}
    local t2 = {3,4,5}
    this.shallow_copy(t1, t2)
    this.assert_equals(t2, t1)
end

return this
