# 《方块战争》长按加速下滑 —— 设计与验证

> 版本：v1.0 ｜ 目标设备：Amazon Kindle Basic（第 7 代 / 2014，机型代号 KT2，设备码 C6）(600×800, 16 级灰度，**无前光**)
> 涉及文件：`plugins/tetris.koplugin/tetrisdialog.lua`
> 关联文档：[`docs/BREAKOUT_PLAN.md`](BREAKOUT_PLAN.md)（打砖块方案，其中已同步收录本文的两个引擎级坑）

---

## 一、需求

给《方块战争》（俄罗斯方块）加上**按住屏幕加速下滑**：按住不放，方块加速下坠；松手立刻恢复原本从容的常速。

设计前提（沿用本项目既有的墨水屏约束）：

- 常速是 **1.80 秒/格** 的护眼节奏，绝不能为了"加速"而改动常速档位；
- 加速必须**可感知**，但也不能快到看不清方块；
- 加速期间**不能靠全屏刷新硬扛** —— 墨水屏整屏刷新要几百毫秒，会把节奏直接拖死；
- 原本的**长按暂存换块**不能被加速抢走。

---

## 二、交互设计：长按手势按区域分流

KOReader 的 `hold` 手势本身只带坐标，**没有任何"区域"语义**。要同时支持"长按加速"和"长按换块"，只能自己按坐标把长按拆成若干区域，分别绑定不同处理函数。

| 触摸区 | 屏幕坐标 | 长按行为 |
|---|---|---|
| `tetris_hold_accel_main` | x 0–492，y 0–800（主棋盘区） | **加速下滑** |
| `tetris_hold_accel_side_top` | x 492–600，y 0–136（NEXT 预览区） | **加速下滑** |
| `tetris_hold_accel_side_bottom` | x 492–600，y 216–800（看板其余部分） | **加速下滑** |
| `tetris_hold_swap` | x 492–596，y 136–216（暂存换块面板） | **暂存换块**（保持原功能） |
| `tetris_hold_release` | 全屏 | **抬手 → 恢复常速** |

要点：

1. **`hold` 与 `hold_release` 必须成对注册**。KOReader 的手势检测器在抬手时单独发一个 `hold_release` 事件；只注册 `hold` 而不注册 `hold_release`，加速状态就永远退不掉（会一直加速直到退出游戏）。
2. **`hold_release` 要铺满全屏**。手指按下后在棋盘区、抬手时可能已经滑到别的区域，若抬起区不在注册范围内，加速就关不掉。
3. **手势名严格匹配**。设备端 `GestureRange:match()` 是 `gs.ges ~= self.ges` 的严格比较，所以 `hold` 区域不会被 `hold_release` 误命中，反之亦然。
4. 长按的**识别延迟是 500ms**（`HOLD_INTERVAL_MS`），按住后的前 0.5 秒仍是常速，这是引擎行为，无法规避。

### 视觉反馈

加速期间右侧速度卡把速度数值换成**黑底反白的「加速中」**，让玩家一眼确认"我正按着"。加速结束后自动切回当前速度数值（如 `1.8s`）。

---

## 三、加速参数与真机实测

| 项 | 值 | 说明 |
|---|---|---|
| 常速下落间隔 | `1.80` 秒/格 | 速度档可在 `1.8s / 2.4s / 1.4s / 1.0s` 间切换 |
| 加速下落间隔 | `0.10` 秒/格 | `ACCEL_DROP_DELAY` |
| **实测加速速率** | **9.45 格/秒** | 6 秒长按下落 **52 格**（扣除 500ms 长按识别延迟后 52 / 5.5s） |
| 加速倍率 | **≈ 18 倍** | 相对 1.8s/格的常速 |
| 残影 | **无** | 真机截图核对：加速下落后棋盘干净，无灰影拖尾 |

### 为什么选 0.10 秒

定时器只是下限，真正的瓶颈是**面板刷新**。实测两个候选值：

