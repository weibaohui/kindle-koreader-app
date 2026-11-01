#!/usr/bin/env bash
# krapi 双份副本一致性检查
#
# krapi 的 HTTP 接口实现**归属 skill** `kindle-screen-automation`
# （scripts/krapi/），因为它属于"设备自动化工具链"而不是"墨水屏应用"。
# 仓库里 tools/krapi/ 保留一份镜像，方便直接 clone 仓库的人部署。
#
# 两份内容必须完全一致，否则会出现"改了 skill 但设备上跑的还是旧版"。
# 用法：tools/krapi/sync_check.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="${KRAPI_SKILL_DIR:-$HOME/.agents/skills/kindle-screen-automation}"
REPO_DIR="$REPO/tools/krapi"
SKILL_DIR="$SKILL/scripts/krapi"

if [ ! -d "$SKILL_DIR" ]; then
    echo "⚠️  找不到 skill 里的 krapi：$SKILL_DIR" >&2
    echo "   可以用 KRAPI_SKILL_DIR=<路径> 指定其它位置。" >&2
    exit 2
fi

fail=0
for f in server.lua start.sh stop.sh emergency.sh install.sh krapi.sh; do
    a="$REPO_DIR/$f"
    b="$SKILL_DIR/$f"
    if [ ! -f "$a" ]; then
        echo "✗ 仓库缺少 $f"
        fail=1
        continue
    fi
    if [ ! -f "$b" ]; then
        echo "✗ skill 缺少 $f"
        fail=1
        continue
    fi
    if diff -q "$a" "$b" >/dev/null 2>&1; then
        echo "✓ $f 一致"
    else
        echo "✗ $f 不一致："
        diff -u "$a" "$b" | head -20
        fail=1
    fi
done

if [ "$fail" -eq 0 ]; then
    echo
    echo "两份 krapi 副本一致。"
else
    echo
    echo "两份 krapi 副本已经漂移，请同步后再提交。"
fi
exit $fail
