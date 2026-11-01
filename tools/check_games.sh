#!/usr/bin/env bash
# 游戏插件合规体检
#
# 检查项（对齐 docs/design/GAME_PLUGIN_SPEC.md）：
#   1. 目录三件套齐全、main.lua 有 return
#   2. disable_double_tap = true
#   3. 注册了 ges_events（Tap/Hold）并重写 onGesture
#   4. Lua 5.1 语法（用设备上的 luajit 解析，Mac 的 lua 5.5 放行 5.3+ 语法）
#   5. 没有用 COLOR_GRAY_A（设备上不存在，会报错）
#   6. 没有 ipairs(...:gmatch(...))（会把 KOReader 带崩）
#   7. paintTo 铺满全屏底色
#   8. 菜单 key 全局唯一
#
# 用法：tools/check_games.sh [设备IP]
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEV="${1:-192.168.0.99}"
PORT="${KR_SSH_PORT:-2222}"
GAMES=(chess xiangqi go junqi)

fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }
head2() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

echo "静态检查：$REPO"
echo "设备语法检查：$DEV:$PORT"

# ---- 本地静态检查 ----
head2 "本地静态检查"
for g in "${GAMES[@]}"; do
    d="$REPO/plugins/$g.koplugin"
    printf '\033[1m-- %s --\033[0m\n' "$g"

    [ -d "$d" ] || { bad "目录不存在"; continue; }

    n=$(ls "$d"/*.lua 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" = "3" ] && ok "三件套齐全（$n 个 lua 文件）" || bad "lua 文件数=$n（期望 3）"

    if grep -q '^return ' "$d/main.lua"; then
        ok "main.lua 有 return"
    else
        bad "main.lua 缺少 return（加载会失败）"
    fi

    if grep -q 'disable_double_tap' "$d"/*.lua; then
        ok "disable_double_tap 已设置"
    else
        bad "缺少 disable_double_tap = true"
    fi

    if grep -q 'ges_events' "$d"/*.lua; then
        ok "已注册 ges_events"
    else
        bad "缺少 ges_events 注册（插件会完全点不动且不报错）"
    fi

    if grep -q 'function .*:onGesture' "$d"/*.lua; then
        ok "重写了 onGesture"
    else
        bad "缺少 onGesture 重写（事件会冒泡到下层）"
    fi

    if grep -q 'GestureRange:new' "$d"/*.lua; then
        ok "使用了 GestureRange 声明手势"
    else
        bad "缺少 GestureRange:new 声明"
    fi

    if grep -q 'COLOR_GRAY_A' "$d"/*.lua; then
        bad "用了 COLOR_GRAY_A（设备上不存在）"
    else
        ok "未使用 COLOR_GRAY_A"
    fi

    if grep -nE 'ipairs\([^)]*:gmatch' "$d"/*.lua; then
        bad "出现 ipairs(...:gmatch(...))（会带崩 KOReader）"
    else
        ok "无 ipairs(...:gmatch(...))"
    fi

    if grep -q 'paintRect(0,\s*0,\s*self\.W' "$d"/*.lua; then
        ok "paintTo 铺满全屏底色"
    else
        bad "paintTo 可能没有铺满全屏底色（下层会透出来）"
    fi

    # 顶部中文注释
    for f in "$d"/*.lua; do
        head -5 "$f" | grep -q '[一-龥]' || bad "$(basename "$f") 顶部缺中文说明注释"
    done
done

head2 "菜单 key 全局唯一"
keys=$(grep -rhoE 'menu_items\.[a-z_]+' "$REPO"/plugins/*.koplugin/*.lua 2>/dev/null \
        | sed 's/menu_items\.//' | sort | uniq -d)
if [ -z "$keys" ]; then
    ok "全部插件菜单 key 无重复"
else
    bad "重复的菜单 key: $(echo "$keys" | tr '\n' ' ')"
fi

# ---- Lua 5.1 语法检查 ----
# 优先用设备上的 luajit（与真机运行时完全一致）；
# 设备不可达时退回本机 luajit（brew install luajit），同样能查 5.1 语法。
head2 "Lua 5.1 语法检查"
LOCAL_LUAJIT=""
if command -v luajit >/dev/null 2>&1; then
    LOCAL_LUAJIT=$(command -v luajit)
fi

if ssh -p "$PORT" -o ConnectTimeout=8 -o BatchMode=yes root@"$DEV" true 2>/dev/null; then
    tmp=$(mktemp -d)
    for g in "${GAMES[@]}"; do
        d="$REPO/plugins/$g.koplugin"
        [ -d "$d" ] || continue
        mkdir -p "$tmp/$g"
        cp "$d"/*.lua "$tmp/$g/" 2>/dev/null
    done

    # 一次传过去，减少 SSH 往返
    ssh -p "$PORT" root@"$DEV" "rm -rf /tmp/kr_lint && mkdir -p /tmp/kr_lint" 2>/dev/null
    scp -P "$PORT" -q -r "$tmp"/. root@"$DEV":/tmp/kr_lint/ 2>/dev/null

    out=$(ssh -p "$PORT" root@"$DEV" '
  for f in $(find /tmp/kr_lint -name "*.lua" | sort); do
    if /mnt/us/koreader/luajit -e "local f,err=loadfile([[$f]]); if not f then io.stderr:write(tostring(err)) os.exit(1) end" 2>/tmp/kr_lint_err; then
      echo "OK $f"
    else
      echo "FAIL $f : $(cat /tmp/kr_lint_err)"
    fi
  done
  rm -rf /tmp/kr_lint /tmp/kr_lint_err
' 2>&1)

    while IFS= read -r line; do
        case "$line" in
            OK*)   ok "${line#OK }" ;;
            FAIL*) bad "${line#FAIL }" ;;
        esac
    done <<< "$out"

    rm -rf "$tmp"
elif [ -n "$LOCAL_LUAJIT" ]; then
    echo "  (设备不可达，改用本机 luajit: $LOCAL_LUAJIT)"
    for g in "${GAMES[@]}"; do
        d="$REPO/plugins/$g.koplugin"
        [ -d "$d" ] || continue
        for f in "$d"/*.lua; do
            [ -f "$f" ] || continue
            if "$LOCAL_LUAJIT" -bl "$f" /dev/null 2>/tmp/kr_lint_err; then
                ok "${f#$REPO/}"
            else
                bad "${f#$REPO/} : $(cat /tmp/kr_lint_err)"
            fi
        done
    done
    rm -f /tmp/kr_lint_err
else
    echo "  (跳过：设备不可达，本机也没有 luajit，装一个 brew install luajit 即可离线检查)"
fi

echo
if [ "$fail" -eq 0 ]; then
    printf '\033[32m全部检查通过\033[0m\n'
else
    printf '\033[31m%d 项未通过\033[0m\n' "$fail"
fi
exit $fail
