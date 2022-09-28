local module = neorg.modules.create("core.extern.switch")

module.load = function()
    neorg.modules.await("core.neorgcmd", function(neorgcmd)
        neorgcmd.add_commands_from_table({
            switch = {
                max_args = 1,
                name = "extern.switch",
                condition = { --[[TODO]]
                },
            },
        })
    end)
end

module.on_event = function(event)
    if event.type ~= "core.neorgcmd.events.extern.switch" then
        return
    end

    -- Code here
end

module.events.subscribed = {
    ["core.neorgcmd"] = {
        ["extern.switch"] = true,
    },
}

return module
