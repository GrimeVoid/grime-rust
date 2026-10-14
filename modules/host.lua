local helper = require("helper")
local ctx = helper.ctx

function main()
    local target_dir = ctx.pipeline_input or ctx.target_dir
    ctx.module_return(target_dir)
end
