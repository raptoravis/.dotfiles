local wezterm = require('wezterm')
local K = require('keybinds')
local F = require('functions')
local config = wezterm.config_builder()

-- ---------------------------------------------------------------------------
-- Session save/restore — self-contained, no external plugin.
--
-- Was previously based on danielcopper/wezterm-session-manager but its
-- restore reused initial_pane:send_text("exit\r") + spawn_tab loop, which
-- visibly flashes on Windows. We now reuse the initial pane via `cd <path>`
-- (no kill+spawn round-trip) so only the *additional* tabs spawn fresh
-- pwsh's. Cuts the flash and saves one full pwsh-profile load on launch.
--
-- State file: ~/.local/share/wezterm/sessions/wezterm_state_<workspace>.json
-- Outside wezterm.config_dir on purpose: automatically_reload_config watches
-- config_dir, and writing the state file there triggers a config reload
-- mid-session that resets wezterm.GLOBAL and re-fires gui-startup.
--
-- Behavior:
--   - Alt+s             manual save (with toast)
--   - Alt+r             manual restore (with toast)
--   - Alt+q             save-then-quit
--   - window-focus-changed (lose focus) -> silent auto-save
--   - gui-startup -> deferred silent auto-restore
-- ---------------------------------------------------------------------------
local sessions_dir = wezterm.home_dir .. '/.local/share/wezterm/sessions'
do
    local sep = package.config:sub(1, 1)
    if sep == '\\' then
        local win = sessions_dir:gsub('/', '\\')
        os.execute('cmd /c if not exist "' .. win .. '" mkdir "' .. win .. '" >nul 2>&1')
    else
        os.execute('mkdir -p "' .. sessions_dir .. '"')
    end
end

local function state_file(workspace)
    return sessions_dir .. '/wezterm_state_' .. workspace .. '.json'
end

-- Convert a wezterm cwd string ('file:///D:/path' or 'file://host/path') back
-- to a filesystem path the shell can `cd` into.
local function cwd_uri_to_path(uri)
    if not uri or uri == '' then return nil end
    local p = tostring(uri):gsub('^file://[^/]*', '')
    p = p:gsub('^/([A-Za-z]:)', '%1') -- /D:/x -> D:/x on Windows
    return p
end

local function collect_state(window)
    local mux_win = window:mux_window()
    if not mux_win then return nil end
    local data = { name = window:active_workspace(), tabs = {} }
    for _, tab in ipairs(mux_win:tabs()) do
        local tab_data = { tab_id = tostring(tab:tab_id()), panes = {} }
        for _, info in ipairs(tab:panes_with_info()) do
            table.insert(tab_data.panes, {
                pane_id = tostring(info.pane:pane_id()),
                index = info.index,
                is_active = info.is_active,
                is_zoomed = info.is_zoomed,
                left = info.left,
                top = info.top,
                width = info.width,
                height = info.height,
                pixel_width = info.pixel_width,
                pixel_height = info.pixel_height,
                cwd = tostring(info.pane:get_current_working_dir()),
                tty = tostring(info.pane:get_foreground_process_name()),
            })
        end
        table.insert(data.tabs, tab_data)
    end
    return data
end

local function silent_save_state(window)
    if wezterm.GLOBAL.session_save_blocked then return end
    pcall(function()
        local data = collect_state(window)
        if not data then return end
        local json = wezterm.json_encode(data)
        if json == wezterm.GLOBAL.session_last_json then return end
        local f = io.open(state_file(data.name), 'w')
        if f then
            f:write(json)
            f:close()
            wezterm.GLOBAL.session_last_json = json
        end
    end)
end

local function split_direction(curr, prev)
    return (curr.left == prev.left) and 'Bottom' or 'Right'
end

-- Returns true if the given foreground process name looks like a shell we can
-- safely send a `cd` line to without disturbing a running TUI.
local function is_shell(fg)
    if not fg then return false end
    fg = fg:lower()
    return fg:find('sh$') or fg:find('cmd%.exe$')
        or fg:find('powershell%.exe$') or fg:find('pwsh%.exe$')
        or fg:find('nu%.exe$') or fg:find('nu$')
end

