--[[--
拖拽注入脚本：在 Kindle 触摸总线 /dev/input/event1 上模拟"按下 -> 移动 -> 抬起"，
用于验证打砖块插件的 pan 跟手手势。

用法:
  LD_LIBRARY_PATH=/mnt/us/koreader/libs \
    /mnt/us/koreader/luajit /mnt/us/scripts/touch_drag.lua <x1> <y1> <x2> <y2> [steps] [step_delay_ms]
--]]--
local ffi = require('ffi')
ffi.cdef[[
    struct timeval {
        long tv_sec;
        long tv_usec;
    };
    struct input_event {
        struct timeval time;
        uint16_t type;
        uint16_t code;
        int32_t value;
    };
    int open(const char *pathname, int flags);
    int close(int fd);
    long write(int fd, const void *buf, unsigned long count);
    int usleep(unsigned int usec);
]]

local EV_SYN = 0
local SYN_REPORT = 0
local EV_KEY = 1
local BTN_TOUCH = 330
local BTN_TOOL_FINGER = 325
local EV_ABS = 3
local ABS_MT_SLOT = 47
local ABS_MT_TOUCH_MAJOR = 48
local ABS_MT_POSITION_X = 53
local ABS_MT_POSITION_Y = 54
local ABS_MT_TRACKING_ID = 57

local x1 = tonumber(arg[1]) or 300
local y1 = tonumber(arg[2]) or 400
local x2 = tonumber(arg[3]) or x1
local y2 = tonumber(arg[4]) or y1
local steps = tonumber(arg[5]) or 10
local delay = tonumber(arg[6]) or 30

local fd = ffi.C.open('/dev/input/event1', 1) -- O_WRONLY
if fd < 0 then
    print('Failed to open /dev/input/event1')
    os.exit(1)
end

local function send_event(type_, code, val)
    local ev = ffi.new('struct input_event')
    ev.type = type_
    ev.code = code
    ev.value = val
    ffi.C.write(fd, ev, ffi.sizeof(ev))
end

local function report()
    send_event(EV_SYN, SYN_REPORT, 0)
end

-- Touch down
send_event(EV_ABS, ABS_MT_TRACKING_ID, 0)
send_event(EV_ABS, ABS_MT_POSITION_X, x1)
send_event(EV_ABS, ABS_MT_POSITION_Y, y1)
send_event(EV_KEY, BTN_TOUCH, 1)
send_event(EV_KEY, BTN_TOOL_FINGER, 1)
report()
ffi.C.usleep(60000)

-- Move
for i = 1, steps do
    local t = i / steps
    local px = math.floor(x1 + (x2 - x1) * t + 0.5)
    local py = math.floor(y1 + (y2 - y1) * t + 0.5)
    send_event(EV_ABS, ABS_MT_POSITION_X, px)
    send_event(EV_ABS, ABS_MT_POSITION_Y, py)
    report()
    ffi.C.usleep(delay * 1000)
end

-- Touch up
send_event(EV_ABS, ABS_MT_TRACKING_ID, -1)
send_event(EV_KEY, BTN_TOUCH, 0)
send_event(EV_KEY, BTN_TOOL_FINGER, 0)
report()

print(string.format("drag %d,%d -> %d,%d (%d steps)", x1, y1, x2, y2, steps))
