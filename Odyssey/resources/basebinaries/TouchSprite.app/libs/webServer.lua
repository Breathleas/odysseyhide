--
-- Created by IntelliJ IDEA.
-- User: huanghaojing
-- Date: 16/1/5
-- Time: 上午9:49
-- To change this template use File | Settings | File Templates.
--

local platform_ios = true
if getOSType and getOSType()=="android" then
    platform_ios = false
end

local json = platform_ios and require('sz').json or require('cjson')
local socket = platform_ios and require('szocket') or require('socket')

local thread = require('thread')
local socket_help = require('socket_help')

--local nLog = require('nLog')
local nLog = print

local webServer = {}

--url解码
local function decodeURI(s)
    s = string.gsub(s, '%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end)
    return s
end

function string.split(str, delimiter)
    if str==nil or str=='' or delimiter==nil then
        return nil
    end
    local result = {}
    for match in (str..delimiter):gmatch("(.-)"..delimiter) do
        table.insert(result, match)
    end
    return result
end


--循环发送
local function sock_send(task,sock,data,i)

    i = i or 1
    --    print("send",data,i)

    local pos,err,pos2= sock:send(data,i)

    --    print("pos=",pos,err,pos2)

    if not pos then
        if err == "timeout" then
            task.sleep(1)
            return sock_send(task,sock,data,pos2+1)
        else
            return false
        end
    elseif pos == #data then
        return true
    else
        --没发送完整,等10毫秒再发送
        task.sleep(1)
        return sock_send(task,sock,data,pos+1)
    end
end


--处理一个httpclient
local function httpClient(parent_task,sock,respond_func,conf)
    local conf = conf or {}
    local client = {}

    sock:settimeout(0)
    local client_ip,client_port = sock:getpeername()

    parent_task.createSubTask(function(task)

        nLog("begin httpClient")
        local print = task.log
        local method,path,http_protocol

        task.log("准备接收协议")
        task.setTimeout(3000)
        local line = socket_help.receive_line(task,sock)
        _,_,method,path,http_protocol = string.find(line, "(.+)%s+(.+)%s+(.+)")

        if method~='GET' and method~='get'
                and method~='POST' and method~='post'
                and method~='OPTIONS' and method~='options'
        then
            task.throw("无效的method:"..method)
        end

        if type(path) ~= "string" then
            task.throw("无效的 path:")
        end

        nLog('path=',path)

        if type(http_protocol) ~= "string" then
            task.throw("无效的 http_protocol:")
        end


        local is_post = false
        if not (method=='GET' or method=='get') then
            is_post = true
        end

        --提取get参数
        local split_result = string.split(path, "?")
        path = split_result[1]

        local params = {}
        --开始查分参数
        if split_result[2] then
            local params_str = split_result[2]
            local split_result = string.split(params_str, "&")

            for i,param in pairs(split_result) do
                if #param > 0 then
                    local split_param = string.split(param, "=")
                    if #split_param == 2 then
                        params[split_param[1]] = decodeURI(split_param[2])
                    end
                end
            end
        end

        -- 接收headers
        local headers = {}
        while true do
            local line = socket_help.receive_line(task,sock)

            if #line == 0 then
                print('结束header')
                break;
            end

            local _,_,name,value = string.find(line, "^(.-):%s*(.*)")
            line = ''

            if name then
                print('header:'..name..": "..value)
                headers[string.lower(name)] = value;
            else
                print("无效的header!")
            end
        end

        local post_data = ''
        if is_post and headers['content-length'] then

            local post_length = tonumber(headers['content-length'])
            print('post_length=',post_length)

            while true do
                local chunk, status, partial = sock:receive(post_length - #post_data)
                post_data = post_data..(chunk or partial)

                if status == 'timeout' then
                    task.sleep(1)
                end
                if status == 'closed' then task.throw("connection is closed") end

                if #post_data >= post_length then
                    break;
                end
            end
        end

        --调用返回
        local body = nil
        local respond = {code=200,headers={}}
        if true then

            --判断直接返回文件
            if conf
                    and conf.root and conf.files
                    and type(conf.files)=="table" then

                for index,file_grep in pairs(conf.files) do

                    print("file_grep.grep=",file_grep.grep)

                    if type(file_grep) == "table" and type(file_grep['grep'])== "string"
                            and string.find(path,file_grep["grep"])~=nil then

                        local filename = conf.root..path
                        local f = io.open(filename,"rb")
                        if f then
                            body = f:read("*all")
                            f:close()

                            if type(file_grep["Content_Type"])== "string" then
                                --写Content_Type
                                respond.headers["Content-Type"] = file_grep["Content_Type"]
                            end
                            respond.headers["Connection"] = "close"
                            break
                        else
                            --                            body = ""
                            --                            respond.code = 404
                        end
                    end
                end
            end

            if body == nil then
                task.clearTimeout()
                body = respond_func({
                    method=method,path=path,headers=headers,
                    params=params,post_data=post_data,
                    client_ip=client_ip,client_port=client_port
                },respond,task)
            end
        end

        if body then
            headers['Content-Length']=#body
            --            sock:send(http_protocol.." "..respond.code.."\r\n")
            sock_send(task,sock,http_protocol.." "..respond.code.."\r\n")

            for name,value in pairs(respond.headers)
            do
                --                sock:send(name..': '..value.."\r\n")
                sock_send(task,sock,name..': '..value.."\r\n")
            end
            --            sock:send("\r\n");
            sock_send(task,sock,"\r\n");
            --            sock:send(body);
            sock_send(task,sock,body);
        end

        --        sock:close()
    end,{
        task_name="httpClient"..(conf.name or "")..conf.port,
        --        filelog = true,
        callBack = function(output)
            sock:close()
        end,

    })

    return client
end


function webServer.create(port,respond_func,conf)

    local conf = conf or {}
    local port = port or 0
    local server = {
    }

    conf.port = port

    --运行服务
    function server:run()

        server.socket = socket.tcp()
        server.socket:setoption("reuseaddr",true)
        local ok,msg = server.socket:bind("*",port)
        if not ok then
            nLog("绑定失败:",msg)
            return
        end
        server.socket:listen(1024)

        server.running = true
        server.socket:settimeout(0)

        --获取端口号
        local server_ip,server_port = server.socket:getsockname()
        server.port = server_port

        nLog("webserver port:",server_port)

        thread.create(function(task)
            while server.running do
                local conn = server.socket:accept()
                if conn then
                    task.log("accept ok")
                    httpClient(task,conn,respond_func,conf)
                end
                task.sleep(1)
            end
            server.socket:close()

        end,{
            task_name="webServer-"..port..(conf.name or ""),
            --            filelog = true,
        })

        return server.port
    end

    --停止服务
    function server:stop()
        server.running = false
    end

    return server
end

return webServer

