# Kindle KOReader 墨水屏精选应用与插件合集 (kindle-koreader-app)

[![GitHub License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Kindle%20%7C%20KOReader-black.svg)](https://koreader.rocks/)

专为 Amazon Kindle 墨水屏生态量身打造的精选应用与扩展插件仓库。解决传统应用在电子墨水屏（E-ink）上“刷新闪烁拖影”、“触控按键过小不易按”、“屏幕利用率低”等痛点，提供极致舒适从容的墨水屏人机交互体验。

---

## 🌟 包含模块一览

### 1. 🎮 方块战争 (Tetris) - 墨水屏全屏大视野定制版
> 路径：[`plugins/tetris.koplugin/`](plugins/tetris.koplugin/)

专为 Kindle 600×800（及以上）电子纸深度重构的俄罗斯方块插件：
- **80% 极限游戏视野**：横向占据屏幕整整 80.0%（480px 宽度），告别传统小窗口。
- **1:1 绝对正方形网格（16列 × 24行）**：共 384 格大棋盘，方块外观小巧精致、比例严格对称，彻底消除拉伸变形。
- **纯手势盲操体验**：
  - **点棋盘任意处 / 上划**：顺时针旋转方块。
  - **左右划屏**：左右平移方块。
  - **下滑 / 屏幕双击**：直坠速降到底并锁定。
  - **轻触暂存框**：换块暂存（Hold）。
- **护眼恒定下落速度（杜绝拖影）**：
  - 默认采用从容护眼的 **1.80 秒 / 格** 恒定下落速度，绝不随关卡变快。方块下落速度严格适配墨水屏物理刷新速率，彻底消灭动画重影与残影异形。
  - 右侧看板内置**速度切换卡**，轻触即可在 `1.8s` / `2.4s` / `1.4s` / `1.0s` 之间随意切换。
- **AI 智能观战模式**：
  - 内置基于启发式评估函数的 AI 自动规划引擎，支持一键开启 AI 自主游玩与演示，随时轻触切换回手动接管。
- **消行计分与最高分持久化**：
  - 支持单行、双行、三行与 Tetris 四行复合消除奖励，记录并自动保存历史最高分至存储。

![俄罗斯方块实机效果图](docs/screenshots/tetris_preview.png)

---

### 2. 📊 智谱 GLM 大模型额度看板 (GLM Usage)
> 包含两套运行模式：
> - KOReader 工具插件：[`plugins/glmusage.koplugin/`](plugins/glmusage.koplugin/)
> - KUAL 原生扩展：[`extensions/glm_usage/`](extensions/glm_usage/)

随时随地在 Kindle 上便捷掌握智谱 AI（GLM）API 用量消耗：
- **HS256 签名动态认证**：无需外部中转服务，Kindle 本地利用 `openssl` 或 Python 动态生成 JWT 鉴权凭据直接与智谱开放平台通信。
- **多维度配额全景监控**：
  - **5 小时滑动窗口**：当前用量比例、剩余 Token / 额度、下次重置时间。
  - **每周自然周期配额**：本周累计消耗、剩余额度、配额重置倒计时。
  - **重置券状态**：实时统计可用团队重置券剩余张数。
- **双运行形态**：
  - **KOReader 内部运行**：通过顶部工具栏“智谱 GLM 用量查询”一键弹出文字看板查看。
  - **KUAL 原生桌面运行**：基于 `fbink` 硬件加速直接刷新到墨水屏全屏，呈现精美的字符进度条卡片看板。

```text
   【 智谱 GLM 看板 】
──────────────
套餐：团队编程套餐

【 5小时滑动配额 】
状态：充足健康
进度：[□□□□□] 0%
已用：0 / 15000

【 每周自然配额 】
状态：已用完 (达上限)
进度：[■■■■■] 100%
已用：66018 / 66000
礼券：剩余 3 张重置券

──────────────
更新：14:15 (已刷新)
```

---

## 📂 项目目录结构

```text
kindle-koreader-app/
├── LICENSE                    # MIT 开源协议
├── README.md                  # 详细使用与说明文档
├── docs/
│   └── screenshots/           # 实机运行效果截图
├── plugins/
│   ├── tetris.koplugin/       # 俄罗斯方块 KOReader 插件
│   │   ├── _meta.lua          # 插件元信息
│   │   ├── main.lua           # 菜单入口注册
│   │   └── tetrisdialog.lua   # 游戏主逻辑、UI 渲染与手势引擎
│   └── glmusage.koplugin/     # GLM 用量 KOReader 插件
│       ├── _meta.lua          # 插件元信息
│       └── main.lua           # 菜单与展示浮层
└── extensions/
    └── glm_usage/             # GLM 用量 KUAL 扩展
        ├── menu.json          # KUAL 扩展配置
        ├── glm_config.env.example # API 密钥配置模板
        └── bin/
            ├── query.sh       # 联网请求与 JWT 签名生成核心脚本
            ├── format_dashboard.lua # 看板数据格式化与进度条计算
            ├── glm_query.py   # Python 版完整查询引擎
            ├── run.sh         # KUAL 启动入口
            └── config_key.sh  # 屏幕提示引导脚本
```

---

## 🚀 安装部署指南

### 前置要求
- 已越狱的 Kindle 设备（如 Paperwhite 2/3/4、Voyage、Oasis、Basic 等）。
- 设备已安装 [KOReader](https://koreader.rocks/)。
- 若需使用桌面看板，建议已安装 [KUAL](https://www.mobileread.com/forums/showthread.php?t=203380)。

---

### 方法一：通过 SSH / SCP 快速安装（推荐）

将 Kindle 连接至同一 Wi-Fi，开启 KOReader 内置的 SSH 服务器（默认端口 `2222`，用户 `root`）：

```bash
# 克隆本仓库
git clone https://github.com/weibaohui/kindle-koreader-app.git
cd kindle-koreader-app

# 替换为你的 Kindle 实际 IP
KINDLE_IP="192.168.0.99"
KINDLE_PORT="2222"

# 1. 安装俄罗斯方块插件
scp -P $KINDLE_PORT -r plugins/tetris.koplugin root@$KINDLE_IP:/mnt/us/koreader/plugins/

# 2. 安装 GLM 用量 KOReader 插件
scp -P $KINDLE_PORT -r plugins/glmusage.koplugin root@$KINDLE_IP:/mnt/us/koreader/plugins/

# 3. 安装 GLM 用量 KUAL 扩展
scp -P $KINDLE_PORT -r extensions/glm_usage root@$KINDLE_IP:/mnt/us/extensions/
```

---

### 方法二：通过 USB 数据线安装

1. 用数据线将 Kindle 连接到电脑，打开弹出的 Kindle 磁盘目录。
2. 复制 `plugins/tetris.koplugin` 到 `koreader/plugins/` 目录。
3. 复制 `plugins/glmusage.koplugin` 到 `koreader/plugins/` 目录。
4. 复制 `extensions/glm_usage` 到 `extensions/` 目录。
5. 安全弹出磁盘。

---

## ⚙️ 配置指南

### 配置智谱 GLM API Key

在 Kindle 设备上的 `/mnt/us/extensions/glm_usage/` 目录下创建配置文件：

#### 方式 A：通过 `glm_config.env` 文件配置（推荐）
复制模板文件并填入 API Key：
```bash
ssh -p 2222 root@<Kindle_IP>
cd /mnt/us/extensions/glm_usage
cp glm_config.env.example glm_config.env
vi glm_config.env
```
填入您的配置：
```bash
API_KEY="your_api_key_id.your_api_key_secret"
ORG="可选组织ID"
PROJ="可选项目ID"
```

#### 方式 B：直接写入 `api_key.txt` 单行文件
```bash
ssh -p 2222 root@<Kindle_IP> 'echo "your_api_key_here" > /mnt/us/extensions/glm_usage/api_key.txt'
```

---

## 🎮 使用与操作

### 俄罗斯方块
1. 打开 KOReader，点击顶部工具栏中的 **工具 (扳手与螺丝刀图标)**。
2. 点击 **“方块战争 (俄罗斯方块)”** 即可启动。
3. **操作要领**：
   - 绝大多数操作可通过划屏与轻触盲操完成。
   - 双击屏幕任意处可立即让方块下落到底。
   - 轻触棋盘任意空白处即可使方块顺时针旋转。
   - 右侧“速度”卡片可随时轻触微调下落节奏。

### GLM 额度用量看板
- **KOReader 内部**：顶部工具栏 -> 更多工具 -> **智谱 GLM 用量查询**。
- **KUAL 菜单**：打开 KUAL 书本 -> 点击 **GLM 用量监控** -> **刷新并查看 GLM 用量**。

---

## 📄 开源许可证

本项目基于 [MIT 许可证](LICENSE) 开源，欢迎提交 Issue 与 Pull Request 共同完善！
