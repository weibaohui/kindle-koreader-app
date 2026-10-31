#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
GLM 用量查询核心引擎（从 Metalio-E-INK4 C++ 源码移植）
- 支持 HS256 JWT 动态生成
- 查询 getCustomerInfo (获取团队/项目)
- 查询 quota/limit (5小时与每周额度/百分比)
- 查询 customer-package-reset/list (重置次数)
- 格式化输出供 fbink 墨水屏渲染
"""

import sys, os, time, json, hmac, hashlib, base64, urllib.request

CONFIG_FILE = "/mnt/us/extensions/glm_usage/api_key.txt"

def base64url(data):
    if isinstance(data, str):
        data = data.encode('utf-8')
    return base64.urlsafe_b64encode(data).decode('utf-8').rstrip('=')

def make_jwt(api_key):
    if '.' not in api_key:
        return api_key
    key_id, secret = api_key.split('.', 1)
    now = int(time.time())
    
    header = {"alg": "HS256", "sign_type": "SIGN"}
    payload = {
        "api_key": key_id,
        "exp": now + 3600,
        "timestamp": now
    }
    
    signing_input = f"{base64url(json.dumps(header))}.{base64url(json.dumps(payload))}"
    signature = hmac.new(secret.encode('utf-8'), signing_input.encode('utf-8'), hashlib.sha256).digest()
    return f"{signing_input}.{base64url(signature)}"

def http_get(url, headers):
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=12) as resp:
            return json.loads(resp.read().decode('utf-8'))
    except Exception as e:
        return {"error": str(e)}

def format_reset_time(ms):
    if not ms or ms <= 0:
        return "--"
    # UTC+8
    t = time.gmtime(ms / 1000 + 8 * 3600)
    return time.strftime("%m-%d %H:%M", t)

def main():
    if not os.path.exists(CONFIG_FILE):
        print("ERR: 未找到 API Key 文件\n请在 /mnt/us/extensions/glm_usage/api_key.txt 中写入 Key")
        return

    with open(CONFIG_FILE, 'r') as f:
        api_key = f.read().strip()

    if not api_key:
        print("ERR: API Key 为空")
        return

    jwt = make_jwt(api_key)
    base_headers = {
        "Authorization": jwt,
        "Accept": "application/json",
        "User-Agent": "Kindle-GLM/1.0"
    }

    # 1. 发现机构与项目
    info = http_get("https://bigmodel.cn/api/biz/customer/getCustomerInfo", base_headers)
    org = ""
    proj = ""
    try:
        data = info.get("result", {}).get("data", {})
        org = data.get("organization", {}).get("id", "")
        proj = data.get("project", {}).get("id", "")
    except:
        pass

    req_headers = dict(base_headers)
    if org: req_headers["bigmodel-organization"] = org
    if proj: req_headers["bigmodel-project"] = proj

    # 2. 查配额
    quota = http_get("https://open.bigmodel.cn/api/monitor/usage/quota/limit?type=2", req_headers)
    
    # 3. 查重置次数
    resets = http_get("https://open.bigmodel.cn/api/biz/customer-package-reset/list?targetType=TEAM", req_headers)

    if quota.get("code") != 200:
        msg = quota.get("msg", "查询失败")
        print(f"ERR: {msg}")
        return

    q_data = quota.get("data", {})
    level = q_data.get("level", "Standard")
    limits = q_data.get("limits", [])

    w5_pct, w5_rem, w5_reset = -1, -1, -1
    week_pct, week_rem, week_reset = -1, -1, -1
    mcp_used, mcp_total = -1, -1

    for item in limits:
        t = item.get("type")
        if t == "TIME_LIMIT":
            mcp_used = item.get("currentValue", 0)
            mcp_total = item.get("usage", 0)
        elif t in ("TOKENS_LIMIT", "CREDIT_LIMIT"):
            pct = item.get("percentage", 0)
            rem = item.get("remaining", 0)
            res_time = item.get("nextResetTime", 0)
            if w5_reset == -1 or res_time < w5_reset:
                week_pct, week_rem, week_reset = w5_pct, w5_rem, w5_reset
                w5_pct, w5_rem, w5_reset = pct, rem, res_time
            else:
                week_pct, week_rem, week_reset = pct, rem, res_time

    # 重置次数
    r_5h, r_week = 0, 0
    try:
        r_data = resets.get("data", {})
        r_5h = sum(1 for x in r_data.get("fiveHourResets", []) if x.get("available", True))
        r_week = sum(1 for x in r_data.get("weekResets", []) if x.get("available", True))
    except:
        pass

    # 格式化输出
    print(f"OK|{level}|{w5_pct}|{w5_rem}|{format_reset_time(w5_reset)}|{week_pct}|{week_rem}|{format_reset_time(week_reset)}|{r_5h}|{r_week}|{mcp_used}/{mcp_total}")

if __name__ == "__main__":
    main()
