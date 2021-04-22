--
-- Created by IntelliJ IDEA.
-- User: huanghaojing
-- Date: 16/11/7
-- Time: 上午10:24
-- To change this template use File | Settings | File Templates.
-- 消息派发


local thread = require('thread')

local event = {
}

local callback_list = {}
local set_list = {}
local callback_index = 0


function event.register(name,callback)

    if type(name) ~= "string" then
        return false,"name is not string!"
    end

    if type(callback) ~= "function" then
        return false,"callback is not funciton!"
    end

    callback_index=callback_index+1
    local id = callback_index

    callback_list[tostring(id)] = {
        name = name,
        callback=callback
    }

    return id
end


function event.unregister(id)
    if callback_list[tostring(id)] then
        callback_list[tostring(id)] = nil
    end
end

function event.set(name,value)
    if type(name) ~= "string" then
        return false,"name is not string!"
    end

    set_list[tostring(name)] = value or ''
end

thread.create(function(event_loop_task)
    while true do
        for name,data in pairs(set_list) do
            for id,callback_info in pairs(callback_list) do
                if callback_info.name == name and type(callback_info.callback)=="function" then
                    local mydata = data
                    thread.create(function(task)
                        callback_info.callback(mydata)
                    end)
                end
            end

            --删除这个事件
            set_list[name] = nil
        end

        event_loop_task.sleep(10)
    end
end,{
    callBack = function()
    end,
    count = 0,
})

return event

