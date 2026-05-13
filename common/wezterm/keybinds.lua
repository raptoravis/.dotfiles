local wezterm = require('wezterm')
local action = wezterm.action

local K = {}

local function confirm(window, pane, prompt, on_yes)
    window:perform_action(action.InputSelector({
        title = prompt,
        choices = { { label = 'No' }, { label = 'Yes' } },
        fuzzy = false,
        action = wezterm.action_callback(function(inner_window, inner_pane, _, label)
            if label == 'Yes' then on_yes(inner_window, inner_pane) end
        end),
    }), pane)
end

-- Close every tab whose index is greater than the active tab.
-- Iterates from the rightmost tab leftward so indices stay valid as we close.
local function close_tabs_to_right(window, pane)
    local mux_win = window:mux_window()
    local tabs = mux_win:tabs()
    local active_idx
    for i, t in ipairs(tabs) do
        if t:tab_id() == window:active_tab():tab_id() then
            active_idx = i
            break
        end
    end
    if not active_idx then return end
    local count = #tabs - active_idx
    if count <= 0 then return end
    confirm(window, pane, 'Close ' .. count .. ' tab(s) to the right?', function(w)
        local ts = w:mux_window():tabs()
        for i = #ts, active_idx + 1, -1 do
            ts[i]:activate()
            w:perform_action(action.CloseCurrentTab({ confirm = false }), w:active_pane())
        end
    end)
end

local function close_current_tab(window, pane)
    confirm(window, pane, 'Close this tab?', function(w)
        w:perform_action(action.CloseCurrentTab({ confirm = false }), w:active_pane())
    end)
end

local function close_other_tabs(window, pane)
    local mux_win = window:mux_window()
    local tabs = mux_win:tabs()
    local keep_id = window:active_tab():tab_id()
    local count = #tabs - 1
    if count <= 0 then return end
    confirm(window, pane, 'Close ' .. count .. ' other tab(s)?', function(w)
        local ts = w:mux_window():tabs()
        for i = #ts, 1, -1 do
            if ts[i]:tab_id() ~= keep_id then
                ts[i]:activate()
                w:perform_action(action.CloseCurrentTab({ confirm = false }), w:active_pane())
            end
        end
    end)
end

function K.keybinds()
    return {
        -- Clipboard
        { key = 'c', mods = 'CTRL', action = wezterm.action_callback(function(window, pane)
            local has_selection = window:get_selection_text_for_pane(pane) ~= ''
            if has_selection then
                window:perform_action(action.CopyTo('ClipboardAndPrimarySelection'), pane)
                window:perform_action(action.ClearSelection, pane)
            else
                window:perform_action(action.SendKey({ key = 'c', mods = 'CTRL' }), pane)
            end
        end) },
        { key = 'v', mods = 'CTRL', action = action.PasteFrom('Clipboard') },

        -- Session save / restore (wezterm-session-manager).
        -- load_session is omitted: load_state is unimplemented in the plugin
        -- (TODO in upstream); auto-restore happens on launch instead.
        { key = 's', mods = 'ALT', action = action.EmitEvent('save_session') },
        { key = 'r', mods = 'ALT', action = action.EmitEvent('restore_session') },

        -- Window
        { key = 'Enter', mods = 'ALT',       action = action.ShowLauncherArgs({ flags = 'LAUNCH_MENU_ITEMS' }) },
        { key = 'Enter', mods = 'CMD|SHIFT', action = action.ToggleFullScreen },
        { key = 'p', mods = 'ALT', action = action.ActivateCommandPalette },
        { key = 'p', mods = 'CTRL|SHIFT', action = action.ActivateCommandPalette },
        { key = 'q', mods = 'ALT', action = action.EmitEvent('save_and_quit') },

        -- Search
        { key = '/', mods = 'ALT', action = action.Search({ CaseInSensitiveString = '' }) },

        -- Font Size
        { key = '0', mods = 'CTRL', action = action.ResetFontSize },
        { key = '-', mods = 'CTRL', action = action.DecreaseFontSize },
        { key = '_', mods = 'CTRL|SHIFT', action = action.IncreaseFontSize },

        -- Opacity
        { key = '0', mods = 'ALT', action = action.EmitEvent('opacity-reset') },
        { key = '-', mods = 'ALT', action = action.EmitEvent('opacity-decrease') },
        { key = '_', mods = 'ALT|SHIFT', action = action.EmitEvent('opacity-increase') },

        -- Tabs
        { key = 'w', mods = 'CTRL',           action = wezterm.action_callback(close_current_tab) },
        { key = 'w', mods = 'CTRL|SHIFT',     action = wezterm.action_callback(close_tabs_to_right) },
        { key = 'w', mods = 'CTRL|ALT|SHIFT', action = wezterm.action_callback(close_other_tabs) },

        -- Yazi (new tab)
        { key = 'y', mods = 'ALT', action = action.SpawnCommandInNewTab({ args = { 'yazi' } }) },

        -- Signals
        { key = 'Backspace', mods = 'CTRL', action = action.SendString('\x03') },
    }
end

return K
