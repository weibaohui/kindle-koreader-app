--[[--
krapi server —— Kindle 后台常驻 HTTP 控制接口

目标：让 AI / 脚本通过普通 HTTP 调用直接控制这台 Kindle（点按、长按、滑动、截屏），
      就像用 SSH 一样，但走的是"起一个 web 服务器 + 放接口"的思路。

为什么是"独立进程"而不是 KOReader 插件：
  * 独立进程不占用 KOReader 的 UI 线程 —— 一个慢客户端不会把阅读器卡死；
  * KOReader 崩溃 / 重启 / 退出，服务都还活着（接口可以报告 KOReader 是否在线）；
  * 用 /mnt/us/koreader/luajit + KOReader 自带的 LuaSocket(common/socket/score.so)
    就能跑，设备上不需要装任何新东西。

实测踩过的坑（都在下面代码里标注了）：
  1) 设备的 /usr/bin/lua 是 PUC Lua 5.1.4，**加载不了** KOReader 的 LuaSocket
     （score.so 报 "undefined symbol: luaL_setfuncs"，那是 Lua 5.2+ 的 API）。
     必须用 /mnt/us/koreader/luajit（LuaJIT）。
  2) LuaSocket 3.x 里 **socket.bind 是 socket.tcp() 对象的方法**，模块级的
     socket.bind 不存在（nil）。要用 srv = socket.tcp(); srv:bind(...); srv:listen(...)。
  3) Kindle 的 iptables INPUT 策略是 **DROP**，只放行 2222/40317/8134 等少数端口。
     任何新开的端口都会被防火墙挡掉 —— 必须先 iptables -I INPUT 1 -p tcp --dport <port> -j ACCEPT。
  4) 设备的 /tmp 是内存盘，**重启即清空**。所以一切状态文件放 /tmp 是安全的，
     但启动脚本必须能在每次开机时重新跑（见 start.sh / install.sh）。
  5) 触控注入在这台机（zforce2）上**不能走 evdev**，必须让 KOReader 里的
     kr_tap_helper 插件代劳 —— 本服务只负责把命令写进 /tmp/kr_tap_cmd，然后等它执行。

用法:
  ./luajit server.lua [--port 8099]
--]]--

package.cpath = "/mnt/us/koreader/common/?.so;" .. package.cpath
package.path  = "/mnt/us/koreader/common/?.lua;" .. package.path

local socket = require("socket.score")
local dkjson = require("dkjson")

-- ======================= 配置 =======================
local PORT = 8099
local TOKEN_FILE = "/mnt/us/krapi/token"     -- 有内容则要求 X-Api-Token 头匹配
local LOG_FILE = "/mnt/us/krapi/server.log"
local BEAT_FILE = "/tmp/krapi_beat"          -- 心跳（/tmp 是内存盘，重启清空）
local TAP_CMD = "/tmp/kr_tap_cmd"            -- KOReader 触控助手的命令文件
local TAP_LOG = "/tmp/kr_tap.log"            -- 触控助手的执行日志
local TAP_BEAT = "/tmp/kr_tap_beat"          -- 触控助手心跳
local SCREENSHOT_DIR = "/mnt/us"             -- /usr/sbin/screenshot 的落盘目录
local TOUCH_TIMEOUT = 6                      -- 等 KOReader 执行触控命令的秒数

for i = 1, #arg do
    if arg[i] == "--port" and arg[i + 1] then
        PORT = tonumber(arg[i + 1]) or PORT
    end
end

-- ======================= 小工具 =======================
local function log(msg)
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. tostring(msg) .. "\n")
        f:close()
    end
end

local function file_size(path)
    local f = io.open(path, "r")
    if not f then return 0 end
    local s = f:seek("end")
    f:close()
    return s or 0
end

local function read_from(path, offset)
    local f = io.open(path, "r")
    if not f then return "" end
    f:seek("set", offset)
    local d = f:read("*a")
    f:close()
    return d or ""
end

-- 跑一条命令取第一行输出
local function cmdline(cmd)
    local f = io.popen(cmd)
    if not f then return "" end
    local l = f:read("*l")
    f:close()
    return l or ""
