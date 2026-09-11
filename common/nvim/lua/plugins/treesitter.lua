if vim.g.vscode then
	return {}
end
  
return {
    {
        'nvim-treesitter/nvim-treesitter',
        lazy = false,
        build = ':TSUpdate',
        config = function()
            require('nvim-treesitter').setup({})

            require('nvim-treesitter').install({
                'bash',
                'c',
                'dockerfile',
                'go',
                'json',
                'lua',
                'markdown',
                'nu',
                'python',
                'rust',
                'terraform',
                'toml',
                'yaml',
            })

            -- Treesitter highlighting is a core Neovim feature, not auto-enabled by the plugin.
            vim.api.nvim_create_autocmd('FileType', {
                pattern = { '*' },
                callback = function()
                    pcall(vim.treesitter.start)
                end,
            })
        end,
    },

    {
        'nvim-treesitter/nvim-treesitter-textobjects',
        branch = 'main',
        dependencies = { 'nvim-treesitter/nvim-treesitter' },
        lazy = false,
        config = function()
            require('nvim-treesitter-textobjects').setup({
                select = {
                    lookahead = true, -- Automatically jump forward to textobj, similar to targets.vim
                },
            })

            local function ts_select(capture)
                return function()
                    require('nvim-treesitter-textobjects.select').select_textobject(capture, 'textobjects')
                end
            end

            -- You can use the capture groups defined in textobjects.scm
            vim.keymap.set({ 'x', 'o' }, 'aa', ts_select('@parameter.outer'))
            vim.keymap.set({ 'x', 'o' }, 'ia', ts_select('@parameter.inner'))
            vim.keymap.set({ 'x', 'o' }, 'af', ts_select('@function.outer'))
            vim.keymap.set({ 'x', 'o' }, 'if', ts_select('@function.inner'))
            vim.keymap.set({ 'x', 'o' }, 'ac', ts_select('@class.outer'))
            vim.keymap.set({ 'x', 'o' }, 'ic', ts_select('@class.inner'))
        end,
    },

    {
        'nvim-treesitter/nvim-treesitter-context',
        config = function()
            local tc = require('treesitter-context')
            tc.setup({
                enable = true,
                max_lines = 5,
                min_window_height = 0,
                line_numbers = true,
                multiline_threshold = 20,
                trim_scope = 'outer',
                mode = 'cursor',
                separator = '-',
                zindex = 20,
            })
            vim.keymap.set('n', '<leader>ct', tc.toggle, { silent = true })
            vim.keymap.set('n', '<leader>cu', tc.go_to_context, { silent = true })
        end,
    },
}
