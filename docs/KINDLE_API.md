# Kindle 后台 HTTP 控制接口（krapi）—— 设计与真机验证

> **一句话结论：可行，已经跑通了。**
> Kindle 上可以常驻一个真正的 HTTP 服务（独立 LuaJIT 进程 + KOReader 自带的 LuaSocket），
> AI 通过 `http://<kindle>:8099/tap?x=248&y=80` 就能直接点这台墨水屏设备。

---

## 1. 目标与形态

把 Kindle 从"只能 SSH 进去手动敲命令"变成"能通过 HTTP 接口被 AI 或任意程序驱动"：

```text
   AI / 脚本 / Claude / Codex
            │  HTTP (局域网, Bearer Token)
            ▼
   ┌────────────────────────────────────────┐
   │  Kindle (192.168.0.99:8099)            │
   │  ┌──────────────────────────────────┐  │
   │  │ krapi server (独立 luajit 进程)   │  │
   │  │  · HTTP 解析 + JSON               │  │
   │  │  · iptables 看门狗                │  │
   │  └───────────┬──────────────────────┘  │
   │              │ 文件协议                  │
   │  ┌───────────▼──────────────────────┐  │
   │  │ KOReader 进程                      │  │
   │  │  · kr_tap_helper 插件（手势注入）  │  │
   │  │  · 渲染 / 截图                     │  │
   │  └──────────────────────────────────┘  │
   └────────────────────────────────────────┘
```

---

## 2. 为什么服务是"独立进程"而不是 KOReader 插件

一开始的自然想法是写个 KOReader 插件，用插件自带的 `SimpleTCPServer` 起 HTTP。
但独立进程在三个维度上明显更合适：

| 维度 | 独立进程（选定） | KOReader 插件 |
| :--- | :--- | :--- |
| 阻塞风险 | 一个慢客户端最多卡住自己那个连接 | 会卡住整个 UI 线程（阅读器卡死） |
| 生命周期 | KOReader 崩了/退了/重启了，服务还活着 | 跟着 KOReader 一起生死 |
| 能力边界 | 只能"隔空"操作设备 | 能直接摸到 KOReader 内部对象 |

代价是触控动作要跨进程，走文件协议 —— 但这条路**本来就存在且已验证**
（skill `kindle-screen-automation` 的 `kr_tap_helper` 就是这么干的），所以等于白捡。

---

## 3. 五个决定成败的坑（全在这台机上实测踩过）

### 3.1 Kindle 的 iptables INPUT 策略是 `DROP`

这是最大的坑。设备上：

```
Chain INPUT (policy DROP)
ACCEPT tcp -- 0.0.0.0/0 0.0.0.0/0  tcp dpt:2222 ctstate NEW,ESTABLISHED
ACCEPT tcp -- 0.0.0.0/0 0.0.0.0/0  tcp dpt:40317
ACCEPT udp -- 0.0.0.0/0 0.0.0.0/0  tcp dpt:8134
```

**只放行了 2222（SSH）等少数几个端口。** 你在自己机器上 bind 一个 8099，
`netstat` 显示 LISTENING、进程也活着，但**从局域网任何机器都连不上** ——
TCP 连接在到达应用之前就被内核丢了。

连 Amazon 自己的 80 端口也不通（Kindle 压根不提供局域网服务）。

> 实测记录：服务器 bind 成功 → Mac 上 `nc -z` 超时 → 加一行 iptables 规则 → 立刻 `HTTP/1.1 200 OK`。

解法就是照抄越狱放行 SSH 的同一套手法：

```sh
iptables -I INPUT 1 -p tcp --dport 8099 -j ACCEPT
```

⚠️ 但越狱脚本（`jb.sh`）**每次开机都会重建 iptables 链**，我们的规则可能被冲掉。
所以服务里带了一个**看门狗**：每 60 秒 `iptables -C` 检查一次，规则没了就 `-I` 补回。

### 3.2 KOReader 空闲 15 分钟会自动挂起，WiFi 跟着断

`auto_suspend_timeout_seconds` 默认 **900 秒**（归 `autosuspend.koplugin` 管）。
到点 KOReader 挂起 → **WiFi 射频跟着断** → 设备从网络上"消失"。

这就是之前反复"SSH 连不上"的真凶（症状极具误导性：ARP 表里条目还在，但 2222 完全无响应）。

长期后台必须：