| `ACCEL_DROP_DELAY` | 理论速率 | 实测速率 | 达成度 | 结论 |
|---|---|---|---|---|
| 0.15s | 6.67 格/秒 | 6.36 格/秒 | 95% | 定时器跟得上，但"砸下去"的感觉偏温和 |
| **0.10s** | 10.0 格/秒 | **9.45 格/秒** | 94% | 达成度与 0.15s 相当，说明刷新还有余量，取更快的档 |

加速期间**只刷新方块所在列带**（约 120×60px）而不是全屏，这是 0.10s 能跑通的前提。刷新面积小一个数量级，定时器才不会被墨水屏的整屏刷新卡住。

---

## 四、实现要点

```lua
-- 加速时只刷列带，而不是全屏
function TetrisDialog:refreshPieceBand(py_old, py_new)
    -- 取方块 4 格所占的列范围 → 算出上下边界 → setDirty 只推这块
end
```

- `softDrop()` 里根据 `self.accel` 决定走列带刷新还是全屏刷新；
- `scheduleNextDrop()` 根据 `self.accel` 决定下一次定时器的间隔（`0.10` 或当前速度档）；
- `onHold` 置位 `self.accel` 并立刻重排定时器（不用等当前这一轮走完）；
- `onHoldRelease` 清位并重排回常速；
- `startNewGame()` 里复位 `self.accel`，避免重开后残留加速状态。

---

## 五、复盘：两个 KOReader 引擎级的坑

这两个坑**只看代码发现不了**，且都不报错，必须上机 + 打日志才能暴露。

### 坑一：`UIManager:scheduleIn()` 没有返回值

设备端 `frontend/ui/uimanager.lua:335`：

```lua
function UIManager:scheduleIn(seconds, action, ...)
    local when = time.now() + time.s(seconds)
    self:schedule(when, action, ...)     -- ← 没有 return
end
```

而 `UIManager:unschedule(action)` 是按 `队列项.action == action` 匹配的。于是这段"看起来正确"的写法：

```lua
self.timer_action = UIManager:scheduleIn(delay, function() ... end)
```

会让 `self.timer_action` **恒为 nil**，`stopDropTimer()` 里的 `unschedule` **一次都没执行过**。

**在《方块战争》里的实际后果**：定时器链数 = 外部调用 `scheduleNextDrop()` 的次数（重开 / 切换速度 / 长按 / 抬手各 +1），每条链都按同一间隔下落，**下落速率被链数倍乘，而且玩得越久越快**。

> 实测对照（同样 6 秒长按）：
> - 修复前（3 条链）：下落 **87 格** ≈ 15.8 格/秒（且当时还叠着逐 tick 调试日志的开销）
> - 修复后（1 条链）：下落 **52 格** ≈ 9.45 格/秒

**修法**（两个插件已同步修正）：

```lua
local drop_timer
drop_timer = function() ... end
self.timer_action = drop_timer          -- 自己留住函数引用
UIManager:scheduleIn(delay, drop_timer)
```

### 坑二：自定义 `onGesture` 不转发 = 所有触摸区都是死代码

设备端 `InputContainer:onGesture`（`frontend/ui/widget/container/inputcontainer.lua:259`）是**唯一**会遍历 `registerTouchZones` 注册的 `_ordered_touch_zones` 的入口：

```lua
function InputContainer:onGesture(ev)
    for _, tzone in ipairs(self._ordered_touch_zones) do
        if tzone.gs_range:match(ev) and tzone.handler(ev) then return true end
    end
    for name, gsseq in pairs(self.ges_events) do ... end
end
```

《方块战争》原本自己重写了 `onGesture` 做手工分支分发（tap / swipe / hold / double_tap），**没有转发给 `InputContainer.onGesture`** —— 于是 `registerTouchZones` 注册的所有触摸区**从来没有被触发过**。