local function silent_restore_state(window)
    local mux_win = window:mux_window()
    if not mux_win then return false end
    local tabs = mux_win:tabs()
    if #tabs ~= 1 or #tabs[1]:panes() ~= 1 then
        return false -- only restore into a fresh window
    end

    local f = io.open(state_file(window:active_workspace()), 'r')
    if not f then return false end
    local content = f:read('*a')
    f:close()
    local data = wezterm.json_parse(content)
    if not data or not data.tabs or #data.tabs == 0 then return false end

    local initial_pane = window:active_pane()
    local fg = initial_pane:get_foreground_process_name() or ''

    -- 1st saved tab reuses the initial tab/pane: send `cd` to the existing
    -- shell instead of killing it and spawning a new one. Avoids the flash.
    local first_tab = data.tabs[1]
    local first_cwd = cwd_uri_to_path(first_tab.panes[1].cwd)
    if first_cwd and is_shell(fg) then
        local cd
        if fg:lower():find('cmd%.exe$') then
            cd = string.format('cd /d "%s"\r', first_cwd)
        else
            cd = string.format('cd "%s"\r', first_cwd)
        end
        initial_pane:send_text(cd)
    end
    for j = 2, #first_tab.panes do
        local pd = first_tab.panes[j]
        local cwd = cwd_uri_to_path(pd.cwd)
        local opts = { direction = split_direction(pd, first_tab.panes[j - 1]) }
        if cwd then opts.cwd = cwd end
        pcall(function() initial_pane:split(opts) end)
    end

    for i = 2, #data.tabs do
        local td = data.tabs[i]
        local cwd = cwd_uri_to_path(td.panes[1].cwd)
        local new_tab = mux_win:spawn_tab(cwd and { cwd = cwd } or {})
        if not new_tab then break end
        for j = 2, #td.panes do
            local pd = td.panes[j]
            local pcwd = cwd_uri_to_path(pd.cwd)
            local opts = { direction = split_direction(pd, td.panes[j - 1]) }
            if pcwd then opts.cwd = pcwd end
            pcall(function() new_tab:active_pane():split(opts) end)
        end
    end
    return true
end

wezterm.on('save_session', function(window)
    silent_save_state(window)
    window:toast_notification('WezTerm', 'Workspace state saved', nil, 4000)
end)

wezterm.on('restore_session', function(window)
    if silent_restore_state(window) then
        window:toast_notification('WezTerm', 'Workspace state restored', nil, 4000)
    else
        window:toast_notification('WezTerm', 'No saved state for ' .. window:active_workspace(), nil, 4000)
    end
end)

wezterm.on('window-focus-changed', function(window, _)
    if wezterm.GLOBAL.session_save_blocked then return end
    if not window:is_focused() then silent_save_state(window) end
end)

wezterm.on('save_and_quit', function(window, _)
    silent_save_state(window)
    window:perform_action(wezterm.action.QuitApplication, window:active_pane())
end)

-- Auto-restore via gui-startup: fires once per wezterm-gui process, immune to
-- the automatically_reload_config / GLOBAL-reset issue we hit before. Restore
-- is deferred ~0.5s so the GUI window is realized.
wezterm.on('gui-startup', function(cmd)
    wezterm.mux.spawn_window(cmd or {})
    wezterm.GLOBAL.session_save_blocked = true
    wezterm.time.call_after(0.5, function()
        for _, mux_win in ipairs(wezterm.mux.all_windows()) do
            local gui = mux_win:gui_window()
            if gui then
                silent_restore_state(gui)
                break
            end
        end
    end)
    wezterm.time.call_after(4, function()
        wezterm.GLOBAL.session_save_blocked = false
    end)
end)

-- ---------------------------------------------------------------------------
-- Window size persistence
-- Default 140x40 if no saved state. Rewritten on every resize so the next
-- launch reopens at the same dimensions.
--
-- Stored under ~/.local/share/wezterm/ (data dir), not wezterm.config_dir,
-- because automatically_reload_config watches the config dir — writing the
-- state file there would trigger a config reload on every resize.
-- ---------------------------------------------------------------------------
local state_path = (os.getenv('USERPROFILE') or os.getenv('HOME') or '')
    .. '/.local/share/wezterm/window-state.json'

local function read_window_state()
    local f = io.open(state_path, 'r')
    if not f then return nil, nil end
    local content = f:read('*a')
    f:close()
    local cols = tonumber(content:match('"cols"%s*:%s*(%d+)'))
    local rows = tonumber(content:match('"rows"%s*:%s*(%d+)'))
    return cols, rows
