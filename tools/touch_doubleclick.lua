--[[--
双击注入脚本：在 Kindle 触摸总线 /dev/input/event1 上模拟连续两次点击。

用法:
  LD_LIBRARY_PATH=/mnt/us/koreader/libs \
    /mnt/us/koreader/luajit /mnt/us/scripts/touch_doubleclick.lua <x> <y> [gap_ms]
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

local x = tonumber(arg[1]) or 300
local y = tonumber(arg[2]) or 400
local gap = tonumber(arg[3]) or 150

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

local function tap()
    send_event(EV_ABS, ABS_MT_TRACKING_ID, 0)
    send_event(EV_ABS, ABS_MT_POSITION_X, x)
    send_event(EV_ABS, ABS_MT_POSITION_Y, y)
    send_event(EV_KEY, BTN_TOUCH, 1)
    send_event(EV_KEY, BTN_TOOL_FINGER, 1)
    report()
    ffi.C.usleep(60000) -- 按住 60ms
    send_event(EV_ABS, ABS_MT_TRACKING_ID, -1)
    send_event(EV_KEY, BTN_TOUCH, 0)
    send_event(EV_KEY, BTN_TOOL_FINGER, 0)
    report()
end

tap()
ffi.C.usleep(gap * 1000)
tap()

print(string.format("double click %d,%d (gap %dms)", x, y, gap))