end

local function url_decode(s)
    s = s:gsub("+", " ")
    s = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    return s
end

local function parse_query(q)
    local out = {}
    if not q or q == "" then return out end
    -- 注意：LuaJIT 5.1 的 gmatch 返回迭代函数，不能塞进 ipairs
    for pair in q:gmatch("[^&]+") do
        local k, v = pair:match("^([^=]*)=?(.*)$")
        if k and k ~= "" then out[url_decode(k)] = url_decode(v) end
    end
    return out
end

-- ======================= HTTP 基础 =======================
local STATUS_TEXT = {
    [200] = "OK", [400] = "Bad Request", [401] = "Unauthorized",
    [404] = "Not Found", [405] = "Method Not Allowed",
    [500] = "Internal Server Error", [503] = "Service Unavailable",
}

local function send_all(client, s)
    local ok, err = pcall(function() client:send(s) end)
    if not ok then log("send failed: " .. tostring(err)) end
end

local function send_json(client, code, obj)
    local body = dkjson.encode(obj) or "{}"
    send_all(client, string.format(
        "HTTP/1.1 %d %s\r\nContent-Type: application/json; charset=utf-8\r\n" ..
        "Content-Length: %d\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n%s",
        code, STATUS_TEXT[code] or "OK", #body, body))
end

local function send_binary(client, code, ctype, data)
    send_all(client, string.format(
        "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n" ..
        "Connection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n",
        code, STATUS_TEXT[code] or "OK", ctype, #data))
    send_all(client, data)
end

local function read_request(client)
    local line = client:receive("*l")
    if not line then return nil end
    local method, path = line:match("^(%S+)%s+(%S+)")
    if not method or not path then return nil end
    local headers = {}
    while true do
        local h = client:receive("*l")
        if h == nil then return nil end
        if h == "" then break end
        local k, v = h:match("^([^:]+):%s*(.*)$")
        if k then headers[k:lower()] = v end
    end
    local body = ""
    local cl = tonumber(headers["content-length"])
    if cl and cl > 0 then
        body = client:receive(cl) or ""
    end
    return { method = method:upper(), path = path, headers = headers, body = body }
end

-- ======================= 触控桥接 =======================
-- 把命令写进 /tmp/kr_tap_cmd，KOReader 里的 kr_tap_helper 插件（每秒轮询一次）会取走执行。
-- 我们通过观察 /tmp/kr_tap.log 里新增的 "done: <cmd>" 来确认真的执行了。
local function send_touch(cmd)
    local off = file_size(TAP_LOG)
    local f = io.open(TAP_CMD, "w")
    if not f then return false, "无法写入 " .. TAP_CMD end
    f:write(cmd .. "\n")
    f:close()

    local deadline = os.time() + TOUCH_TIMEOUT
    while os.time() < deadline do
        socket.sleep(0.2)
        local fresh = read_from(TAP_LOG, off)
        if fresh:find("done: " .. cmd, 1, true) then return true, "ok" end
        if fresh:find("cmd error", 1, true) then return false, "KOReader 侧执行出错" end
    end
    return false, "超时：KOReader 没响应（插件是否已装？/tmp/kr_tap_cmd 是否被消费？）"
end

-- ======================= 截屏 =======================
-- 用系统的 /usr/sbin/screenshot（framebuffer 级），取到图后立刻删掉 —— 零残留。
local function capture_png()
    os.execute("/usr/sbin/screenshot >/dev/null 2>&1")
    local f = io.popen("ls -1t " .. SCREENSHOT_DIR .. "/screenshot_*.png 2>/dev/null | head -n 1")
    local path = ""
    if f then path = f:read("*l") or ""; f:close() end
    path = path:gsub("%s+$", "")
    if path == "" then return nil, "截屏失败（设备没有生成 screenshot_*.png）" end
    local fh = io.open(path, "rb")
    if not fh then return nil, "打不开 " .. path end
    local data = fh:read("*a")
    fh:close()
    os.remove(path)
    if not data or #data == 0 then return nil, "截屏文件为空" end
    return data
end

-- ======================= 各接口实现 =======================
local function ko_reader_alive()
    local beat = tonumber(cmdline("cat " .. TAP_BEAT .. " 2>/dev/null") or "") or 0
    if beat == 0 then return false, 0 end
    return true, os.time() - beat
end

local function handle_ping()
    return { ok = true, service = "krapi", version = "0.1.0", time = os.time() }
end

local function handle_status()
    local alive, age = ko_reader_alive()
    local bat = cmdline("cat /sys/class/power_supply/max77696-battery/capacity 2>/dev/null")
    local cur = cmdline("cat /sys/class/power_supply/max77696-battery/current_now 2>/dev/null")
    local volt = cmdline("cat /sys/class/power_supply/max77696-battery/voltage_now 2>/dev/null")
    local mem = cmdline("grep MemAvailable /proc/meminfo 2>/dev/null")
    local load = cmdline("cat /proc/loadavg 2>/dev/null")
    local up = cmdline("cat /proc/uptime 2>/dev/null")
    local ip = cmdline("ip route get 8.8.8.8 2>/dev/null | grep -o 'src [0-9.]*' | cut -d' ' -f2")
    return {
        ok = true,
        service = "krapi",
        version = "0.1.0",
        time = os.time(),
        device = {
            model = "Kindle Basic 7th Gen (KT2)",
            screen = "600x800, 16 gray",
            ip = ip ~= "" and ip or "192.168.0.99",
            uptime = up,
            load = load,
            mem_available = mem,
        },
        power = {
            capacity_pct = tonumber(bat) or 0,
            current_mA = tonumber(cur) or 0,
            voltage_mV = tonumber(volt) or 0,
        },
        koreader = {
            alive = alive,
            helper_age_sec = age,
            suspend_timeout = cmdline(
                "grep auto_suspend_timeout_seconds /mnt/us/koreader/settings.reader.lua 2>/dev/null"),
        },
        server = { port = PORT, pid = nil },
    }
end

local function handle_touch(req, q)
    -- swipe 用 x1/y1/x2/y2；tap/hold 用 x/y
    local x  = tonumber(q.x)  or tonumber(q.x1)
    local y  = tonumber(q.y)  or tonumber(q.y1)
    if not x or not y then
        return 400, { ok = false, error = "缺少 x / y 参数" }
    end
    if x < 0 or x > 599 or y < 0 or y > 799 then
        return 400, { ok = false, error = "坐标越界（有效范围 x 0-599, y 0-799）" }
    end
    local cmd
    if req.path == "/tap" then
        cmd = string.format("tap %d %d", x, y)
    elseif req.path == "/hold" then
        local ms = tonumber(q.ms) or 1200
        cmd = string.format("hold %d %d %d", x, y, ms)
    elseif req.path == "/swipe" then
        local x2 = tonumber(q.x2) or x
        local y2 = tonumber(q.y2) or y
        local ms = tonumber(q.ms) or 400
        if x2 < 0 or x2 > 599 or y2 < 0 or y2 > 799 then
            return 400, { ok = false, error = "终点坐标越界" }
        end
        cmd = string.format("swipe %d %d %d %d %d", x, y, x2, y2, ms)
    else
        return 404, { ok = false, error = "未知接口 " .. tostring(req.path) }
    end
    local ok, err = send_touch(cmd)
    if not ok then return 503, { ok = false, error = err, cmd = cmd } end
    return 200, { ok = true, cmd = cmd }
end

-- ======================= 路由 =======================
local function handle(req)
    local path = req.path
    local qs = ""
    local qidx = path:find("?", 1, true)
    if qidx then
        qs = path:sub(qidx + 1)
        path = path:sub(1, qidx - 1)
    end
    local q = parse_query(qs)
    req.path = path          -- 关键：把去掉 query 的路径写回去，否则路由匹配不到

    -- JSON body 也收（形如 {"x":1,"y":2}），方便 POST
    if req.body and #req.body > 0 then
        local obj = dkjson.decode(req.body)
        if type(obj) == "table" then
            for k, v in pairs(obj) do
                if q[k] == nil then q[k] = v end
            end
        end
    end

    -- 鉴权（token 文件非空时生效）
    local tf = io.open(TOKEN_FILE, "r")
    local token = ""
    if tf then token = (tf:read("*a") or ""):gsub("%s+$", ""); tf:close() end
    if token ~= "" then
        local got = req.headers["x-api-token"] or q.token
        if got ~= token then
            return 401, { ok = false, error = "缺少或错误的 X-Api-Token" }
        end
    end

    if path == "/ping" then
        return 200, handle_ping()
    elseif path == "/status" then
        return 200, handle_status()
    elseif path == "/screenshot.png" or path == "/screen.png" then
        local data, err = capture_png()
        if not data then return 500, { ok = false, error = err } end
        return "BINARY", data
    elseif path == "/tap" or path == "/hold" or path == "/swipe" then
        return handle_touch(req, q)
    elseif path == "/logs" then
        local n = tonumber(q.n) or 30
        local f = io.open("/mnt/us/krapi/server.log", "r")
        local content = ""
        if f then content = f:read("*a"); f:close() end
        local lines = {}
        for line in content:gmatch("[^\n]+") do lines[#lines + 1] = line end
        local out = {}
        local from = math.max(1, #lines - n + 1)
        for i = from, #lines do out[#out + 1] = lines[i] end
        return 200, { ok = true, lines = out }
    end
    return 404, { ok = false, error = "未知接口 " .. path }
end

-- ======================= 看门狗 =======================
-- 越狱脚本（jb.sh）每次开机都会重建 iptables 的 INPUT 链，
-- 我们插在链首的放行规则可能被冲掉 —— 所以服务自己定期检查并补回。
-- 这也是"开机钩子跑在越狱之前"时的保险。
local function ensure_iptables()
    local r = os.execute("iptables -C INPUT -p tcp --dport " .. PORT .. " -j ACCEPT 2>/dev/null")
    -- LuaJIT 5.1 的 os.execute 返回退出码（数字）；5.2+ 返回 true/nil
    local ok = (r == 0) or (r == true)
    if not ok then
        os.execute("iptables -I INPUT 1 -p tcp --dport " .. PORT .. " -j ACCEPT 2>/dev/null")
        log("看门狗: 重新放行端口 " .. PORT)
    end
end

-- ======================= 主循环 =======================
local srv = socket.tcp()
srv:setoption("reuseaddr", true)
-- bind 失败最常见的原因是"上一个实例刚被杀、端口还没让出来"。
-- 与其直接退出，不如重试若干次 —— 服务是常驻的，起来一次就得一直活着。
local ok, err
for attempt = 1, 10 do
    ok, err = srv:bind("0.0.0.0", PORT)
    if ok then break end
    log("bind 失败（第 " .. attempt .. " 次）: " .. tostring(err))
    socket.sleep(3)
end
if not ok then
    log("bind 彻底失败: " .. tostring(err))
    print("bind failed: " .. tostring(err))
    os.exit(1)
end
assert(srv:listen(16))
srv:settimeout(1)          -- accept 超时 1 秒（到点返回 nil，循环继续）

log("krapi server 启动，监听 0.0.0.0:" .. PORT .. " pid=" .. tostring(os.time()))
print("krapi listening on 0.0.0.0:" .. PORT)

local last_check = os.time()
while true do
    local client = srv:accept()
    if client then
        -- 任何异常都不能让服务器挂掉
        pcall(function()
            client:settimeout(3)
            local req = read_request(client)
            if req then
                local code, payload = handle(req)
                if code == "BINARY" then
                    send_binary(client, 200, "image/png", payload)
                else
                    send_json(client, code, payload)
                end
            else
                send_json(client, 400, { ok = false, error = "无法解析的请求" })
            end
        end)
        pcall(function() client:close() end)
    else
        -- 写心跳，供 Mac 侧判活
        local f = io.open(BEAT_FILE, "w")
        if f then f:write(tostring(os.time())); f:close() end
    end

    -- 每 60 秒检查一次防火墙规则
    local now = os.time()
    if now - last_check >= 60 then
        last_check = now
        pcall(ensure_iptables)
    end
end
