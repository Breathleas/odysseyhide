--
-- Created by IntelliJ IDEA.
-- User: huanghaojing
-- Date: 16/8/5
-- Time: 下午12:54
-- To change this template use File | Settings | File Templates.
-- nLog的实现

local sz = require('sz')
local json = sz.json

return function(...)

    local log = ""
    --    local date=os.date("%Y-%m-%d %H:%M:%S");
    --    local log_header = "["..date..']'
    --    log = log..log_header

    local arg = {... }
    for i = 1,#arg do
        local at = type(arg[i])
        if at == "table" then
            log = log..json.encode(arg[i])
        elseif at == "function" then
            log = log.."function"
        elseif at == "userdata" then
            log = log.."userdata"
        elseif at == "boolean" then
            log = log..(arg[i] and "true" or "false")
        elseif at == "nil" then
            log = log..('nil')
        elseif at == "string" or at == "number" then
            log = log..arg[i]
        else
            log = log..(at)
        end
        log = log..("\t")
    end

    --    log = log..("\n")
    --    log = log..(debug.traceback())
    --    log = log..("\n")

    nLog(log)
    --    sysLog(log)
end