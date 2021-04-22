--
-- Created by IntelliJ IDEA.
-- User: huanghaojing
-- Date: 16/8/5
-- Time: 下午12:36
-- To change this template use File | Settings | File Templates.
--


local platform_ios = true
if getOSType and getOSType()=="android" then
    platform_ios = false
end

--重定义nlog
--local nLog = require('nLog')

local json = platform_ios and require('sz').json or require('cjson')
local socket = platform_ios and require('szocket') or { gettime = function() return getCurrentTime() end }

local lua_error = error
local error = nLog
local nLog = print
local log_file_root = userPath().."/logs"
local print = nLog

local isDebug = true

if isDebug then
    --创建任务日志目录
--    os.execute("mkdir "..log_file_root)
end

local thread = {
    list = {},
    current_index = 0,
    total = 0,
    --最大任务数
    max_task_count = 5000,
    --超过协同最大数,放入栈中
    current_queue_index = 0,
    queue = {},
    current_thread_id = false,
    running = true,
}

function thread.create(func,input)

    local input = input or {}
    input.task_name = input.task_name or "server"
    input.count = input.count==nil and 1 or input.count

    if isDebug then
        input.filelog = input.filelog or false
    else
        input.filelog = false
    end

    --    local co = coroutine.create(func)
    local co = coroutine.create(function(task)

--        local newget = {}
--        setmetatable(newget,{__index=_G})
--        setfenv(1,newget)
--        nLog("sss")
--        abc = 1
        --保护模式运行task
        local ok,msg = pcall(func,task)

        if not ok then
--            nLog("task error",(input.task_name or "无"),msg)
            if type(msg) == "table" and msg.type == 'exception' then
                if task.input.catchBack then
                    task.input.catchBack(msg)
                end
                return false,msg
            else
                if task.input.errorBack then
                    task.input.errorBack(msg)
                end
                return false,{type='error',msg=msg}
            end

        end
        return true,msg
    end)

    thread.total = thread.total+1
    print("总的协同数:",thread.total)

    thread.current_index = thread.current_index+1
    local index = thread.current_index

    print("add task id="..index..",name="..(input.task_name or "无"));

    local log_file_name = log_file_root.."/"..(input.task_name or "无")

    --任务超时
    local timeout = 0
    local timeout_msg = ""

    --日志函数
    local log_func = function(...)
        local date=os.date("%Y-%m-%d %H:%M:%S");
        --插入时间、taskid，task_name
        local log_header = '['..index..']['..(input.task_name or "无").."]"

        if input.filelog then
            --写文件日志
            local f = io.open(log_file_name,"a+")

            if f then
                f:write('['..date..']'.."\t")
                local log_content = {... }
                for i,content in pairs(log_content) do
                    f:write(tostring(content).."\t")
                end
                f:write("\n")
                f:close()
            else
                error("写日志文件失败:",log_file_name)
            end
        end
        print(log_header,...)
    end
    --抛出异常函数
    local throw_func = function(msg,code,base_levle)
        local base_levle = base_levle or 0
        local di = debug.getinfo(2+base_levle,'Sln')
        if not di.name then di.name = "<"..di.short_src..":"..di.linedefined..">" end
        local debug_msg = di.short_src..":"..di.currentline.." in function "..di.name

        log_func("throw exception:",msg)
        lua_error({code=code or 99999,msg=msg or "exception",type="exception",debug=debug_msg})
    end

    thread.list[index] = {
        id = index,
        co = co,            --协同
        progress = 0,       --进度
        finished = false,   --是否完成
        input = input,      --输入参数
        output = {},        --输出参数
        sleep = function(ms)  --休眠函数
            local begin = socket.gettime()
            while true do
                coroutine:yield()
                if not thread.list[index].running then
                    --lua_error("stop task!")
                    throw_func("stop task!",10,1)
                end

                --处理任务超时
                if timeout>0 and socket.gettime()>timeout then
                    throw_func(timeout_msg)
                end
                if socket.gettime()-begin > ms/1000 then
                    break
                end
            end
        end,
        --设置超时
        setTimeout = function(ms,tm) timeout=socket.gettime()+ms/1000 timeout_msg= tm or "timeout" end,
        --清空超时
        clearTimeout = function() timeout=0 end,
        log = log_func,
        error = function(...) lua_error(...) end,
        throw = throw_func,
        running = true,
        subthread = {},
        createSubTask = function(...)
            local taskId = thread.create(...)
            thread.list[index].subthread[#thread.list[index].subthread+1] = taskId
            return taskId
        end,
        createWaitSubTask = function(...)
            local taskId = thread.list[index].createSubTask(...)
            return thread.wait(taskId)
        end,
    }

    --函数别名
    thread.list[index].createSubThread = thread.list[index].createSubTask
    thread.list[index].createWaitSubThread = thread.list[index].createWaitSubTask

    --调度任务
    --    thread.dispatch()
    --创建日志文件
    if input.filelog then
        local f = io.open(log_file_name,"w+")
        if f then
            f:close()
        else
            error("创建日志文件失败:",log_file_name)
        end

    end

    --返回任务序号
    return index
end

--创建任务，并等待结束
function thread.createWait(...) return thread.wait(thread.create(...)) end

--任务轮训
function thread.dispatch()
    --    print("thread.dispathch()");
    local active_thread_count = 0
    for taskId, task in pairs(thread.list)
    do
        if task.co ~= nil then
            local status = coroutine.status(task.co)
            if status == 'suspended' then
                thread.current_thread_id = taskId
                local status,res,msg = coroutine.resume(task.co,task)
                thread.current_thread_id = false
                active_thread_count = active_thread_count+task.input.count
                task.result = {
                    success=res,
                    message = msg,
                }
            elseif status == 'dead' then
                task.co = nil
                print("task stop:"..taskId..",name="..(task.input.task_name or "无"))
                thread.total = thread.total - 1
                print("总的协同数:",thread.total)

                task.progress = 100
                task.finished = true

                if task.input.callBack then
                    task.input.callBack(task.output)
                end

                --记录结束时间
                task.end_time=os.time()

                --关闭子任务
                for index,taskId in pairs(task.subthread) do
                    thread.stop(taskId)
                end

            else
                error("coroutine.status",status)
            end
        else
            --任务完成后，60秒没有被查询的任务，会被删除
            if os.time() - task.end_time > 6 then
                print("自动删除task:"..taskId..",name="..(task.input.task_name or "无"))
                thread.list[taskId] = nil
            end
        end
    end

    return active_thread_count
end

--查询任务状态
function thread.query(taskId)
    local task = thread.list[taskId]
    if task then
        if not task.co then
            --延长结束时间
            task.end_time=os.time()
        end
    end

    return task
end


--试图停止一个任务,任务函数看到这个标志后,会尽快结束任务
function thread.stop(taskId)
    local task = thread.query(taskId)
    if task then
        task.running = false
    end
end


--删除任务
function thread.del(taskId)
    thread.list[taskId] = nil
end

--获取当前进程id
function thread.getId()
    return thread.current_thread_id
end

--重新定义 mSleep
local mSleep_old = mSleep

--等待所有线程退出
function thread.waitAllThreadExit()

    if thread.current_thread_id then
       return false,"this is not main thread!"
    end

    while true do
        if thread.dispatch() == 0 then
            break
        end
        mSleep_old(10)
    end

    return true
end


mSleep = function(ms)
    local begin = socket.gettime()
    if not thread.current_thread_id then
        --主线程
        while true do
            thread.dispatch()
            mSleep_old(10)
            if socket.gettime()-begin > ms/1000 then
                break
            end
        end
    else
        thread.list[thread.current_thread_id].sleep(ms)
    end
end

--等待任务结束
function thread.wait(taskId,waitFunc)
    while true do
        if thread.list[taskId] then
            if thread.list[taskId].co then
                if type(waitFunc) == "function" then waitFunc(taskId) end
--                coroutine:yield()
                mSleep(1)
            else
                return thread.list[taskId].result.success,thread.list[taskId].result.message
            end
        else
            return false,"no find taskId!"
        end
    end

end

--抛出异常
function thread.throw(msg)
    if not thread.current_thread_id then
        return false,"this is not in thread!"
    end
    thread.list[thread.current_thread_id].throw(msg)
end

--创建子线程
function thread.createSubThread(...)
    if not thread.current_thread_id then
        return false,"this is not in thread!"
    end
    return thread.list[thread.current_thread_id].createSubTask(...)
end

--设置超时
function thread.setTimeout(ms,thread_id)
    local thread_id = thread_id or thread.current_thread_id
    if not thread_id then
        return false,"this is not in thread!"
    end

    if not thread.list[thread_id] then
        return false,"thread id is not exist!"
    end

    thread.list[thread_id].setTimeout(ms)
    return true
end

--清除超时
function thread.clearTimeout(thread_id)
    local thread_id = thread_id or thread.current_thread_id

    if not thread_id then
        return false,"this is not in thread!"
    end
    if not thread.list[thread_id] then
        return false,"thread id is not exist!"
    end

    thread.list[thread_id].clearTimeout()
    return true
end


return thread