```lua
G_reader_settings:saveSetting("auto_suspend_timeout_seconds", -1)  -- -1 = 禁用
```

判定语义在插件源码里写得很清楚：`return self.auto_suspend_timeout_seconds > 0` 才启用。

⚠️ 改这个值要**在 KOReader 启动前**改文件（`settings.reader.lua`）。
autosuspend 插件在 init 时读一次；之后 KOReader 任何一次 `flush()` 都会把内存里的值写回文件，
所以"文件里改成 -1 → 插件读到 -1 → 落盘还是 -1"是自洽的，不会被打回。

### 3.3 Kindle 自己的电源管理照样会把设备拖进深度睡眠

禁用了 KOReader 的挂起还不够，Kindle 原生的 `powerd` 也有自己的空闲计时器，
到点一样会把设备拖进深度睡眠（WiFi 全关）。

越狱自带了现成的对策：

```sh
/etc/rc.d/keep_awake 10    # 每 10 秒给 powerd 喂一个假用户事件，骗过它的计时器
```

这台是 Basic 第 7 代**没有前光**，屏幕一直亮着也不费电，所以没有副作用。

### 3.4 触控注入在 zforce2 上不能走 evdev

往 `/dev/input/event1` 写 `input_event`，`write()` 返回 16 字节（成功），
但**事件进不了输入子系统**（另一个读端抓 3 秒 = 0 个事件）。

可行路径是让 KOReader 里的 `kr_tap_helper` 插件代劳：
合成事件直接喂 `Input:handleTouchEv` → 真 `GestureDetector` → `UIManager:sendEvent`。
krapi 只需要把命令写进 `/tmp/kr_tap_cmd`，等插件在 `/tmp/kr_tap.log` 里写出 `done: <cmd>` 即可确认。

细节（已在 skill 文档里沉淀）：

- **hold 必须"按下立刻送、抬起延后送"** —— hold 靠 `input:setTimeout(slot,"hold",...)`
  这个**真实墙钟定时器**判定，一次性灌完会被判成 tap；
- 事件时间字段是 `{ sec, usec }`（不是 `{tv_sec, tv_usec}`），且要用 **double**；
- `string.gmatch` 返回的是迭代函数，`ipairs(content:gmatch(...))` 会**直接把 KOReader 带崩**。

### 3.5 独立的 `/usr/bin/lua` 装不了 LuaSocket，但 KOReader 的 luajit 可以

设备的 `/usr/bin/lua` 是 PUC **Lua 5.1.4**，加载 KOReader 的 `common/socket/score.so` 会报：

```
undefined symbol: luaL_setfuncs
```

（`luaL_setfuncs` 是 Lua 5.2+ 的 API。）而 KOReader 自带一个 **LuaJIT 可执行文件**
`/mnt/us/koreader/luajit`（350KB），用它就能正常加载：

```sh
cd /mnt/us/koreader
LD_LIBRARY_PATH=/mnt/us/koreader/libs ./luajit /mnt/us/krapi/server.lua --port 8099
```

另外 LuaSocket 3.x 里 **`socket.bind` 是 `socket.tcp()` 对象的方法**，模块级 `socket.bind` 是 nil：

```lua
local srv = socket.tcp()
srv:setoption("reuseaddr", true)
assert(srv:bind("0.0.0.0", 8099))
assert(srv:listen(16))
```

### 3.6 ⚠️ `busybox pkill -f` 会自杀（后台进程一律用 PID 文件管）

**这是本次踩得最隐蔽的一个坑。**

`pkill -f <模式>` 匹配的是**整条命令行**，而"执行 pkill 的那个 shell"的命令行里
往往就含这个模式本身：

```sh
ssh host "pkill -f 'krapi/server.lua'"
# 远端进程是 `sh -c pkill -f 'krapi/server.lua' ...`
# → 它的 cmdline 里含 "krapi/server.lua" → pkill 把它和执行它的 shell 一起杀了
```

**表现**：SSH 会话毫无征兆地断掉（没有任何错误输出），脚本执行到一半凭空消失，
看起来像"设备随机断线"。很容易误判成网络问题。

**对策**：所有后台进程用 **PID 文件**管理 —— `echo $! > x.pid`，之后 `kill $(cat x.pid)`。
本仓库的 `start.sh` / `stop.sh` 都按这个来。

配套的 busybox 细节：

