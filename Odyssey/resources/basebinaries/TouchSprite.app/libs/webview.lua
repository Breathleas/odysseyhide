--
-- Created by IntelliJ IDEA.
-- User: huanghaojing
-- Date: 16/11/4
-- Time: 下午2:40
-- To change this template use File | Settings | File Templates.
--

local webServer = require("webServer")

--local nLog = require('nLog')
local nLog = print

local event = require('event')

local sz = require('sz');
local json = sz.json;

local webview = {}

local webview_list = {}


local touchsprite_js = [[

touchsprite = {};
//调用全局函数
touchsprite.call = function(function_name){

  var cb = function(){};
  //find cb
  for(var i = 1; i<arguments.length;i++){
    if(typeof arguments[i] == "function"){
      cb = arguments[i];
      break;
    }
  }

  if(typeof function_name != "string"){
    return cb(false,"function type invalid");
  }

  if(!/^\w+$/.test(function_name)){
    return cb(false,"function name invalid");
  }

  var call_params = "";
  for(var i = 1; i<arguments.length;i++){
    if(typeof arguments[i] == "object"){
      return cb(false,"call只支持string,number参数!");
    }
    else if(typeof arguments[i] == "function"){
      break;
    }
    else if(typeof arguments[i] == "string"){
      call_params += (","+"[["+arguments[i]+'\]\]');
    }
    else{
      call_params += (","+arguments[i]);
    }
  }

  if(call_params.length > 0){
    call_params = call_params.substr(1);
  }

  var luaStr = "if type("+function_name+") ~= 'function' then" +
  " return {false,'"+function_name+" is not function'}" +
  " end" +
  " local ret= {"+function_name+"("+call_params+")}" +
  " return {true,#ret==1 and ret[1] or ret}";

  touchsprite.doString(luaStr,function(success,ret){
    if(!success) return cb(false,ret);
    return cb(ret[0],ret[1]);
  });
};

//设置全局变量
touchsprite.setVariable = function(name,value,cb){

  var cb = (typeof(cb)=="function")? cb : function(){};

  if(typeof name != "string"){
    return cb(false,"name type invalid");
  }

  if(!/^\w+$/.test(name)){
    return cb(false,"name invalid");
  }

  var xhr = new XMLHttpRequest(); //new xhr对象
  xhr.open(
    "post", //类型
    "/setVariable", //接口
    true
  );
  xhr.setRequestHeader("X-Requested-With", "XMLHttpRequest"); //设置请求头
  xhr.setRequestHeader('Content-Type', 'application/json');
  xhr.onreadystatechange = function() { //返回结果
    if (xhr.readyState == 4) { //请求成功
      switch (xhr.status) {
        case 200:
          var response = xhr.responseText; //返回结果数据(字符串)
          response = JSON.parse(response); //转换数据类型
          return cb(response.success,response.message);
          break;
        case 403:
          return cb(false,"禁止访问");
          break;
        case 404:
          return cb(false,"无接口");
          break;
        case 500:
          return cb(false,"内部服务器错误");
          break;
        case 502:
          return cb(false,"网关错误");
          break;
        default:
          return cb(false,"未知错误:"+xhr.status);
          break;
      }
    }
  };
  xhr.send(JSON.stringify({name:name,value:value}));
};

//发送事件
touchsprite.setEvent = function(name,value,cb){
  var cb = (typeof(cb)=="function")? cb : function(){};

  if(typeof name != "string"){
    return cb(false,"name type invalid");
  }

  if(!/^\w+$/.test(name)){
    return cb(false,"name invalid");
  }

  var xhr = new XMLHttpRequest(); //new xhr对象
  xhr.open(
    "post", //类型
    "/set_event", //接口
    true
  );
  xhr.setRequestHeader("X-Requested-With", "XMLHttpRequest"); //设置请求头
  xhr.setRequestHeader('Content-Type', 'application/json');
  xhr.onreadystatechange = function() { //返回结果
    if (xhr.readyState == 4) { //请求成功
      switch (xhr.status) {
        case 200:
          var response = xhr.responseText; //返回结果数据(字符串)
          response = JSON.parse(response); //转换数据类型
          return cb(response.success,response.message);
          break;
        case 403:
          return cb(false,"禁止访问");
          break;
        case 404:
          return cb(false,"无接口");
          break;
        case 500:
          return cb(false,"内部服务器错误");
          break;
        case 502:
          return cb(false,"网关错误");
          break;
        default:
          return cb(false,"未知错误:"+xhr.status);
          break;
      }
    }
  };
  xhr.send(JSON.stringify({name:name,value:value}));
};

//运行lua脚本
touchsprite.doString = function(str,cb){
  var cb = (typeof(cb)=="function")? cb : function(){};
  var xhr = new XMLHttpRequest(); //new xhr对象
  xhr.open(
    "post", //类型
    "/doString", //接口
    true
  );
  xhr.setRequestHeader("X-Requested-With", "XMLHttpRequest"); //设置请求头
  xhr.setRequestHeader('Content-Type', 'application/json');
  xhr.onreadystatechange = function() { //返回结果
    if (xhr.readyState == 4) { //请求成功
      switch (xhr.status) {
        case 200:
          var response = xhr.responseText; //返回结果数据(字符串)
          response = JSON.parse(response); //转换数据类型
          return cb(response.success,response.message);
          break;
        case 403:
          return cb(false,"禁止访问");
          break;
        case 404:
          return cb(false,"无接口");
          break;
        case 500:
          return cb(false,"内部服务器错误");
          break;
        case 502:
          return cb(false,"网关错误");
          break;
        default:
          return cb(false,"未知错误:"+xhr.status);
          break;
      }
    }
  };
  xhr.send(str);
};

//关闭webview
touchsprite.closeWebView = function(){
  var xhr = new XMLHttpRequest(); //new xhr对象
  xhr.open(
    "post", //类型
    "/closeWebView", //接口
    true
  );
  xhr.setRequestHeader("X-Requested-With", "XMLHttpRequest"); //设置请求头
  xhr.setRequestHeader('Content-Type', 'application/json');
  xhr.send('');
};
]]

