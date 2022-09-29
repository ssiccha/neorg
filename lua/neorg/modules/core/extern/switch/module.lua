local module = neorg.modules.create("core.extern.switch")

module.setup = function()
    return {
        requires = {
            "core.norg.dirman",
        },
    }
end

module.load = function()
    neorg.modules.await("core.neorgcmd", function(neorgcmd)
        neorgcmd.add_commands_from_table({
            switch = {
                max_args = 1,
                name = "extern.switch",
                complete = {
                    function()
                        return module.required["core.norg.dirman"].get_workspace_names()
                    end,
                },
            },
        })
    end)

    local current_workspace = module.required["core.norg.dirman"].get_current_workspace()

    vim.api.nvim_create_autocmd("BufEnter", {
        pattern = "*.norg",
        callback = function()
            local current_buf = vim.api.nvim_get_current_buf()

            module.private.buffers[current_workspace[1]] = module.private.buffers[current_workspace[1]] or {}
            module.private.buffers[current_workspace[1]][current_buf] = true
        end,
    })
end

module.private = {
    buffers = {
        -- Default workspace
        default = {},
    },
}

module.on_event = function(event)
    if event.type ~= "core.neorgcmd.events.extern.switch" then
        return
    end

    if not event.content[1] then
        local current_workspace = module.required["core.norg.dirman"].get_current_workspace()[1]
    end
end

module.events.subscribed = {
    ["core.neorgcmd"] = {
        ["extern.switch"] = true,
    },
}

return module