| 工具 | 坑 |
| :--- | :--- |
| `pgrep` / `pkill` | 默认按**进程名**匹配，要匹配整条命令行必须加 `-f`；但加了 `-f` 就有自匹配风险 |
| `grep` | **不支持** `[[:space:]]` 字符类（用普通空格） |
| `ps` | 不支持 `-eo` 组合（用 `ps -o pid,args`）；看不到某些会话外的进程时，改扫 `/proc/*/cmdline` |
| `netstat` | 默认只列 IPv4；`-tln` 只看 LISTEN 状态 |

另外，"上一个实例刚被杀、端口还没让出来"就会报 `address already in use`。
服务里做了 **bind 重试（10 次 × 3 秒）**，启动脚本里也会等 LISTEN 套接字消失再起新的。

---

## 4. API 规格

所有接口都支持 `GET`；触控类也支持 `POST` + JSON body（`{"x":248,"y":80}`）。
**除 `/ping` 外都需要 `X-Api-Token` 头**（或 `?token=` 参数），令牌在
`/mnt/us/krapi/token`，安装时自动生成。

| 方法 | 路径 | 参数 | 说明 |
| :--- | :--- | :--- | :--- |
| GET | `/ping` | — | 存活探测（不需要令牌） |
| GET | `/status` | — | 设备状态：电量、电流、电压、内存、负载、IP、KOReader 是否在线 |
| GET | `/screenshot.png` | — | 当前屏幕 PNG（600×800，灰度）。**取完立即删设备端文件，零残留** |
| GET/POST | `/tap` | `x` `y` | 点按 |
| GET/POST | `/hold` | `x` `y` `ms`（默认 1200） | 长按 |
| GET/POST | `/swipe` | `x1` `y1` `x2` `y2` `ms`（默认 400） | 滑动 |
| GET | `/logs` | `n`（默认 30） | 服务日志尾部 |

返回：

```json
{"ok": true, "cmd": "tap 248 80"}
{"ok": false, "error": "坐标越界（有效范围 x 0-599, y 0-799）"}
```

坐标范围 `x 0-599`、`y 0-799`，越界直接 400。

### 用法

```bash
# 装
./tools/krapi/install.sh 192.168.0.99 8099

# 命令行客户端
./tools/krapi/krapi.sh status
./tools/krapi/krapi.sh shot /tmp/s.png
./tools/krapi/krapi.sh tap 248 80
./tools/krapi/krapi.sh hold 248 80 1500

# 裸 curl
TOKEN=$(ssh -p 2222 root@192.168.0.99 cat /mnt/us/krapi/token)
curl -H "X-Api-Token: $TOKEN" http://192.168.0.99:8099/status
curl -H "X-Api-Token: $TOKEN" http://192.168.0.99:8099/screenshot.png -o /tmp/s.png
```

---

## 5. 开机持久化

越狱在 `/var/local/appreg.db` 里注册了一个开机启动项：

```
handlerId: org.kindlemodding.emergency_launcher
command  : /bin/sh /mnt/us/emergency.sh
```

**这个文件默认不存在**（越狱的"紧急模式"钩子），我们把它建出来当开机 root 钩子：

```sh
# /mnt/us/emergency.sh（设备端，由 kmc.conf 在 framework_ready 时以 root 执行）
sleep 20                                   # 等 Amazon 的启动流程先跑完
sh /mnt/us/krapi/start.sh 8099              # iptables + 禁用挂起 + keep_awake + 起服务
# 兜底：KOReader 没起来就拉起来（触控接口需要它）
pgrep -f reader.lua >/dev/null 2>&1 || (cd /mnt/us/koreader && setsid nohup ./koreader.sh &)
```

删掉 `/mnt/us/emergency.sh` 即可完全撤销，不影响越狱本身。

开机链路全貌：

```
Kindle 开机
  └─ framework_ready
       ├─ appreg: hotfix_launcher   → /var/local/kmc/run_hotfix.sh → 重新拉 jb.sh（越狱自愈）
       └─ appreg: emergency_launcher → /bin/sh /mnt/us/emergency.sh → 我们的 krapi
```

---

## 6. 功耗

实测（600×800 / 16 灰 / WiFi 常开 / e-ink 静止）：