webview.new = function(wid,option)

    if type(wid) ~= "string" then
        return false,"wid is not string!"
    end

    if webview_list[wid] then
        return false,"wid is exist!"
    end

    local webui = {}
    local option = option or {}
    local wid = wid

    --启动web服务
    option.root = option.root or userPath().."/res"
    option.files =  option.files or {}

    local webui_files = require('webui_files')
    for filename,file_data in pairs(webui_files) do
        option.files[filename]=file_data
    end
    option.files["ts.js"] = touchsprite_js

    option.index = option.index or 'index.html'

    local index_name = 'sldfjslsdegld'

    if option.html then
        option.files[index_name] = option.html
        option.index = index_name
    end


    local web_server = webServer.create(0,function(req,res,task)

        nLog('webServer',req.path)

        --处理event post
        if req.path == [[/set_event]] then
            local ret = {success=false,message = "未知"}

            local ok,event_info = pcall(json.decode,req.post_data)

            if ok then
                if event_info.name and type(event_info.name)=="string" then
                    event.set(event_info.name,event_info.value)
                    ret = {success=true}
                else
                    ret.message = "缺少参数!"
                end
            else
                ret.message = event_info
            end

            res.headers['Content-type']='application/json; charset=utf-8'
            return json.encode(ret)
        elseif req.path == [[/closeWebView]] then
            webui.close()
        elseif req.path == [[/setVariable]] then
            local ret = {success=false,message = "未知"}

            local ok,event_info = pcall(json.decode,req.post_data)

            if ok then
                if event_info.name and type(event_info.name)=="string" then
                    --                    nLog(event_info)
                    _ENV[event_info.name] = event_info.value
                    ret = {success=true}
                else
                    ret.message = "缺少参数!"
                end
            else
                ret.message = event_info
            end

            res.headers['Content-type']='application/json; charset=utf-8'
            return json.encode(ret)
        elseif req.path == [[/doString]] then

            nLog(req.post_data)
            res.headers['Content-type']='application/json; charset=utf-8'

            local fun, msg = load(req.post_data,"webview")
            if not fun then
                return json.encode({
                    success = false,
                    message = msg,
                })
            end

            local ok,msg = pcall(fun,{
                task=task,
                req = req,
                res = res,
            })

            return json.encode({
                success = ok,
                message = msg,
            })

        elseif req.path == [[/save_file]] then
            local ret = {success=false,message = "未知" }

            local ok,file_info = pcall(json.decode,req.post_data)

            if ok then
                if file_info.name and type(file_info.name)=="string" and file_info.data then
                    local filename = option.root.."/"..file_info.name
                    local f = io.open(filename,"wb")
                    if f then
                        f:write(json.encode(file_info.data))
                        f:close()

                        ret = {success=true}
                    else
                        ret.message = "无法打开文件:"..filename
                    end
                else
                    ret.message = "缺少参数!"
                end
            else
                ret.message = file_info
            end

            res.headers['Content-type']='application/json; charset=utf-8'
            return json.encode(ret)
        elseif req.path == [[/load_file]] then
            local ret = {success=false,message = "未知" }

            local ok,file_info = pcall(json.decode,req.post_data)

            if ok then
                if file_info.name and type(file_info.name)=="string"then
                    local filename = option.root.."/"..file_info.name
                    local f = io.open(filename,"rb")
                    if f then
                        local file_data = f:read("*all")
                        f:close()

                        local ok,data = pcall(json.decode,file_data)

                        if ok then
                            ret = {success=true,data=data}
                        else
                            ret.message = data
                        end
                    else
                        ret.message = "无法打开文件:"..filename
                    end
                else
                    ret.message = "缺少参数!"
                end
            else
                ret.message = file_info
            end

            res.headers['Content-type']='application/json; charset=utf-8'
            return json.encode(ret)
        end

        local path = string.sub(req.path,2)
        if option.files[path] then
            return option.files[path]
        end

        return "no find"
    end,{
        root=option.root,
        files = {
            {grep = ".*%.json$",Content_Type="application/json; charset=utf-8;"},
            {grep = ".*%.png$",Content_Type="image/png;"},
            {grep = ".*%.jpg$",Content_Type="image/jpg;"},
            {grep = ".*%.jpeg$",Content_Type="image/jpeg;"},
            {grep = ".*%.html$",Content_Type="text/html; charset=utf-8;"},
            {grep = ".*%.css$",Content_Type="text/css;"},
            {grep = ".*%.log$",Content_Type="text/css;"},
            {grep = ".*%.js$",Content_Type="application/x-javascript;"},
            {grep = ".*%.ico$",Content_Type="image/ico;"},
            {grep = ".*%.ttf$",Content_Type="application/x-font-ttf;"},
            {grep = ".*%.ttc$",Content_Type="application/x-font-ttf;"},
            {grep = ".*%.ttx$",Content_Type="application/x-font-ttx;"},
            {grep = ".*%.txt$",Content_Type="text/plain;"},
            {grep = ".*%..*$",Content_Type="application/octet-stream;"},
            {grep = ".*$",Content_Type="application/octet-stream;"},
        }
    })

    local port = web_server:run()
    nLog('webview port',port)

    function webui.show()

        showWebUI({
            originx = option.originx,
            originy = option.originy,
            width = option.width,
            height = option.height,
            orient = option.orient,
            cornerRadius = option.cornerRadius,
            id = wid,
            url = "http://127.0.0.1:"..port.."/"..option.index
        })

        runJsInWebUI({
            id=wid,
            js=touchsprite_js
        })
    end

    function webui.set(new_option)

        local new_option = new_option or {}
        option.originx = new_option.originx or option.originx
        option.originy = new_option.originy or option.originy
        option.width = new_option.width or option.width
        option.height = new_option.height or option.height
        option.orient = new_option.orient or option.orient
        option.cornerRadius = new_option.cornerRadius or option.cornerRadius

        showWebUI({
            originx = option.originx,
            originy = option.originy,
            width = option.width,
            height = option.height,
            orient = option.orient,
            cornerRadius = option.cornerRadius,
            id = wid,
        })
    end

    function webui.close()
        closeWebUI(wid)
        web_server:stop()
        webview_list[wid] = nil
    end

    webui.hide = webui.close

    function webui.runJs(js)
        return runJsInWebUI({
            id=wid,
            js=js
        })
    end

    webview_list[wid] = webui

    return webui
end


webview.version = "1.2"
webview.build = 1106

return webview

