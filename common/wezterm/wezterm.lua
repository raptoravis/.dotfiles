local wezterm = require('wezterm')
local K = require('keybinds')
local F = require('functions')
local config = wezterm.config_builder()

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
