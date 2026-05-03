local wezterm = require('wezterm')
local nerdfonts = wezterm.nerdfonts
local F = {}

function F.is_vim(pane)
    return pane:get_user_vars().IS_NVIM == 'true'
end

function F.detect_os()
    local sep = package.config:sub(1, 1)
    if sep == '\\' then
        return 'windows'
    elseif wezterm.target_triple:find('darwin') then
        return 'macos'
    end
    return 'linux'
end

function F.get_os_font_size()
    local os_name = F.detect_os()
    if os_name == 'windows' then
        return 12.0
    elseif os_name == 'macos' then
        return 16.0
    end
    return 12.0
end

function F.get_default_program()
    local os_name = F.detect_os()
    if os_name == 'windows' then
        return { 'pwsh.exe', '-NoLogo' }
    end
    return { 'zsh' }
end

function F.get_default_cwd()
    if F.detect_os() == 'windows' then
        return 'D:\\dev'
    end
    return os.getenv('HOME') or '~'
end

function F.get_launch_menu()
    local os_name = F.detect_os()
    if os_name == 'windows' then
        return {
            { label = 'PowerShell 7',       args = { 'pwsh.exe', '-NoLogo' } },
            { label = 'WSL (zsh)',          args = { 'wsl.exe', '--cd', '~' } },
            { label = 'Windows PowerShell', args = { 'powershell.exe' } },
            { label = 'Command Prompt',     args = { 'cmd.exe' } },
        }
    end
    return {
        { label = 'zsh',  args = { 'zsh', '-l' } },
        { label = 'bash', args = { 'bash', '-l' } },
    }
end

function F.get_pane_type(pane)
    local proc = (pane.foreground_process_name or ''):lower()
    if proc:match('pwsh') or proc:match('powershell') or proc:match('cmd') then
        return 'windows'
    end
    if F.detect_os() == 'macos' then
        return 'macos'
    end
    return 'wsl'
end

-- Extract the basename of a pane's current_working_dir.
-- Handles both modern wezterm (Url userdata with .file_path) and older
-- string-form 'file://host/path'. Returns '' if cwd is unavailable.
function F.get_cwd_label(pane)
    local cwd_uri = pane.current_working_dir
    if not cwd_uri then return '' end

    local path
    if type(cwd_uri) == 'userdata' then
        path = cwd_uri.file_path
    else
        path = tostring(cwd_uri):gsub('^file://[^/]*', '')
    end
    if not path or path == '' then return '' end

    -- Normalize: strip leading slash before drive letter (Windows: /D:/...),
    -- replace ~ for HOME, then take the last path segment.
    path = path:gsub('^/([A-Za-z]:)', '%1')
    path = path:gsub('[/\\]+$', '')

    local home = os.getenv('USERPROFILE') or os.getenv('HOME')
    if home and path == home then return '~' end

    local basename = path:match('([^/\\]+)$')
    return basename or path
end

function F.get_tab_title(tab, tabs)
    local colors = wezterm.GLOBAL.color_table
    local tab_number = tostring(tab.tab_index + 1)
    local pane_type = F.get_pane_type(tab.active_pane)
    local env_icon
    if pane_type == 'macos' then
        env_icon = nerdfonts.dev_apple
    elseif pane_type == 'wsl' then
        env_icon = nerdfonts.dev_linux
    else
        env_icon = nerdfonts.md_microsoft_windows
    end

    local cwd = F.get_cwd_label(tab.active_pane)
    local label = ' ' .. env_icon .. ' ' .. tab_number
    if cwd ~= '' then label = label .. '  ' .. cwd end
    label = label .. ' '

    if tab.is_active then
        return {
            { Background = { Color = colors.ansi[1] } },
            { Foreground = { Color = colors.ansi[2] } },
            { Attribute = { Intensity = 'Bold' } },
            { Text = label },
        }
    else
        return {
            { Background = { Color = colors.ansi[1] } },
            { Foreground = { Color = colors.foreground } },
            { Text = label },
        }
    end
end

function F.reset_opacity(window, config)
    local overrides = window:get_config_overrides() or {}
    overrides.text_background_opacity = config.text_background_opacity
    overrides.window_background_opacity = config.window_background_opacity
    window:set_config_overrides(overrides)
end

function F.lower_opacity(window, config)
    local overrides = window:get_config_overrides() or {}

    if window:get_config_overrides() then
        overrides.text_background_opacity =
            tonumber(string.format('%.2f', window:get_config_overrides().text_background_opacity))
        overrides.window_background_opacity =
            tonumber(string.format('%.2f', window:get_config_overrides().window_background_opacity))
    else
        overrides.text_background_opacity = config.text_background_opacity
        overrides.window_background_opacity = config.window_background_opacity
    end

    if overrides.window_background_opacity > 0 and overrides.window_background_opacity <= 1 then
        overrides.text_background_opacity = overrides.text_background_opacity - 0.05
        overrides.window_background_opacity = overrides.window_background_opacity - 0.05
        window:set_config_overrides(overrides)
    end
end

function F.increase_opacity(window, config)
    local overrides = window:get_config_overrides() or {}

    if window:get_config_overrides() then
        overrides.text_background_opacity =
            tonumber(string.format('%.2f', window:get_config_overrides().text_background_opacity))
        overrides.window_background_opacity =
            tonumber(string.format('%.2f', window:get_config_overrides().window_background_opacity))
    else
        overrides.text_background_opacity = config.text_background_opacity
        overrides.window_background_opacity = config.window_background_opacity
    end

    if overrides.window_background_opacity >= 0 and overrides.window_background_opacity < 1 then
        overrides.text_background_opacity = overrides.text_background_opacity + 0.05
        overrides.window_background_opacity = overrides.window_background_opacity + 0.05
        window:set_config_overrides(overrides)
    end
end

return F
