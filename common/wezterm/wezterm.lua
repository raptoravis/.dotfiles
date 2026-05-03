local wezterm = require('wezterm')
local K = require('keybinds')
local F = require('functions')
local config = wezterm.config_builder()

-- Session save/load (wezterm-session-manager).
-- Cloned manually into ~/.config/wezterm/wezterm-session-manager/ by the
-- install script; pcall'd so a missing clone doesn't break startup.
--
-- Behavior:
--   - manual save  : Alt+s    (with toast)
--   - manual restore: Alt+r   (with toast)
--   - auto-save    : silent_save_state on window-focus-changed when the
--                    window loses focus. Catches alt-tab and most close
--                    paths (X button drops focus before window destruction).
--                    Also wired into Alt+q (save-then-quit) as a guaranteed
--                    save path. wezterm 20240203 has no before-quit event,
--                    so X-click-while-already-focused may miss the save.
--   - auto-restore : gui-startup spawns default window; first
--                    window-config-reloaded fire restores the saved state.
--                    gui-startup MUST spawn a window itself, otherwise
--                    wezterm sits with no windows and flashes on Windows.
local ok, session_manager = pcall(require, 'wezterm-session-manager/session-manager')
if not ok then session_manager = nil end

-- ~/.local/share/wezterm/sessions/ — used by both silent_save_state and the
-- patched session-manager.lua plugin. Outside config_dir on purpose:
-- automatically_reload_config watches config_dir, so writing the state file
-- there triggers a config reload mid-session and breaks restore.
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

local function silent_save_state(window)
    -- Skip auto-saves while session_save_blocked is set (during the brief
    -- gui-startup -> restore window). Otherwise a focus change during
    -- restore could overwrite the saved file with partial state.
    if wezterm.GLOBAL.session_save_blocked then return end
    pcall(function()
        local mux_win = window:mux_window()
        if not mux_win then return end
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
        local json = wezterm.json_encode(data)
        if json == wezterm.GLOBAL.session_last_json then return end
        local path = sessions_dir .. '/wezterm_state_' .. data.name .. '.json'
        local f = io.open(path, 'w')
        if f then
            f:write(json)
            f:close()
            wezterm.GLOBAL.session_last_json = json
        end
    end)
end

if session_manager then
    wezterm.on('save_session',    function(window) session_manager.save_state(window) end)
    wezterm.on('restore_session', function(window) session_manager.restore_state(window) end)

    -- Auto-save on focus loss only (no periodic / no update-status save).
    wezterm.on('window-focus-changed', function(window, _)
        if wezterm.GLOBAL.session_save_blocked then return end
        if not window:is_focused() then silent_save_state(window) end
    end)

    -- Save-then-quit: Alt+q first persists state, then quits. Defined here
    -- (not in keybinds.lua) because it needs the silent_save_state closure.
    wezterm.on('save_and_quit', function(window, _)
        silent_save_state(window)
        window:perform_action(wezterm.action.QuitApplication, window:active_pane())
    end)

    -- Auto-restore via gui-startup: fires exactly once per wezterm-gui process,
    -- unaffected by automatically_reload_config (which re-fires
    -- window-config-reloaded and resets wezterm.GLOBAL — observed empirically
    -- on wezterm 20240203 despite docs saying GLOBAL persists). Restore is
    -- deferred so the GUI window object is realized before the plugin's
    -- restore_state walks it. session_save_blocked prevents focus-change
    -- auto-save from racing the restore process.
    wezterm.on('gui-startup', function(cmd)
        wezterm.mux.spawn_window(cmd or {})
        wezterm.GLOBAL.session_save_blocked = true
        wezterm.time.call_after(0.5, function()
            for _, mux_win in ipairs(wezterm.mux.all_windows()) do
                local gui = mux_win:gui_window()
                if gui then
                    session_manager.restore_state(gui)
                    break
                end
            end
        end)
        wezterm.time.call_after(4, function()
            wezterm.GLOBAL.session_save_blocked = false
        end)
    end)
end

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
