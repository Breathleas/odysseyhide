--
-- Created by IntelliJ IDEA.
-- User: huanghaojing
-- Date: 16/11/7
-- Time: 上午10:56
-- To change this template use File | Settings | File Templates.
--

local platform_ios = true
if getOSType and getOSType()=="android" then
    platform_ios = false
end

local json = platform_ios and require('sz').json or require('cjson')
local socket = platform_ios and require('szocket') or { gettime = function() return getCurrentTime() end }

local thread = require('thread')

local timer = {}

local timeout_list = {}
local timeout_index = 0


function timer.add_timeout(ms,callback)

    if type(ms) ~= "number" then
        return false,"ms is not number!"
    end

    if type(callback) ~= "function" then
        return false,"callback is not funciton!"
    end

    timeout_index=timeout_index+1
    local id = timeout_index

    local begin = socket.gettime()

    timeout_list[tostring(id)] = {
        time = begin+ms/1000,
        callback = callback,
    }

    return id
end

--清除计时器
function timer.clear_timeout(id)

    if timeout_list[tostring(id)] then
        timeout_list[tostring(id)] = nil
    end
end


--计数器后台程序
thread.create(function(timeout_task)
    while true do
        for id,timeout_info in pairs(timeout_list) do
            local current_time = socket.gettime()
            if current_time > timeout_info.time then
                local callback = timeout_info.callback
                thread.create(function(timeout_callback)
                    callback()
                end)
                --删除这个超时
                timeout_list[id] = nil
            end
        end
        timeout_task.sleep(1)
    end
end,{
    task_name = "timer_bg",
    callBack = function()
    end,
    count = 0,
})

return timer