end

local function write_window_state(cols, rows)
    local f = io.open(state_path, 'w')
    if not f then return end
    f:write(string.format('{"cols":%d,"rows":%d}\n', cols, rows))
    f:close()
end

-- Launch
local os_name = F.detect_os()
config.default_prog = F.get_default_program()
config.default_cwd = F.get_default_cwd()
config.automatically_reload_config = true

config.launch_menu = F.get_launch_menu()

-- Colors
config.color_scheme = '{{theme_wezterm}}'
local color_table = wezterm.color.get_builtin_schemes()[config.color_scheme]
wezterm.GLOBAL.color_table = color_table
config.colors = {
    compose_cursor = color_table.ansi[2],
    cursor_bg = color_table.indexed[16] or color_table.ansi[2],
    tab_bar = {
        background = color_table.background,
        active_tab = { bg_color = color_table.background, fg_color = color_table.foreground },
        inactive_tab = { bg_color = color_table.background, fg_color = color_table.foreground },
        inactive_tab_hover = { bg_color = color_table.background, fg_color = color_table.foreground },
        inactive_tab_edge = color_table.background,
        new_tab = { bg_color = color_table.ansi[1], fg_color = color_table.foreground },
        new_tab_hover = { bg_color = color_table.ansi[1], fg_color = color_table.ansi[2], intensity = 'Bold' },
    },
}
config.window_frame = {
    font = wezterm.font({ family = 'JetBrains Mono', weight = 'Bold' }),
    font_size = 10.0,
    active_titlebar_bg = color_table.background,
    inactive_titlebar_bg = color_table.background,
}

-- Window
config.max_fps = 144
config.adjust_window_size_when_changing_font_size = false
config.text_background_opacity = 1.0
config.window_background_opacity = 1.0
config.window_close_confirmation = 'NeverPrompt'
if os_name == 'windows' then
    config.window_decorations = 'INTEGRATED_BUTTONS|RESIZE'
    config.integrated_title_button_alignment = 'Right'
    config.integrated_title_buttons = { 'Hide', 'Maximize', 'Close' }
else
    config.window_decorations = 'TITLE|RESIZE'
end
config.window_padding = {
    left = 0,
    right = 0,
    top = 0,
    bottom = 0,
}

-- Initial window size — restore last saved dimensions or fall back to default.
local saved_cols, saved_rows = read_window_state()
config.initial_cols = saved_cols or 140
config.initial_rows = saved_rows or 40

-- Font
config.font = wezterm.font_with_fallback({ 'FiraCode Nerd Font', 'FiraCode NF', 'JetBrains Mono' })
config.font_size = F.get_os_font_size()
config.warn_about_missing_glyphs = false

-- Scrolling
config.enable_scroll_bar = false
config.scrollback_lines = 10000

-- Tab bar
config.enable_tab_bar = true
config.hide_tab_bar_if_only_one_tab = false
config.show_new_tab_button_in_tab_bar = true
config.show_tab_index_in_tab_bar = true
config.show_tabs_in_tab_bar = true
config.use_fancy_tab_bar = true

-- Keys
config.enable_kitty_keyboard = false
config.disable_default_key_bindings = false
config.keys = K.keybinds()

-- Events
wezterm.on('window-config-reloaded', function(window, _)
    F.reset_opacity(window, config)
end)

wezterm.on('format-tab-title', function(tab, tabs)
    return F.get_tab_title(tab, tabs)
end)

wezterm.on('opacity-decrease', function(window, _)
    F.lower_opacity(window, config)
end)

wezterm.on('opacity-increase', function(window, _)
    F.increase_opacity(window, config)
end)

wezterm.on('opacity-reset', function(window, _)
    F.reset_opacity(window, config)
end)

-- Persist window size on resize so the next launch reopens at the same size.
-- Skipped while in fullscreen so F11 toggles don't clobber the saved dims.
wezterm.on('window-resized', function(window, pane)
    if window:get_dimensions().is_full_screen then return end
    local dims = pane:get_dimensions()
    if dims and dims.cols and dims.viewport_rows then
        write_window_state(dims.cols, dims.viewport_rows)
    end
end)

return config