| 状态 | 电流 | 功率 |
| :--- | :--- | :--- |
| KOReader 运行 + WiFi 开（空闲采样中位数） | ~25–68 mA | **~0.1 W** |
| 瞬时峰值（刚做完 SSH/截图等 IO） | ~250 mA | ~0.9 W |
| 电池 | 容量 34–37%（**放电中，未插电**） | — |

结论：**长期后台必须插电**。设备在电池上大概只能撑几小时量级。
这台是 Basic 第 7 代没有前光，屏幕常亮不额外耗电，所以 keep_awake 没有副作用。

---

## 7. 安全模型

- 令牌：16 字节随机 hex，写在 `/mnt/us/krapi/token`（root 专属，`/mnt/us` 上权限 777，注意）。
- 监听 `0.0.0.0` → 局域网内可访问。**只应跑在可信局域网里。**
- **没有暴露任意命令执行接口** —— 这是刻意的。root shell over HTTP 等于把整台设备交出去。
  以后要加 `/exec`，必须加白名单。
- 截屏会暴露屏幕内容（含正在看的书、账号信息）—— 令牌就是这层的唯一防线。
- 想从外网访问：建议在 Mac 侧做一层反向代理（加 TLS + 限流），别把 Kindle 直接暴露到公网。

---

## 8. 卸载 / 回滚

```sh
ssh -p 2222 root@192.168.0.99 \
  'sh /mnt/us/krapi/stop.sh 8099; rm -f /mnt/us/emergency.sh'
```

`stop.sh` 会：停服务、停 keep_awake、撤销 iptables 规则、把 `auto_suspend_timeout_seconds` 恢复成 900。

---

## 9. 真机验证记录

| 验证项 | 结果 |
| :--- | :--- |
| 独立 luajit + LuaSocket bind/listen | ✅ |
| Mac 端 `curl` 拿到 `HTTP/1.1 200 OK` | ✅（加 iptables 规则前是超时） |
| 无令牌访问 | ✅ 返回 401 |
| `/status` 返回电量/电流/内存/负载/KOReader 存活 | ✅（实测 30%、-356mA、KOReader 在线、挂起超时 -1） |
| `/screenshot.png` | ✅ 600×800 PNG，**设备端零残留** |
| `/tap` `/hold` `/swipe` | ✅ 助手日志确认 `done: tap/hold/swipe ...` |
| 坐标越界 | ✅ 400 |
| **端到端确定性验证** | ✅ 通过 API 点打砖块顶栏「暂停」→ 按钮文字变化 317px（暂停→继续）→ 再点恢复 |
| iptables 看门狗自愈 | ✅ 手动删规则 → 60 秒内自动补回（`server.log` 留痕） |
| 连续重启 3 次 | ✅ 全部成功（PID 文件方案） |
| 3 分钟存活观察（18 次采样） | ✅ 每次 HTTP 200 |
| 开机钩子 | ✅ `appreg.db` 注册项确认存在；`emergency.sh` 已部署并手动执行验证 |

> 三个曾经把测试带偏的"假故障"，写在这里免得后人重踩：
>
> 1. **`stdout.log` 是累加的**，里面的 `bind failed` 可能来自几小时前的一次失败 ——
>    判断要看带时间戳的 `server.log`。
> 2. **启动不是瞬时的**：kill 旧实例 + 等端口释放 + 服务自己 bind 重试，总共十几秒。
>    启动后立刻 curl 会拿到 `000`（连接被拒），这不是故障，是没等够。
>    现在 `start.sh` 会一直等到端口真的进入 LISTEN 才返回。
> 3. **端口"被占"往往就是它自己在占** —— 老实例没被杀掉时，新实例必然 bind 失败。
>    查端口归属要扫 `/proc/*/fd` 找 socket inode，不要只看 `netstat`。

---

## 10. 下一步路线图

1. **Mac 侧 MCP server**：把 krapi 包成 MCP tools（`kindle_tap` / `kindle_screenshot` / `kindle_status`），
   Claude / Codex / 本仓库的 AI 就能直接用，不需要手写 curl。
2. **按键接口**：目前只能点/长按/滑，KOReader 的物理键（翻页、返回）还触达不到。
3. **文本输入**：`/type` 往输入框里塞字符串（搜书、填 URL 都用得上）。
4. **/exec 白名单**：只允许一组预定义的只读命令（如 `cat /proc/meminfo`），不做任意 shell。
5. **多设备**：接口本身与设备无关，`install.sh` 加个设备列表就能管多台。
