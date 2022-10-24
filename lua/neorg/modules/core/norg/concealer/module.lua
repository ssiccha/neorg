--[[
    File: Concealer
    Title: Concealer Module for Neorg
    Summary: Enhances the basic Neorg experience by using icons instead of text.
    ---
This module handles the iconification and concealing of several different
syntax elements in your document.

It's also directly responsible for displaying completion levels
in situations like this:
```norg
* Do Some Things
- [ ] Thing A
- [ ] Thing B
```

Where it will display this instead:
```norg
* Do Some Things (0 of 2) [0% complete]
- [ ] Thing A
- [ ] Thing B
```

Once anticonceal (https://github.com/neovim/neovim/pull/9496) is
a thing, punctuation can be added (without removing the whitespace
between the icon and actual text) like so:

```lua
icon = module.private.ordered_concealing.punctuation.dot(
    module.private.ordered_concealing.icon_renderer.numeric
)
```

Note: this will produce icons like `1.`, `2.`, etc.

You can even chain multiple punctuation wrappers like so:

```lua
icon = module.private.ordered_concealing.punctuation.parenthesis(
    module.private.ordered_concealing.punctuation.dot(
        module.private.ordered_concealing.icon_renderer.numeric
    )
)
```

Note: this will produce icons like `1.)`, `2.)`, etc.
--]]

require("neorg.modules.base")

local module = neorg.modules.create("core.norg.concealer")

--- Schedule a function if there is no debounce active or if deferred updates have been disabled
---@param func function #Any function to execute
local function schedule(func)
    vim.schedule(function()
        if
            module.private.disable_deferred_updates
            or (
                (module.private.debounce_counters[vim.api.nvim_win_get_cursor(0)[1] + 1] or 0)
                >= module.config.public.performance.max_debounce
            )
        then
            return
        end

        func()
    end)
end

local function add_to_counters_if_todo_node(node, results)
    if vim.startswith(node:type(), "todo_item") then
        local type_node = node:named_child(1)

        if type_node then
            local todo_item_type = type_node:type():sub(string.len("todo_item_") + 1)
            local resulting_todo_item = results[todo_item_type] or 0

            results[todo_item_type] = resulting_todo_item + 1
            results.total = results.total + (todo_item_type == "cancelled" and 0 or 1)
        end
    end
end

local function count_todo_nodes_under_node(root_node, results)
    add_to_counters_if_todo_node(root_node, results)
    for child_node in root_node:iter_children() do
        count_todo_nodes_under_node(child_node, results)
    end
end

module.setup = function()
    return {
        success = true,
        requires = {
            "core.autocommands",
            "core.integrations.treesitter",
        },
        imports = {
            "preset_basic",
            "preset_varied",
            "preset_diamond",
        },
    }
end

module.private = {
    icon_namespace = vim.api.nvim_create_namespace("neorg-conceals"),
    code_block_namespace = vim.api.nvim_create_namespace("neorg-code-blocks"),
    completion_level_namespace = vim.api.nvim_create_namespace("neorg-completion-level"),
    icons = {},

    largest_change_start = -1,
    largest_change_end = -1,

    last_change = {
        active = false,
        line = 0,
    },

    disable_deferred_updates = false,
    debounce_counters = {},

    enabled = true,

    attach_uid = 0,
}

---@class core.norg.concealer
module.public = {

    --- Triggers an icon set for the current buffer
    ---@param buf number #The ID of the buffer to apply conceals in
    ---@param has_conceal boolean #Whether or not concealing is enabled
    ---@param icon_set table #The icon set to use
    ---@param namespace number #The extmark namespace to use when setting extmarks
    ---@param from? number #The line number to start parsing from (used for incremental updates)
    ---@param to? number #The line number to keep parsing to (used for incremental updates)
    trigger_icons = function(buf, has_conceal, icon_set, namespace, from, to)
        -- Get old extmarks - this is done to reduce visual glitches; all old extmarks are stored,
        -- the new extmarks are applied on top of the old ones, then the old ones are deleted.
        local old_extmarks = module.public.get_old_extmarks(buf, namespace, from, to and to - 1)

        -- Get the root node of the document (required to iterate over query captures)
        local document_root = module.required["core.integrations.treesitter"].get_document_root(buf)

        if not document_root then
            return
        end

        -- Loop through all icons that the user has enabled
        for _, icon_data in ipairs(icon_set) do
            schedule(function()
                if icon_data.query then
                    -- Attempt to parse the query provided by `icon_data.query`
                    -- A query must have at least one capture, e.g. "(test_node) @icon"
                    local query = vim.treesitter.parse_query("norg", icon_data.query)

                    -- This is a mapping of [id] = to_omit pairs, where `id` is a treesitter
                    -- node's id and `to_omit` is a boolean.
                    -- The reason we do this is because some nodes should not be iconified
                    -- if `conceallevel` > 2.
                    local nodes_to_omit = {}

                    -- Go through every found node and try to apply an icon to it
                    -- The reason `iter_prepared_matches` and other `nvim-treesitter` functions are used here is because
                    -- we also want to support special captures and predicates like `(#has-parent?)`
                    for id, node in query:iter_captures(document_root, buf, from or 0, to or -1) do
                        local capture = query.captures[id]
                        local rs, _, re = node:range()

                        -- If the node has a `no-conceal` capture name then omit it
                        -- when rendering icons.
                        if capture == "no-conceal" and has_conceal then
                            nodes_to_omit[node:id()] = true
                        end

                        if capture == "icon" and not nodes_to_omit[node:id()] then
                            if rs < (from or 0) or re > (to or math.huge) then
                                goto continue
                            end

                            -- Extract both the text and the range of the node
                            local text = module.required["core.integrations.treesitter"].get_node_text(node, buf)
                            local range = module.required["core.integrations.treesitter"].get_node_range(node)

                            -- Set the offset to 0 here. The offset is a special value that, well, offsets
                            -- the location of the icon column-wise
                            -- It's used in scenarios where the node spans more than what we want to iconify.
                            -- A prime example of this is the todo item, whose content looks like this: "[x]".
                            -- We obviously don't want to iconify the entire thing, this is why we will tell Neorg
                            -- to use an offset of 1 to start the icon at the "x"
                            local offset = 0

                            -- The extract function is used exactly to calculate this offset
                            -- If that function is present then run it and grab the return value
                            if icon_data.extract then
                                offset = icon_data.extract(text, node) or 0
                            end

                            -- Every icon can also implement a custom "render" function that can allow for things like multicoloured icons
                            -- This is primarily used in nested quotes
                            -- The "render" function must return a table of this structure: { { "text", "highlightgroup1" }, { "optionally more text", "higlightgroup2" } }
                            if not icon_data.render then
                                module.public._set_extmark(
                                    buf,
                                    icon_data.icon,
                                    icon_data.highlight,
                                    namespace,
                                    range.row_start,
                                    range.row_end,
                                    range.column_start + offset,
                                    range.column_end,
                                    false,
                                    "combine"
                                )
                            else
                                module.public._set_extmark(
                                    buf,
                                    icon_data:render(text, node),
                                    icon_data.highlight,
                                    namespace,
                                    range.row_start,
                                    range.row_end,
                                    range.column_start + offset,
                                    range.column_end,
                                    false,
                                    "combine"
                                )
                            end
                        end

                        ::continue::
                    end
                end
            end)
        end

        -- After we have applied every extmark we can remove the old ones
        schedule(function()
            neorg.lib.map(old_extmarks, function(_, id)
                vim.api.nvim_buf_del_extmark(buf, namespace, id)
            end)
        end)
    end,

    --- Dims code blocks in the buffer
    ---@param buf number #The buffer to apply the dimming in
    ---@param from? number #The line number to start parsing from (used for incremental updates)
    ---@param to? number #The line number to keep parsing until (used for incremental updates)
    trigger_code_block_highlights = function(buf, has_conceal, from, to)
        -- If the code block dimming is disabled, return right away.
        if not module.config.public.dim_code_blocks.enabled then
            return
        end

        -- Similarly to `trigger_icons()`, we gather all old extmarks here, apply the new dims on top of the old ones,
        -- then delete the old extmarks to prevent flickering
        local old_extmarks = {}

        -- The next block of code will be responsible for dimming code blocks accordingly
        local tree = module.required["core.integrations.treesitter"].get_document_root(buf)

        -- If the tree is valid then attempt to perform the query
        if tree then
            -- Query all code blocks
            local ok, query = pcall(
                vim.treesitter.parse_query,
                "norg",
                [[(
                    (ranged_verbatim_tag (tag_name) @_name) @tag
                    (#any-of? @_name "code" "embed")
                )]]
            )

            -- If something went wrong then go bye bye
            if not ok or not query then
                return
            end

            -- Go through every found capture
            for id, node in query:iter_captures(tree:root(), buf, from or 0, to or -1) do
                local id_name = query.captures[id]

                -- If the capture name is "tag" then that means we're dealing with our ranged_verbatim_tag
                if id_name == "tag" then
                    -- Get the range of the code block
                    local range = module.required["core.integrations.treesitter"].get_node_range(node)

                    vim.list_extend(
                        old_extmarks,
                        module.public.get_old_extmarks(
                            buf,
                            module.private.code_block_namespace,
                            range.row_start,
                            range.row_end
                        )
                    )

                    schedule(function()
                        if module.config.public.dim_code_blocks.conceal then
                            pcall(
                                vim.api.nvim_buf_set_extmark,
                                buf,
                                module.private.code_block_namespace,
                                range.row_start,
                                0,
                                {
                                    end_col = (vim.api.nvim_buf_get_lines(
                                        buf,
                                        range.row_start,
                                        range.row_start + 1,
                                        false
                                    )[1] or ""):len(),
                                    conceal = "",
                                }
                            )
                            pcall(
                                vim.api.nvim_buf_set_extmark,
                                buf,
                                module.private.code_block_namespace,
                                range.row_end,
                                0,
                                {
                                    end_col = (
                                        vim.api.nvim_buf_get_lines(buf, range.row_end, range.row_end + 1, false)[1]
                                        or ""
                                    ):len(),
                                    conceal = "",
                                }
                            )
                        end

                        if
                            module.config.public.dim_code_blocks.conceal
                            and module.config.public.dim_code_blocks.adaptive
                        then
                            module.config.public.dim_code_blocks.content_only = has_conceal
                        end

                        if module.config.public.dim_code_blocks.content_only then
                            range.row_start = range.row_start + 1
                            range.row_end = range.row_end - 1
                        end

                        local width = module.config.public.dim_code_blocks.width
                        local hl_eol = width == "fullwidth"

                        local lines = vim.api.nvim_buf_get_lines(
                            buf,
                            range.row_start,
                            (range.row_end >= vim.api.nvim_buf_line_count(buf) and range.row_start or range.row_end + 1),
                            false
                        )

                        local longest_len = 0

                        if width == "content" then
                            for _, line in ipairs(lines) do
                                longest_len = math.max(longest_len, vim.api.nvim_strwidth(line))
                            end
                        end

                        -- Go through every line in the code block and give it a magical highlight
                        for i, line in ipairs(lines) do
                            local linenr = range.row_start + (i - 1)
                            local line_width = vim.api.nvim_strwidth(line)

                            -- If our line is valid and it's not too short then apply the dimmed highlight
                            if line and line:len() >= range.column_start then
                                module.public._set_extmark(
                                    buf,
                                    nil,
                                    "@neorg.tags.ranged_verbatim.code_block",
                                    module.private.code_block_namespace,
                                    linenr,
                                    linenr + 1,
                                    math.max(range.column_start - module.config.public.dim_code_blocks.padding.left, 0),
                                    nil,
                                    hl_eol,
                                    "blend",
                                    nil,
                                    nil,
                                    true
                                )

                                if width == "content" then
                                    module.public._set_extmark(
                                        buf,
                                        {
                                            {
                                                string.rep(
                                                    " ",
                                                    longest_len
                                                        - line_width
                                                        + module.config.public.dim_code_blocks.padding.right
                                                ),
                                                "@neorg.tags.ranged_verbatim.code_block",
                                            },
                                        },
                                        nil,
                                        module.private.code_block_namespace,
                                        linenr,
                                        linenr + 1,
                                        line_width,
                                        nil,
                                        hl_eol,
                                        "blend",
                                        nil,
                                        nil,
                                        true
                                    )
                                end
                            else
                                -- There may be scenarios where the line is empty, or the line is shorter than the indentation
                                -- level of the code block, in that case we place the extmark at the very beginning of the line
                                -- and pad it with enough spaces to "emulate" the existence of whitespace
                                module.public._set_extmark(
                                    buf,
                                    {
                                        {
                                            string.rep(
                                                " ",
                                                math.max(
                                                    range.column_start
                                                        - module.config.public.dim_code_blocks.padding.left,
                                                    0
                                                )
                                            ),
                                        },
                                        (width == "content" and {
                                            string.rep(
                                                " ",
                                                math.max(
                                                    (longest_len - range.column_start)
                                                        + module.config.public.dim_code_blocks.padding.left
                                                        + module.config.public.dim_code_blocks.padding.right
                                                        - math.max(
                                                            module.config.public.dim_code_blocks.padding.left
                                                                - range.column_start,
                                                            0
                                                        ),
                                                    0
                                                )
                                            ),
                                            "@neorg.tags.ranged_verbatim.code_block",
                                        } or nil),
                                    },
                                    "@neorg.tags.ranged_verbatim.code_block",
                                    module.private.code_block_namespace,
                                    linenr,
                                    linenr + 1,
                                    0,
                                    nil,
                                    hl_eol,
                                    "blend",
                                    nil,
                                    nil,
                                    true
                                )
                            end
                        end
                    end)
                end
            end

            schedule(function()
                neorg.lib.map(old_extmarks, function(_, id)
                    vim.api.nvim_buf_del_extmark(buf, module.private.code_block_namespace, id)
                end)
            end)
        end
    end,

    --- Mostly a wrapper around vim.api.nvim_buf_set_extmark in order to make it safer
    ---@param text string|table #The virtual text to overlay (usually the icon)
    ---@param highlight string #The name of a highlight to use for the icon
    ---@param line_number number #The line number to apply the extmark in
    ---@param end_line number #The last line number to apply the extmark to (useful if you want an extmark to exist for more than one line)
    ---@param start_column number #The start column of the conceal
    ---@param end_column number #The end column of the conceal
    ---@param whole_line boolean #If true will highlight the whole line (like in diffs)
    ---@param mode string #"replace"/"combine"/"blend" - the highlight mode for the extmark
    ---@param pos string #"overlay"/"eol"/"right_align" - the position to place the extmark in (defaults to "overlay")
    ---@param conceal string #The char to use for concealing
    ---@param fixed boolean #When true the extmark will not move
    _set_extmark = function(
        buf,
        text,
        highlight,
        ns,
        line_number,
        end_line,
        start_column,
        end_column,
        whole_line,
        mode,
        pos,
        conceal,
        fixed
    )
        if not vim.api.nvim_buf_is_loaded(buf) then
            return
        end

        -- If the text type is a string then convert it into something that Neovim's extmark API can understand
        if type(text) == "string" then
            text = { { text, highlight } }
        end

        -- Attempt to call vim.api.nvim_buf_set_extmark with all the parameters
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, line_number, start_column, {
            end_col = end_column,
            hl_group = highlight,
            end_row = end_line,
            virt_text = text,
            virt_text_pos = pos or "overlay",
            virt_text_win_col = (fixed and start_column or nil),
            hl_mode = mode,
            hl_eol = whole_line,
            conceal = conceal,
        })
    end,

    --- Gets the already present extmarks in a buffer
    ---@param buf number #The buffer to get the extmarks from
    ---@param namespace number #The namespace to query the extmarks from
    ---@param from? number #The first line to extract the extmarks from
    ---@param to? number #The last line to extract the extmarks from
    ---@return list #A list of extmark IDs
    get_old_extmarks = function(buf, namespace, from, to)
        return neorg.lib.map(
            neorg.lib.inline_pcall(
                vim.api.nvim_buf_get_extmarks,
                buf,
                namespace,
                from and { from, 0 } or 0,
                to and { to, -1 } or -1,
                {}
            ) or {},
            function(_, v)
                return v[1]
            end
        )
    end,

    completion_levels = {
        --- Displays the completion level with incremental updates
        ---@param buf number #The number of the buffer to parse
        ---@param line number #The line number the user is at
        trigger_completion_levels_incremental = function(buf, line)
            -- Get the root node of the document (required to iterate over query captures)
            local document_root = module.required["core.integrations.treesitter"].get_document_root(buf)

            if not document_root then
                return
            end

            local current_node = module.required["core.integrations.treesitter"].get_first_node_on_line(buf, line)

            if not current_node or current_node:type() == "document" then
                current_node = module.required["core.integrations.treesitter"].get_ts_utils().get_node_at_cursor()

                if not current_node then
                    return
                end
            end

            local parent = module.required["core.integrations.treesitter"].find_parent(
                current_node,
                vim.tbl_keys(module.config.public.completion_level.queries)
            )

            if not parent then
                return
            end

            local query = module.config.public.completion_level.queries[parent:type()]

            if not query then
                return
            end

            local parent_range = module.required["core.integrations.treesitter"].get_node_range(parent)

            schedule(function()
                module.public.completion_levels.clear_completion_levels(
                    buf,
                    parent_range.row_start,
                    parent_range.row_start + 1
                )

                local todo_item_counts = module.public.completion_levels.get_todo_item_counts(parent)

                if todo_item_counts.total ~= 0 then
                    module.public._set_extmark(
                        buf,
                        module.public.completion_levels.convert_query_syntax_to_extmark_syntax(
                            query.text,
                            todo_item_counts
                        ),
                        query.highlight,
                        module.private.completion_level_namespace,
                        parent_range.row_start,
                        nil,
                        parent_range.column_start,
                        nil,
                        nil,
                        nil,
                        "eol"
                    )
                end
            end)
        end,

        --- Triggers the completion level check for a range of lines
        ---@param buf number #The number of the buffer to trigger completion levels in
        ---@param from? number #The start line
        ---@param to? number #The end line
        trigger_completion_levels = function(buf, from, to)
            module.public.completion_levels.clear_completion_levels(buf, from, to)

            local root = module.required["core.integrations.treesitter"].get_document_root(buf)

            if not root then
                return
            end

            for node_name, data in pairs(module.config.public.completion_level.queries) do
                local ok, query = pcall(
                    vim.treesitter.parse_query,
                    "norg",
                    string.format(
                        [[
                        (%s) @parent
                    ]],
                        node_name
                    )
                )

                if not ok then
                    log.error(
                        "Failed to parse completion level for node type '"
                            .. node_name
                            .. "' - ensure that you're providing a valid node name. Full error: "
                            .. query
                    )
                    return
                end

                for id, node in query:iter_captures(root, buf, from, to) do
                    local capture = query.captures[id]

                    if capture == "parent" then
                        local node_range = module.required["core.integrations.treesitter"].get_node_range(node)

                        schedule(function()
                            module.public.completion_levels.clear_completion_levels(
                                buf,
                                node_range.row_start,
                                node_range.row_start + 1
                            )

                            local todo_item_counts = module.public.completion_levels.get_todo_item_counts(node)

                            if todo_item_counts.total ~= 0 then
                                module.public._set_extmark(
                                    buf,
                                    module.public.completion_levels.convert_query_syntax_to_extmark_syntax(
                                        data.text,
                                        todo_item_counts
                                    ),
                                    data.highlight,
                                    module.private.completion_level_namespace,
                                    node_range.row_start,
                                    nil,
                                    node_range.column_start,
                                    nil,
                                    nil,
                                    nil,
                                    "eol"
                                )
                            end
                        end)
                    end
                end
            end
        end,

        --- Counts the number of todo items under a node
        ---@param start_node userdata #The treesitter node to start at
        ---@return table #A table of data regarding all todo item counts
        get_todo_item_counts = function(start_node)
            local results = { total = 0 }
            count_todo_nodes_under_node(start_node, results)
            return results
        end,

        --- Converts a formatted string to a raw string
        ---@param str string #The formatted string
        ---@param item_counts table #A table of data regarding all todo item counts
        ---@see get_todo_item_counts
        ---@return string #The string with all valid formatting replaced
        substitute_item_counts_in_str = function(str, item_counts)
            local types = {
                "undone",
                "pending",
                "done",
                "on_hold",
                "urgent",
                "cancelled",
                "recurring",
                "uncertain",
            }

            for _, type in ipairs(types) do
                str = str:gsub("<" .. type .. ">", item_counts[type] or 0)
            end

            str = str:gsub("<total>", item_counts.total)
            str = str:gsub("<percentage>", math.floor((item_counts.done or 0) / item_counts.total * 100))

            return str
        end,

        convert_query_syntax_to_extmark_syntax = function(tbl, item_counts)
            local result = vim.deepcopy(tbl)

            for i, item in ipairs(result) do
                if type(item) == "string" then
                    result[i] = { item }
                end

                result[i][1] = module.public.completion_levels.substitute_item_counts_in_str(result[i][1], item_counts)
            end

            return result
        end,

        --- Clears the completion level namespace
        ---@param buf number #The buffer to clear the extmarks in
        ---@param from? number #The start line
        ---@param to? number #The end line
        clear_completion_levels = function(buf, from, to)
            vim.api.nvim_buf_clear_namespace(buf, module.private.completion_level_namespace, from or 0, to or -1)
        end,
    },

    -- VARIABLES
    concealing = {
        ordered = {
            get_index = function(node, level)
                local sibling = node:parent():prev_named_sibling()
                local count = 1

                while sibling and sibling:type() == level do
                    sibling = sibling:prev_named_sibling()
                    count = count + 1
                end

                return count
            end,

            enumerator = {
                numeric = function(count)
                    return tostring(count)
                end,

                latin_lowercase = function(count)
                    return string.char(96 + count)
                end,

                latin_uppercase = function(count)
                    return string.char(64 + count)
                end,

                -- NOTE: only supports number up to 12
                roman_lowercase = function(count)
                    local chars = {
                        [1] = "ⅰ",
                        [2] = "ⅱ",
                        [3] = "ⅲ",
                        [4] = "ⅳ",
                        [5] = "ⅴ",
                        [6] = "ⅵ",
                        [7] = "ⅶ",
                        [8] = "ⅷ",
                        [9] = "ⅸ",
                        [10] = "ⅹ",
                        [11] = "ⅺ",
                        [12] = "ⅻ",
                        [50] = "ⅼ",
                        [100] = "ⅽ",
                        [500] = "ⅾ",
                        [1000] = "ⅿ",
                    }
                    return chars[count]
                end,

                -- NOTE: only supports number up to 12
                roman_uppwercase = function(count)
                    local chars = {
                        [1] = "Ⅰ",
                        [2] = "Ⅱ",
                        [3] = "Ⅲ",
                        [4] = "Ⅳ",
                        [5] = "Ⅴ",
                        [6] = "Ⅵ",
                        [7] = "Ⅶ",
                        [8] = "Ⅷ",
                        [9] = "Ⅸ",
                        [10] = "Ⅹ",
                        [11] = "Ⅺ",
                        [12] = "Ⅻ",
                        [50] = "Ⅼ",
                        [100] = "Ⅽ",
                        [500] = "Ⅾ",
                        [1000] = "Ⅿ",
                    }
                    return chars[count]
                end,
            },

            punctuation = {
                dot = function(renderer)
                    return function(count)
                        return renderer(count) .. "."
                    end
                end,

                parenthesis = function(renderer)
                    return function(count)
                        return renderer(count) .. ")"
                    end
                end,

                double_parenthesis = function(renderer)
                    return function(count)
                        return "(" .. renderer(count) .. ")"
                    end
                end,

                -- NOTE: only supports arabic numbers up to 20
                unicode_dot = function(renderer)
                    return function(count)
                        local chars = {
                            ["1"] = "⒈",
                            ["2"] = "⒉",
                            ["3"] = "⒊",
                            ["4"] = "⒋",
                            ["5"] = "⒌",
                            ["6"] = "⒍",
                            ["7"] = "⒎",
                            ["8"] = "⒏",
                            ["9"] = "⒐",
                            ["10"] = "⒑",
                            ["11"] = "⒒",
                            ["12"] = "⒓",
                            ["13"] = "⒔",
                            ["14"] = "⒕",
                            ["15"] = "⒖",
                            ["16"] = "⒗",
                            ["17"] = "⒘",
                            ["18"] = "⒙",
                            ["19"] = "⒚",
                            ["20"] = "⒛",
                        }
                        return chars[renderer(count)]
                    end
                end,

                -- NOTE: only supports arabic numbers up to 20 or lowercase latin characters
                unicode_double_parenthesis = function(renderer)
                    return function(count)
                        local chars = {
                            ["1"] = "⑴",
                            ["2"] = "⑵",
                            ["3"] = "⑶",
                            ["4"] = "⑷",
                            ["5"] = "⑸",
                            ["6"] = "⑹",
                            ["7"] = "⑺",
                            ["8"] = "⑻",
                            ["9"] = "⑼",
                            ["10"] = "⑽",
                            ["11"] = "⑾",
                            ["12"] = "⑿",
                            ["13"] = "⒀",
                            ["14"] = "⒁",
                            ["15"] = "⒂",
                            ["16"] = "⒃",
                            ["17"] = "⒄",
                            ["18"] = "⒅",
                            ["19"] = "⒆",
                            ["20"] = "⒇",
                            ["a"] = "⒜",
                            ["b"] = "⒝",
                            ["c"] = "⒞",
                            ["d"] = "⒟",
                            ["e"] = "⒠",
                            ["f"] = "⒡",
                            ["g"] = "⒢",
                            ["h"] = "⒣",
                            ["i"] = "⒤",
                            ["j"] = "⒥",
                            ["k"] = "⒦",
                            ["l"] = "⒧",
                            ["m"] = "⒨",
                            ["n"] = "⒩",
                            ["o"] = "⒪",
                            ["p"] = "⒫",
                            ["q"] = "⒬",
                            ["r"] = "⒭",
                            ["s"] = "⒮",
                            ["t"] = "⒯",
                            ["u"] = "⒰",
                            ["v"] = "⒱",
                            ["w"] = "⒲",
                            ["x"] = "⒳",
                            ["y"] = "⒴",
                            ["z"] = "⒵",
                        }
                        return chars[renderer(count)]
                    end
                end,

                -- NOTE: only supports arabic numbers up to 20 or latin characters
                unicode_circle = function(renderer)
                    return function(count)
                        local chars = {
                            ["1"] = "①",
                            ["2"] = "②",
                            ["3"] = "③",
                            ["4"] = "④",
                            ["5"] = "⑤",
                            ["6"] = "⑥",
                            ["7"] = "⑦",
                            ["8"] = "⑧",
                            ["9"] = "⑨",
                            ["10"] = "⑩",
                            ["11"] = "⑪",
                            ["12"] = "⑫",
                            ["13"] = "⑬",
                            ["14"] = "⑭",
                            ["15"] = "⑮",
                            ["16"] = "⑯",
                            ["17"] = "⑰",
                            ["18"] = "⑱",
                            ["19"] = "⑲",
                            ["20"] = "⑳",
                            ["A"] = "Ⓐ",
                            ["B"] = "Ⓑ",
                            ["C"] = "Ⓒ",
                            ["D"] = "Ⓓ",
                            ["E"] = "Ⓔ",
                            ["F"] = "Ⓕ",
                            ["G"] = "Ⓖ",
                            ["H"] = "Ⓗ",
                            ["I"] = "Ⓘ",
                            ["J"] = "Ⓙ",
                            ["K"] = "Ⓚ",
                            ["L"] = "Ⓛ",
                            ["M"] = "Ⓜ",
                            ["N"] = "Ⓝ",
                            ["O"] = "Ⓞ",
                            ["P"] = "Ⓟ",
                            ["Q"] = "Ⓠ",
                            ["R"] = "Ⓡ",
                            ["S"] = "Ⓢ",
                            ["T"] = "Ⓣ",
                            ["U"] = "Ⓤ",
                            ["V"] = "Ⓥ",
                            ["W"] = "Ⓦ",
                            ["X"] = "Ⓧ",
                            ["Y"] = "Ⓨ",
                            ["Z"] = "Ⓩ",
                            ["a"] = "ⓐ",
                            ["b"] = "ⓑ",
                            ["c"] = "ⓒ",
                            ["d"] = "ⓓ",
                            ["e"] = "ⓔ",
                            ["f"] = "ⓕ",
                            ["g"] = "ⓖ",
                            ["h"] = "ⓗ",
                            ["i"] = "ⓘ",
                            ["j"] = "ⓙ",
                            ["k"] = "ⓚ",
                            ["l"] = "ⓛ",
                            ["m"] = "ⓜ",
                            ["n"] = "ⓝ",
                            ["o"] = "ⓞ",
                            ["p"] = "ⓟ",
                            ["q"] = "ⓠ",
                            ["r"] = "ⓡ",
                            ["s"] = "ⓢ",
                            ["t"] = "ⓣ",
                            ["u"] = "ⓤ",
                            ["v"] = "ⓥ",
                            ["w"] = "ⓦ",
                            ["x"] = "ⓧ",
                            ["y"] = "ⓨ",
                            ["z"] = "ⓩ",
                        }
                        return chars[renderer(count)]
                    end
                end,
            },
        },
    },

    --- Custom foldtext to be used with the native folding support
    ---@return string #The foldtext
    foldtext = function()
        local foldstart = vim.v.foldstart
        local line = vim.api.nvim_buf_get_lines(0, foldstart - 1, foldstart, true)[1]

        return neorg.lib.match(line, function(lhs, rhs)
            return vim.startswith(lhs, rhs)
        end)({
            ["@document.meta"] = "Document Metadata",
            _ = function()
                local line_length = vim.api.nvim_strwidth(line)

                local icon_extmarks = vim.api.nvim_buf_get_extmarks(
                    0,
                    module.private.icon_namespace,
                    { foldstart - 1, 0 },
                    { foldstart - 1, line_length },
                    {
                        details = true,
                    }
                )

                for _, extmark in ipairs(icon_extmarks) do
                    local extmark_details = extmark[4]
                    local extmark_column = extmark[3] + (line_length - vim.api.nvim_strwidth(line))

                    for _, virt_text in ipairs(extmark_details.virt_text or {}) do
                        line = line:sub(1, extmark_column)
                            .. virt_text[1]
                            .. line:sub(extmark_column + vim.api.nvim_strwidth(virt_text[1]) + 1)
                        line_length = vim.api.nvim_strwidth(line) - line_length + vim.api.nvim_strwidth(virt_text[1])
                    end
                end

                local completion_extmarks = vim.api.nvim_buf_get_extmarks(
                    0,
                    module.private.completion_level_namespace,
                    { foldstart - 1, 0 },
                    { foldstart - 1, vim.api.nvim_strwidth(line) },
                    {
                        details = true,
                    }
                )

                if not vim.tbl_isempty(completion_extmarks) then
                    line = line .. " "

                    for _, extmark in ipairs(completion_extmarks) do
                        for _, virt_text in ipairs(extmark[4].virt_text or {}) do
                            line = line .. virt_text[1]
                        end
                    end
                end

                return line
            end,
        })
    end,

    toggle_concealer = function()
        module.private.enabled = not module.private.enabled

        if module.private.enabled then
            neorg.events.send_event(
                "core.norg.concealer",
                neorg.events.create(module, "core.autocommands.events.bufenter", {
                    norg = true,
                })
            )
        else
            for _, namespace in ipairs({
                "icon_namespace",
                "code_block_namespace",
                "completion_level_namespace",
            }) do
                vim.api.nvim_buf_clear_namespace(0, module.private[namespace], 0, -1)
            end
        end
    end,
}

module.config.public = {
    -- Which icon preset to use
    -- Go to [imports](#imports) to see which ones are currently defined
    -- E.g `core.norg.concealer.preset_diamond` will be `preset = "diamond"`
    icon_preset = "basic",

    -- Configuration for icons: their looks and behaviours are contained here
    icons = {
        todo = {
            enabled = true,

            done = {
                enabled = true,
                icon = "",
                query = "(todo_item_done) @icon",
            },

            pending = {
                enabled = true,
                icon = "",
                query = "(todo_item_pending) @icon",
            },

            undone = {
                enabled = true,
                icon = "×",
                query = "(todo_item_undone) @icon",
            },

            uncertain = {
                enabled = true,
                icon = "",
                query = "(todo_item_uncertain) @icon",
            },

            on_hold = {
                enabled = true,
                icon = "",
                query = "(todo_item_on_hold) @icon",
            },

            cancelled = {
                enabled = true,
                icon = "",
                query = "(todo_item_cancelled) @icon",
            },

            recurring = {
                enabled = true,
                icon = "↺",
                query = "(todo_item_recurring) @icon",
            },

            urgent = {
                enabled = true,
                icon = "⚠",
                query = "(todo_item_urgent) @icon",
            },
        },

        list = {
            enabled = true,

            level_1 = {
                enabled = true,
                icon = "•",
                query = "(unordered_list1_prefix) @icon",
            },

            level_2 = {
                enabled = true,
                icon = " •",
                query = "(unordered_list2_prefix) @icon",
            },

            level_3 = {
                enabled = true,
                icon = "  •",
                query = "(unordered_list3_prefix) @icon",
            },

            level_4 = {
                enabled = true,
                icon = "   •",
                query = "(unordered_list4_prefix) @icon",
            },

            level_5 = {
                enabled = true,
                icon = "    •",
                query = "(unordered_list5_prefix) @icon",
            },

            level_6 = {
                enabled = true,
                icon = "     •",
                query = "(unordered_list6_prefix) @icon",
            },
        },

        ordered = {
            enabled = require("neorg.external.helpers").is_minimum_version(0, 6, 0),

            level_1 = {
                enabled = true,
                icon = module.public.concealing.ordered.punctuation.unicode_dot(
                    module.public.concealing.ordered.enumerator.numeric
                ),
                query = "(ordered_list1_prefix) @icon",
                render = function(self, _, node)
                    local count = module.public.concealing.ordered.get_index(node, "ordered_list1")
                    return {
                        { self.icon(count), self.highlight },
                    }
                end,
            },

            level_2 = {
                enabled = true,
                icon = module.public.concealing.ordered.enumerator.latin_uppercase,
                query = "(ordered_list2_prefix) @icon",
                render = function(self, _, node)
                    local count = module.public.concealing.ordered.get_index(node, "ordered_list2")
                    return {
                        { " " .. self.icon(count), self.highlight },
                    }
                end,
            },

            level_3 = {
                enabled = true,
                icon = module.public.concealing.ordered.enumerator.latin_lowercase,
                query = "(ordered_list3_prefix) @icon",
                render = function(self, _, node)
                    local count = module.public.concealing.ordered.get_index(node, "ordered_list3")
                    return {
                        { "  " .. self.icon(count), self.highlight },
                    }
                end,
            },

            level_4 = {
                enabled = true,
                icon = module.public.concealing.ordered.punctuation.unicode_double_parenthesis(
                    module.public.concealing.ordered.enumerator.numeric
                ),
                query = "(ordered_list4_prefix) @icon",
                render = function(self, _, node)
                    local count = module.public.concealing.ordered.get_index(node, "ordered_list4")
                    return {
                        { "   " .. self.icon(count), self.highlight },
                    }
                end,
            },

            level_5 = {
                enabled = true,
                icon = module.public.concealing.ordered.enumerator.latin_uppercase,
                query = "(ordered_list5_prefix) @icon",
                render = function(self, _, node)
                    local count = module.public.concealing.ordered.get_index(node, "ordered_list5")
                    return {
                        { "    " .. self.icon(count), self.highlight },
                    }
                end,
            },

            level_6 = {
                enabled = true,
                icon = module.public.concealing.ordered.punctuation.unicode_double_parenthesis(
                    module.public.concealing.ordered.enumerator.latin_lowercase
                ),
                query = "(ordered_list6_prefix) @icon",
                render = function(self, _, node)
                    local count = module.public.concealing.ordered.get_index(node, "ordered_list6")
                    return {
                        { "     " .. self.icon(count), self.highlight },
                    }
                end,
            },
        },

        quote = {
            enabled = true,

            level_1 = {
                enabled = true,
                icon = "│",
                highlight = "@neorg.quotes.1.prefix",
                query = "(quote1_prefix) @icon",
            },

            level_2 = {
                enabled = true,
                icon = "│",
                highlight = "@neorg.quotes.2.prefix",
                query = "(quote2_prefix) @icon",
                render = function(self)
                    return {
                        { self.icon, module.config.public.icons.quote.level_1.highlight },
                        { self.icon, self.highlight },
                    }
                end,
            },

            level_3 = {
                enabled = true,
                icon = "│",
                highlight = "@neorg.quotes.3.prefix",
                query = "(quote3_prefix) @icon",
                render = function(self)
                    return {
                        { self.icon, module.config.public.icons.quote.level_1.highlight },
                        { self.icon, module.config.public.icons.quote.level_2.highlight },
                        { self.icon, self.highlight },
                    }
                end,
            },

            level_4 = {
                enabled = true,
                icon = "│",
                highlight = "@neorg.quotes.4.prefix",
                query = "(quote4_prefix) @icon",
                render = function(self)
                    return {
                        { self.icon, module.config.public.icons.quote.level_1.highlight },
                        { self.icon, module.config.public.icons.quote.level_2.highlight },
                        { self.icon, module.config.public.icons.quote.level_3.highlight },
                        { self.icon, self.highlight },
                    }
                end,
            },

            level_5 = {
                enabled = true,
                icon = "│",
                highlight = "@neorg.quotes.5.prefix",
                query = "(quote5_prefix) @icon",
                render = function(self)
                    return {
                        { self.icon, module.config.public.icons.quote.level_1.highlight },
                        { self.icon, module.config.public.icons.quote.level_2.highlight },
                        { self.icon, module.config.public.icons.quote.level_3.highlight },
                        { self.icon, module.config.public.icons.quote.level_4.highlight },
                        { self.icon, self.highlight },
                    }
                end,
            },

            level_6 = {
                enabled = true,
                icon = "│",
                highlight = "@neorg.quotes.6.prefix",
                query = "(quote6_prefix) @icon",
                render = function(self)
                    return {
                        { self.icon, module.config.public.icons.quote.level_1.highlight },
                        { self.icon, module.config.public.icons.quote.level_2.highlight },
                        { self.icon, module.config.public.icons.quote.level_3.highlight },
                        { self.icon, module.config.public.icons.quote.level_4.highlight },
                        { self.icon, module.config.public.icons.quote.level_5.highlight },
                        { self.icon, self.highlight },
                    }
                end,
            },
        },

        heading = {
            enabled = true,

            level_1 = {
                enabled = true,
                icon = "◉",
                highlight = "@neorg.headings.1.prefix",
                query = "[ (heading1_prefix) (link_target_heading1) @no-conceal ] @icon",
            },

            level_2 = {
                enabled = true,
                icon = " ◎",
                highlight = "@neorg.headings.2.prefix",
                query = "[ (heading2_prefix) (link_target_heading2) @no-conceal ] @icon",
            },

            level_3 = {
                enabled = true,
                icon = "  ○",
                highlight = "@neorg.headings.3.prefix",
                query = "[ (heading3_prefix) (link_target_heading3) @no-conceal ] @icon",
            },

            level_4 = {
                enabled = true,
                icon = "   ✺",
                highlight = "@neorg.headings.4.prefix",
                query = "[ (heading4_prefix) (link_target_heading4) @no-conceal ] @icon",
            },

            level_5 = {
                enabled = true,
                icon = "    ▶",
                highlight = "@neorg.headings.5.prefix",
                query = "[ (heading5_prefix) (link_target_heading5) @no-conceal ] @icon",
            },

            level_6 = {
                enabled = true,
                icon = "     ⤷",
                highlight = "@neorg.headings.6.prefix",
                query = "[ (heading6_prefix) (link_target_heading6) @no-conceal ] @icon",
                render = function(self, text)
                    return {
                        {
                            string.rep(" ", text:len() - string.len("******") - string.len(" ")) .. self.icon,
                            self.highlight,
                        },
                    }
                end,
            },
        },

        definition = {
            enabled = true,

            single = {
                enabled = true,
                icon = "≡",
                query = "[ (single_definition_prefix) (link_target_definition) @no-conceal ] @icon",
            },
            multi_prefix = {
                enabled = true,
                icon = "⋙ ",
                query = "(multi_definition_prefix) @icon",
            },
            multi_suffix = {
                enabled = true,
                icon = "⋘ ",
                query = "(multi_definition_suffix) @icon",
            },
        },

        footnote = {
            enabled = true,

            single = {
                enabled = true,
                icon = "⁎",
                query = "[ (single_footnote_prefix) (link_target_footnote) @no-conceal ] @icon",
            },
            multi_prefix = {
                enabled = true,
                icon = "⁑ ",
                query = "(multi_footnote_prefix) @icon",
            },
            multi_suffix = {
                enabled = true,
                icon = "⁑ ",
                query = "(multi_footnote_suffix) @icon",
            },
        },

        delimiter = {
            enabled = true,

            weak = {
                enabled = true,
                icon = "⟨",
                highlight = "@neorg.delimiters.weak",
                query = "(weak_paragraph_delimiter) @icon",
                render = function(self, text)
                    return {
                        { string.rep(self.icon, text:len() - 1), self.highlight },
                    }
                end,
            },

            strong = {
                enabled = true,
                icon = "⟪",
                highlight = "@neorg.delimiters.strong",
                query = "(strong_paragraph_delimiter) @icon",
                render = function(self, text)
                    return {
                        { string.rep(self.icon, text:len() - 1), self.highlight },
                    }
                end,
            },

            horizontal_line = {
                enabled = true,
                icon = "─",
                highlight = "@neorg.delimiters.horizontal_line",
                query = "(horizontal_line) @icon",
                render = function(self, _, node)
                    return {
                        {
                            string.rep(self.icon, vim.api.nvim_win_get_width(0) - ({ node:range() })[2]),
                            self.highlight,
                        },
                    }
                end,
            },
        },

        markup = {
            enabled = true,

            spoiler = {
                enabled = true,
                icon = "•",
                highlight = "@neorg.markup.spoiler",
                query = '(spoiler ("_open") _ @icon ("_close"))',
                render = function(self, text)
                    return { { string.rep(self.icon, text:len()), self.highlight } }
                end,
            },
        },
    },

    -- If you want to dim code blocks
    dim_code_blocks = {
        enabled = true,

        -- If true will only dim the content of the code block,
        -- not the code block itself.
        content_only = true,

        -- Will adapt based on the `conceallevel` option.
        -- If `conceallevel` > 0, then only the content will be dimmed,
        -- else the whole code block will be dimmed.
        adaptive = true,

        -- The width to use for code block backgrounds.
        --
        -- When set to `fullwidth` (the default), will create a background
        -- that spans the width of the buffer.
        --
        -- When set to `content`, will only span as far as the longest line
        -- within the code block.
        width = "fullwidth",

        -- Additional padding to apply to either the left or the right.
        -- Making these values negative is undefined behaviour (it may work, but
        -- it's not officially supported).
        padding = {
            left = 0,
            right = 0,
        },

        -- If `true` will conceal the `@code` and `@end` portion of the code
        -- block.
        conceal = true,
    },

    folds = true,

    completion_level = {
        enabled = true,

        queries = vim.tbl_deep_extend(
            "keep",
            {},
            (function()
                local result = {}

                for i = 1, 6 do
                    result["heading" .. i] = {
                        text = {
                            "(",
                            { "<done>", "@field" },
                            " of ",
                            { "<total>", "@neorg.todo_items.done.1" },
                            ") [<percentage>% complete]",
                        },

                        highlight = "DiagnosticVirtualTextHint",
                    }
                end

                return result
            end)()
            --[[ (function()
                local result = {}

                for i = 1, 6 do
                    result["todo_item" .. i] = {
                        text = "[<done>/<total>]",
                        highlight = "DiagnosticVirtualTextHint",
                    }
                end

                return result
            end)() ]]
        ),
    },

    performance = {
        increment = 1250,
        timeout = 0,
        interval = 500,
        max_debounce = 5,
    },
}

module.load = function()
    if not module.config.private["icon_preset_" .. module.config.public.icon_preset] then
        log.error(
            string.format(
                "Unable to load icon preset '%s' - such a preset does not exist",
                module.config.public.icon_preset
            )
        )
        return
    end

    module.config.public.icons = vim.tbl_deep_extend(
        "force",
        module.config.public.icons,
        module.config.private["icon_preset_" .. module.config.public.icon_preset] or {},
        module.config.custom
    )

    --- Queries all icons that have their `enable = true` flags set
    ---@param tbl table #The table to parse
    ---@param parent_icon string #Is used to pass icons from parents down to their table children to handle inheritance.
    ---@param rec_name string #Should not be set manually. Is used for Neorg to have information about all other previous recursions
    local function get_enabled_icons(tbl, parent_icon, rec_name)
        rec_name = rec_name or ""

        -- Create a result that we will return at the end of the function
        local result = {}

        -- If the current table isn't enabled then don't parser any further - simply return the empty result
        if vim.tbl_isempty(tbl) or (tbl.enabled ~= nil and tbl.enabled == false) then
            return result
        end

        -- Go through every icon
        for name, icons in pairs(tbl) do
            -- If we're dealing with a table (which we should be) and if the current icon set is enabled then
            if type(icons) == "table" and icons.enabled then
                -- If we have defined a query value then add that icon to the result
                if icons.query then
                    result[rec_name .. name] = icons

                    if icons.icon == nil then
                        result[rec_name .. name].icon = parent_icon
                    end
                else
                    -- If we don't have an icon variable then we need to descend further down the lua table.
                    -- To do this we recursively call this very function and merge the results into the result table
                    result =
                        vim.tbl_deep_extend("force", result, get_enabled_icons(icons, parent_icon, rec_name .. name))
                end
            end
        end

        return result
    end

    -- Set the module.private.icons variable to the values of the enabled icons
    module.private.icons = vim.tbl_values(get_enabled_icons(module.config.public.icons))

    -- Enable the required autocommands (these will be used to determine when to update conceals in the buffer)
    module.required["core.autocommands"].enable_autocommand("BufEnter")
    module.required["core.autocommands"].enable_autocommand("InsertEnter")
    module.required["core.autocommands"].enable_autocommand("InsertLeave")
    module.required["core.autocommands"].enable_autocommand("VimLeavePre")

    neorg.modules.await("core.neorgcmd", function(neorgcmd)
        neorgcmd.add_commands_from_table({
            ["toggle-concealer"] = {
                name = "core.norg.concealer.toggle",
                args = 0,
                condition = "norg",
            },
        })
    end)

    if neorg.utils.is_minimum_version(0, 7, 0) then
        vim.api.nvim_create_autocmd("OptionSet", {
            pattern = "conceallevel",
            callback = function()
                local current_buffer = vim.api.nvim_get_current_buf()
                if vim.bo[current_buffer].ft ~= "norg" then
                    return
                end
                local has_conceal = (tonumber(vim.v.option_new) > 0)

                module.public.trigger_icons(
                    current_buffer,
                    has_conceal,
                    module.private.icons,
                    module.private.icon_namespace
                )

                if module.config.public.dim_code_blocks.conceal and module.config.public.dim_code_blocks.adaptive then
                    module.public.trigger_code_block_highlights(current_buffer, has_conceal)
                end
            end,
        })
    end
end

module.on_event = function(event)
    if event.type == "core.neorgcmd.events.core.norg.concealer.toggle" then
        module.public.toggle_concealer()
    end

    if not module.private.enabled then
        return
    end

    module.private.debounce_counters[event.cursor_position[1] + 1] = module.private.debounce_counters[event.cursor_position[1] + 1]
        or 0

    local function should_debounce()
        return module.private.debounce_counters[event.cursor_position[1] + 1]
            >= module.config.public.performance.max_debounce
    end

    local has_conceal = (
        vim.api.nvim_win_is_valid(event.window) and (vim.api.nvim_win_get_option(event.window, "conceallevel") > 0)
        or false
    )

    if event.type == "core.autocommands.events.bufenter" and event.content.norg then
        if module.config.public.folds and vim.api.nvim_win_is_valid(event.window) then
            vim.api.nvim_win_set_option(event.window, "foldmethod", "expr")
            vim.api.nvim_win_set_option(event.window, "foldexpr", "nvim_treesitter#foldexpr()")
            vim.api.nvim_win_set_option(
                event.window,
                "foldtext",
                "v:lua.neorg.modules.get_module('core.norg.concealer').foldtext()"
            )
        end

        local buf = event.buffer
        local line_count = vim.api.nvim_buf_line_count(buf)

        vim.api.nvim_buf_clear_namespace(buf, module.private.icon_namespace, 0, -1)
        vim.api.nvim_buf_clear_namespace(buf, module.private.code_block_namespace, 0, -1)
        vim.api.nvim_buf_clear_namespace(buf, module.private.completion_level_namespace, 0, -1)

        if line_count < module.config.public.performance.increment then
            module.public.trigger_icons(buf, has_conceal, module.private.icons, module.private.icon_namespace)
            module.public.trigger_code_block_highlights(buf, has_conceal)
            module.public.completion_levels.trigger_completion_levels(buf)
        else
            -- This bit of code gets triggered if the line count of the file is bigger than one increment level
            -- provided by the user.
            -- In this case, the concealer enters a block mode and splits up the file into chunks. It then goes through each
            -- chunk at a set interval and applies the conceals that way to reduce load and improve performance.

            -- This points to the current block the user's cursor is in
            local block_current =
                math.floor((line_count / module.config.public.performance.increment) % event.cursor_position[1])

            local function trigger_conceals_for_block(block)
                local line_begin = block == 0 and 0 or block * module.config.public.performance.increment - 1
                local line_end = math.min(
                    block * module.config.public.performance.increment + module.config.public.performance.increment - 1,
                    line_count
                )

                module.public.trigger_icons(
                    buf,
                    has_conceal,
                    module.private.icons,
                    module.private.icon_namespace,
                    line_begin,
                    line_end
                )

                module.public.trigger_code_block_highlights(buf, has_conceal, line_begin, line_end)
                module.public.completion_levels.trigger_completion_levels(buf, line_begin, line_end)
            end

            trigger_conceals_for_block(block_current)

            local block_bottom, block_top = block_current - 1, block_current + 1

            local timer = vim.loop.new_timer()

            timer:start(
                module.config.public.performance.timeout,
                module.config.public.performance.interval,
                vim.schedule_wrap(function()
                    local block_bottom_valid = block_bottom == 0
                        or (block_bottom * module.config.public.performance.increment - 1 >= 0)
                    local block_top_valid = block_top * module.config.public.performance.increment - 1 < line_count

                    if not block_bottom_valid and not block_top_valid then
                        timer:stop()
                        return
                    end

                    if block_bottom_valid then
                        trigger_conceals_for_block(block_bottom)
                        block_bottom = block_bottom - 1
                    end

                    if block_top_valid then
                        trigger_conceals_for_block(block_top)
                        block_top = block_top + 1
                    end
                end)
            )
        end

        module.private.attach_uid = module.private.attach_uid + 1
        local uid_upvalue = module.private.attach_uid

        vim.api.nvim_buf_attach(buf, false, {
            on_lines = function(_, cur_buf, _, start, _end)
                -- There are edge cases where the current buffer is not the same as the tracked buffer,
                -- which causes desyncs
                if buf ~= cur_buf or not module.private.enabled or uid_upvalue ~= module.private.attach_uid then
                    return true
                end

                if should_debounce() then
                    return
                end

                module.private.last_change.active = true

                local mode = vim.api.nvim_get_mode().mode

                has_conceal = (
                    vim.api.nvim_win_is_valid(event.window)
                        and (vim.api.nvim_win_get_option(event.window, "conceallevel") > 0)
                    or false
                )

                if mode ~= "i" then
                    module.private.debounce_counters[event.cursor_position[1] + 1] = module.private.debounce_counters[event.cursor_position[1] + 1]
                        + 1

                    schedule(function()
                        local new_line_count = vim.api.nvim_buf_line_count(buf)

                        -- Sometimes occurs with one-line undos
                        if start == _end then
                            _end = _end + 1
                        end

                        if new_line_count > line_count then
                            _end = _end + (new_line_count - line_count - 1)
                        end

                        line_count = new_line_count

                        module.public.trigger_icons(
                            buf,
                            has_conceal,
                            module.private.icons,
                            module.private.icon_namespace,
                            start,
                            _end
                        )

                        -- NOTE(vhyrro): It is simply not possible to perform incremental
                        -- updates here. Code blocks require more context than simply a few lines.
                        -- It's still incredibly fast despite this fact though.
                        module.public.trigger_code_block_highlights(buf, has_conceal)

                        module.public.completion_levels.trigger_completion_levels(buf, start, _end)

                        vim.schedule(function()
                            module.private.debounce_counters[event.cursor_position[1] + 1] = module.private.debounce_counters[event.cursor_position[1] + 1]
                                - 1
                        end)
                    end)
                else
                    schedule(neorg.lib.wrap(module.public.trigger_code_block_highlights, buf, has_conceal, start, _end))

                    if module.private.largest_change_start == -1 then
                        module.private.largest_change_start = start
                    end

                    if module.private.largest_change_end == -1 then
                        module.private.largest_change_end = _end
                    end

                    module.private.largest_change_start = start < module.private.largest_change_start and start
                        or module.private.largest_change_start
                    module.private.largest_change_end = _end > module.private.largest_change_end and _end
                        or module.private.largest_change_end
                end
            end,
        })
    elseif event.type == "core.autocommands.events.insertenter" then
        schedule(function()
            module.private.last_change = {
                active = false,
                line = event.cursor_position[1] - 1,
            }

            vim.api.nvim_buf_clear_namespace(
                event.buffer,
                module.private.icon_namespace,
                event.cursor_position[1] - 1,
                event.cursor_position[1]
            )

            vim.api.nvim_buf_clear_namespace(
                event.buffer,
                module.private.completion_level_namespace,
                event.cursor_position[1] - 1,
                event.cursor_position[1]
            )
        end)
    elseif event.type == "core.autocommands.events.insertleave" then
        if should_debounce() then
            return
        end

        schedule(function()
            if not module.private.last_change.active or module.private.largest_change_end == -1 then
                module.public.trigger_icons(
                    event.buffer,
                    has_conceal,
                    module.private.icons,
                    module.private.icon_namespace,
                    module.private.last_change.line,
                    module.private.last_change.line + 1
                )

                module.public.completion_levels.trigger_completion_levels_incremental(
                    event.buffer,
                    event.cursor_position[1] - 1
                )
            else
                module.public.trigger_icons(
                    event.buffer,
                    has_conceal,
                    module.private.icons,
                    module.private.icon_namespace,
                    module.private.largest_change_start,
                    module.private.largest_change_end
                )

                module.public.completion_levels.trigger_completion_levels_incremental(
                    event.buffer,
                    event.cursor_position[1] - 1
                )
            end

            module.private.largest_change_start, module.private.largest_change_end = -1, -1
        end)
    elseif event.type == "core.autocommands.events.vimleavepre" then
        module.private.disable_deferred_updates = true
    elseif event.type == "core.norg.concealer.events.update_region" then
        schedule(function()
            vim.api.nvim_buf_clear_namespace(
                event.buffer,
                module.private.icon_namespace,
                event.content.start,
                event.content["end"]
            )
            vim.api.nvim_buf_clear_namespace(
                event.buffer,
                module.private.completion_level_namespace,
                event.content.start,
                event.content["end"]
            )

            module.public.trigger_icons(
                event.buffer,
                module.private.has_conceal,
                module.private.icons,
                module.private.icon_namespace,
                event.content.start,
                event.content["end"]
            )

            module.public.completion_levels.trigger_completion_levels(
                event.buffer,
                event.content.start,
                event.content["end"]
            )
        end)
    end
end

module.events.defined = {
    update_region = neorg.events.define(module, "update_region"),
}

module.events.subscribed = {
    ["core.autocommands"] = {
        bufenter = true,
        insertenter = true,
        insertleave = true,
        vimleavepre = true,
    },

    ["core.neorgcmd"] = {
        ["core.norg.concealer.toggle"] = true,
    },

    ["core.norg.concealer"] = {
        update_region = true,
    },
}

return module
