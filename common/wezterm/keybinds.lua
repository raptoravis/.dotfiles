local wezterm = require('wezterm')
local action = wezterm.action

local K = {}

-- Close every tab whose index is greater than the active tab.
-- Iterates from the rightmost tab leftward so indices stay valid as we close.
local function close_tabs_to_right(window, _)
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
    for i = #tabs, active_idx + 1, -1 do
        tabs[i]:activate()
        window:perform_action(action.CloseCurrentTab({ confirm = false }), window:active_pane())
    end
end

local function close_other_tabs(window, _)
    local mux_win = window:mux_window()
    local tabs = mux_win:tabs()
    local keep_id = window:active_tab():tab_id()
    for i = #tabs, 1, -1 do
        if tabs[i]:tab_id() ~= keep_id then
            tabs[i]:activate()
            window:perform_action(action.CloseCurrentTab({ confirm = false }), window:active_pane())
        end
    end
end

function K.keybinds(resurrect)
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

        -- Session save / restore (resurrect.wezterm)
        { key = 'w', mods = 'ALT', action = wezterm.action_callback(function(_, _)
            resurrect.state_manager.save_state(resurrect.workspace_state.get_workspace_state())
        end) },
        { key = 'W', mods = 'ALT', action = resurrect.window_state.save_window_action() },
        { key = 'T', mods = 'ALT', action = resurrect.tab_state.save_tab_action() },
        { key = 'r', mods = 'ALT', action = wezterm.action_callback(function(win, pane)
            resurrect.fuzzy_loader.fuzzy_load(win, pane, function(id, _)
                local state_type = string.match(id, '^([^/]+)')
                id = string.match(id, '([^/]+)$')
                id = string.match(id, '(.+)%.%..+$')
                local opts = {
                    relative = true,
                    restore_text = true,
                    on_pane_restore = resurrect.tab_state.default_on_pane_restore,
                }
                if state_type == 'workspace' then
                    local state = resurrect.state_manager.load_state(id, 'workspace')
                    resurrect.workspace_state.restore_workspace(state, opts)
                elseif state_type == 'window' then
                    local state = resurrect.state_manager.load_state(id, 'window')
                    resurrect.window_state.restore_window(pane:window(), state, opts)
                elseif state_type == 'tab' then
                    local state = resurrect.state_manager.load_state(id, 'tab')
                    resurrect.tab_state.restore_tab(pane:tab(), state, opts)
                end
            end)
        end) },

        -- Window
        { key = 'Enter', mods = 'ALT',       action = action.ShowLauncherArgs({ flags = 'LAUNCH_MENU_ITEMS' }) },
        { key = 'Enter', mods = 'CMD|SHIFT', action = action.ToggleFullScreen },
        { key = 'p', mods = 'ALT', action = action.ActivateCommandPalette },
        { key = 'p', mods = 'CTRL|SHIFT', action = action.ActivateCommandPalette },
        { key = 'q', mods = 'ALT', action = action.QuitApplication },

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
        { key = 'w', mods = 'CTRL|SHIFT',     action = wezterm.action_callback(close_tabs_to_right) },
        { key = 'w', mods = 'CTRL|ALT|SHIFT', action = wezterm.action_callback(close_other_tabs) },

        -- Signals
        { key = 'Backspace', mods = 'CTRL', action = action.SendString('\x03') },
    }
end

return K