对"长按=暂存换块"这种单区域功能来说，触摸区失效并不会暴露问题（手工分发里的 `hold` 分支照样能用）。但要做"长按加速 vs 长按换块"这种**按区域分流**，触摸区就是唯一实现手段 —— 一旦不转发，**分区彻底失效且毫无报错**，而且 `hold_release` 根本没人接，加速状态永远退不掉。

**修法**：

```lua
function TetrisDialog:onGesture(ev)
    InputContainer.onGesture(self, ev)
    return true   -- 吞掉全部手势，避免冒泡到书页/文件管理器
end
```

---

## 六、验收清单（全部真机通过）

**功能**
- ✅ 长按主棋盘区 → 加速下滑，速度卡显示黑底反白「加速中」
- ✅ 长按右侧 NEXT 区 / 看板其余区域 → 同样加速
- ✅ **长按右侧「暂存换块」面板 → 仍是换块**，不触发加速（区域分流生效）
- ✅ 轻触「暂存换块」面板 → 仍是换块
- ✅ 抬手 → 立刻恢复常速，「加速中」指示器消失
- ✅ 重开新局 → 加速状态被复位

**加速倍率**
- ✅ 6 秒长按下落 **52 格** = **9.45 格/秒** ≈ 常速的 18 倍
- ✅ 常速未被改动：1.80 秒/格（速度档 1.8/2.4/1.4/1.0 照常）

**回归（加速功能不得破坏原有操作）**
- ✅ 点棋盘任意处 → 顺时针旋转（`Tap on board (200, 400) -> rotatePiece!`）
- ✅ 左右划屏 → 平移（`Classified as RIGHT`）
- ✅ 双击 → 直坠到底（`onDoubleTap event -> hardDrop`）
- ✅ 轻触速度卡 → 切换速度档（`Switched speed to 2.4s`）
- ✅ 轻触顶栏暂停 / 重开 / 退出

**墨水屏专项**
- ✅ 加速下落时棋盘**无残影拖尾**（真机截图核对）
- ✅ 加速期间只刷新列带，不触发全屏黑闪

**回归联动**
- ✅ 打砖块插件同步修正了同一个定时器 bug（`scheduleTick` 同样改为自留函数引用）

---

## 七、真机验证方法

```bash
# 部署（软部署：覆盖文件即可生效，无需重启 KOReader）
scp -P 2222 plugins/tetris.koplugin/tetrisdialog.lua \
  root@192.168.0.99:/mnt/us/koreader/plugins/tetris.koplugin/tetrisdialog.lua

# 打开《方块战争》：退出 → 工具菜单 → 方块战争
./tools/kindle_tap.sh 565 22; ./tools/kindle_tap.sh 180 60
./tools/kindle_tap.sh 180 28; ./tools/kindle_tap.sh 120 75

# 重开归零后长按 6 秒（不要在按住期间截图，会打断触控序列）
ssh -p 2222 root@192.168.0.99 "LD_LIBRARY_PATH=/mnt/us/koreader/libs \
  /mnt/us/koreader/luajit /mnt/us/scripts/touch_click.lua 445 22; sleep 2; \
  /mnt/us/koreader/luajit /mnt/us/scripts/touch_hold.lua 200 400 6000"

# 截图读分数：分数 = 每下落 1 格 +1，直接换算速率
./tools/kindle_screenshot.sh /tmp/x.png

# 读日志
ssh -p 2222 root@192.168.0.99 'grep -a "TetrisDialog" /mnt/us/koreader/crash.log | tail -12'
```

> **坑：截图会打断触控注入序列**。按住期间截图会让 `hold_release` 丢失（看起来像功能 bug，其实是 `/usr/sbin/screenshot` 干扰了输入）。要观察加速中的画面，用后台长按 + 并发截图，并**连拍 3 帧交叉核对** —— 墨水屏截图很容易抓到"撕裂帧"（半新半旧的画面），单张截图不能作为渲染 bug 的证据。
