--
-- Created by IntelliJ IDEA.
-- User: huanghaojing
-- Date: 16/6/17
-- Time: 上午11:26
-- To change this template use File | Settings | File Templates.
--


local platform_ios = true
if getOSType and getOSType()=="android" then
    platform_ios = false
end

local json = platform_ios and require('sz').json or require('cjson')
local socket = platform_ios and require('szocket') or require('socket')
local url = platform_ios and require("szocket.url") or require('socket.url')

local socket_help = {

}

--循环发送
function socket_help.sock_send(task,sock,data,i)

    i = i or 1
    --    print("send",data,i)

    local pos,err,pos2= sock:send(data,i)

    --    print("pos=",pos,err,pos2)

    if not pos then
        if err == "timeout" then
            task.sleep(1)
            return socket_help.sock_send(task,sock,data,pos2+1)
        else
            return false,"sock send err:"..err
        end
    elseif pos == #data then
        return true
    else
        --没发送完整,等10毫秒再发送
        task.sleep(1)
        return socket_help.sock_send(task,sock,data,pos+1)
    end
end

--接收一行
function socket_help.receive_line(task,sock)

    while true do
        local chunk, status, partial = sock:receive('*l')

        if chunk then
            return chunk
        end
        if status~= 'timeout' then
            task.throw("socket_help.receive_line error:"..status)
        end
        task.sleep(1)
    end
end

--接收
function socket_help.receive_line_timeout(task,sock,timeout)

    local ok,ret = task.createWaitSubTask(function(sub_task)
        sub_task.setTimeout(timeout)
        return socket_help.receive_line(sub_task,sock)
    end)

    if not ok then
        return false,ret.msg
    end

    return ret
end


function socket_help.http(task,input)

    if type(input) ~= "table" then
        task.throw("http_help.require input param error")
    end

    if type(input.url) ~= "string" then
        task.throw("http_help.require input.url param error")
    end

    input.method = input.method or "GET"
    if not (type(input.method) == "string" and (input.method == "POST" or input.method == "GET")) then
        task.throw("http_help.require input.method param error")
    end

    local sock,msg
    while true do
        sock,msg = socket.tcp()
        if (not sock) and msg == "Too many open files" then
            --如果是因为句柄不足造成的创建失败,等会儿重试一下
            task.log("句柄不足")
            task.sleep(100)
        else
            break
        end
    end

    if not sock then
        task.throw("socket create error:"..msg)
    end

    sock:settimeout(0)
    local output = {
        headers= {}
    }

    --安全运行
    local ok,msg = task.createWaitSubTask(function(sub_task)
        local urlinfo = url.parse(input.url)
        task.log("urlinfo",json.encode(urlinfo))

        local ok,error = sock:connect(urlinfo.host, urlinfo.port or 80)  -- 创建一个 TCP 连接，连接到 HTTP 连接的标准 80 端口上

        --等待连接成功
        sub_task.setTimeout(3000,"connect timeout")
        while true do
            local recvt, sendt, status = socket.select(nil,{sock}, 0)
            if #sendt > 0 then
                ok = true
                break
            end
            task.log("等待连接...")
            sub_task.sleep(500)
        end
        sub_task.clearTimeout()
        task.log("连接成功!")

        --30秒超时
        sub_task.setTimeout(input.timeout or 1000*30)
        -- http 1.0没有chunk问题，比较容易处理
        socket_help.sock_send(sub_task,sock,input.method.." " .. (urlinfo.path or "/")..(urlinfo.query and ('?'..urlinfo.query) or '' ) .. " HTTP/1.0\r\n")


        --添加缺省header
        local headers = input.headers or {}
        headers['User-Agent'] = headers['User-Agent'] or "TouchSprite Enterprise v1.0"
        headers['Connection'] = headers['Connection'] or "close"
        headers['Host'] = headers['Host'] or urlinfo.host
        --    headers['Content-Type'] = headers['Content-Type'] or 'text/html; charset=utf-8'

        if input.method == "POST" and input.postdata then
            headers['Content-Length'] = #input.postdata
        end

--        task.log("send headers:",json.encode(headers))

        for name,value in pairs(headers)
        do
            socket_help.sock_send(sub_task,sock,name..': '..value.."\r\n")
        end

        socket_help.sock_send(sub_task,sock,"\r\n");

        --发送post数据
        if input.method == "POST" and input.postdata then
            task.log("postdata:"..input.postdata)
            socket_help.sock_send(sub_task,sock,input.postdata)
        end

        --接收code
        local line =  socket_help.receive_line(sub_task,sock)
        _,_,output.code = string.find(line, ".+%s+(%d+)")

        if output.code then
            output.code = tonumber(output.code)
            task.log('code:',output.code)
        else
            sub_task.throw("没有找到http code!")
        end

        -- 接收header
        while true do
            local line =  socket_help.receive_line(sub_task,sock)

            if #line == 0 then
--                task.log('结束header')
                break;
            end

            local _,_,name,value = string.find(line, "^(.-):%s*(.*)")

            if name then
--                task.log('header:'..name..": "..value)
                output.headers[string.lower(name)] = value;
            else
                task.log("无效的header!")
            end
        end

--        task.log("收到headers:"..json.encode(output.headers))

        --接收body
        output.body = ""
        while true do
            local chunk, status, partial = sock:receive(output.headers['content-length'] or 1024)
            output.body = output.body..(chunk or partial)

            if status == 'timeout' then
                sub_task.sleep(10)
            end
            if status == 'closed' then break end

            --有长度字段接收到长度字段，没有接收到连接断开
            if output.headers['content-length']
                    and tonumber(output.headers['content-length']) == #output.body then
                break
            end
        end

--        task.log("body:",output.body)

    end,{
        callBack = function(output)
            if sock then
                sock:close()
            end
        end,
        --        errorBack = function(...) task.error(...) end,
        --        catchBack = function(exp) task.throw(exp.msg,exp.code) end,
    })
    if not ok then
        if type(msg) == "table" and msg.type == 'exception' then
            task.throw(msg.msg,msg.code)
        end
    end


    return output.code,output.body
end


--连接一个远程服务
function socket_help.connect(task,remote_ip,remote_port,option)
    local option = option or {}
    option.timeout = option.timeout or 5000

    local sock,err = socket.tcp()
    if not sock then
        return false,"create tcp socket fail:"..err
    end

    sock:settimeout(0)

    local ok,ret = task.createWaitSubTask(function(sub_task)
        local ok,err = sock:connect(remote_ip,remote_port)

        sub_task.setTimeout(option.timeout)
        while true do
            local recvt, sendt, status = socket.select(nil,{sock}, 0)
            if #sendt > 0 then
                break
            end
            sub_task.sleep(500)
        end
        return true
    end)

    if not ok then
        return false,ret.msg
    end

    return sock

end

return socket_help

