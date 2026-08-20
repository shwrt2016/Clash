#!/usr/bin/env bash
# 验证 Claude→SG、DNS 分流是否生效
set -euo pipefail

MIXED_PORT="${MIXED_PORT:-7897}"
PASS=0
TOTAL=0

check() {
  local name="$1"
  local ok="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$ok" == "1" ]]; then
    echo "✅ $name"
    PASS=$((PASS + 1))
  else
    echo "❌ $name"
  fi
}

echo "========================================"
echo " Claude 配置验证"
echo " 时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo

echo "## DNS 解析"
CLAUDE_IP="$(dig +time=2 +tries=1 @127.0.0.1 claude.ai A +short 2>/dev/null | head -1 || true)"
BAIDU_IP="$(dig +time=2 +tries=1 @127.0.0.1 www.baidu.com A +short 2>/dev/null | head -1 || true)"
echo "claude.ai => ${CLAUDE_IP:-无结果}"
echo "www.baidu.com => ${BAIDU_IP:-无结果}"
if [[ -n "${CLAUDE_IP}" && "${CLAUDE_IP}" != 198.18.* ]]; then
  check "Claude 解析为真实 IP" 1
else
  check "Claude 解析为真实 IP" 0
fi
if [[ "${BAIDU_IP}" == 198.18.* ]]; then
  check "国内站为 fake-ip" 1
else
  check "国内站为 fake-ip（若未开 fake-ip 可忽略）" 0
fi

echo
echo "## Claude 出口"
TRACE="$(curl -s --max-time 8 -x "http://127.0.0.1:${MIXED_PORT}" https://claude.ai/cdn-cgi/trace || true)"
IP="$(echo "$TRACE" | awk -F= '/^ip=/{print $2}')"
LOC="$(echo "$TRACE" | awk -F= '/^loc=/{print $2}')"
COLO="$(echo "$TRACE" | awk -F= '/^colo=/{print $2}')"
echo "ip=${IP:-?} loc=${LOC:-?} colo=${COLO:-?}"
if [[ "$LOC" == "SG" ]]; then
  check "Claude 出口新加坡" 1
else
  check "Claude 出口新加坡" 0
fi

echo
echo "## 非 Claude 出口（可为美国/其它，不要求 SG）"
OTHER="$(curl -s --max-time 8 -x "http://127.0.0.1:${MIXED_PORT}" https://cloudflare.com/cdn-cgi/trace || true)"
echo "$OTHER" | awk -F= '/^(ip|loc|colo)=/{print}'

echo
echo "## 配置文件线索"
VERGE_DIR="${HOME}/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
[[ -d "$VERGE_DIR" ]] || VERGE_DIR="${HOME}/Library/Application Support/io.github.clash-verge.clash-verge"
if [[ -f "$VERGE_DIR/profiles/Script.js" ]]; then
  if grep -q 'SG-Team' "$VERGE_DIR/profiles/Script.js" && grep -q '1.1.1.1' "$VERGE_DIR/profiles/Script.js"; then
    check "全局 Script.js 已安装" 1
  else
    check "全局 Script.js 已安装" 0
  fi
else
  check "全局 Script.js 已安装" 0
fi

if [[ -f "$VERGE_DIR/clash-verge.yaml" ]]; then
  if grep -q 'DOMAIN-SUFFIX,claude.ai,SG-Team' "$VERGE_DIR/clash-verge.yaml"; then
    check "运行配置含 Claude→SG-Team 规则" 1
  else
    check "运行配置含 Claude→SG-Team 规则（需在 Verge 里重新加载订阅）" 0
  fi
  if awk '
    /^rules:/ {
      inside = 1
      next
    }
    inside && /^-/ {
      count++
      if (count == 1 && $0 != "- DOMAIN-SUFFIX,qlogo.cn,DIRECT") {
        invalid = 1
      }
      if (count == 2 && $0 != "- DOMAIN-SUFFIX,qpic.cn,DIRECT") {
        invalid = 1
      }
      if (count == 3 && $0 != "- DOMAIN-SUFFIX,gtimg.cn,DIRECT") {
        invalid = 1
      }
      if (count == 3) {
        exit
      }
    }
    END {
      exit count == 3 && !invalid ? 0 : 1
    }
  ' "$VERGE_DIR/clash-verge.yaml"
  then
    check "腾讯图片域名已置顶直连" 1
  else
    check "腾讯图片域名已置顶直连" 0
  fi
  if awk '
    /^rules:/ {
      inside = 1
      next
    }
    inside && /^-/ {
      count++
      if (count == 4 && $0 != "- DOMAIN-SUFFIX,ip138.com,DIRECT") {
        invalid = 1
      }
      if (count == 5 && $0 != "- DOMAIN-SUFFIX,ip.cn,DIRECT") {
        invalid = 1
      }
      if (count == 5) {
        exit
      }
    }
    END {
      exit count == 5 && !invalid ? 0 : 1
    }
  ' "$VERGE_DIR/clash-verge.yaml"
  then
    check "中国出口检测域名已置顶直连" 1
  else
    check "中国出口检测域名已置顶直连" 0
  fi
  if awk '
    /^rules:/ {
      inside = 1
      next
    }
    inside && /^-/ {
      line++
      if ($0 == "- DOMAIN-SUFFIX,claude.ai,SG-Team") {
        claude_line = line
      }
      if ($0 == "- GEOSITE,CN,DIRECT") {
        geosite_line = line
      }
      if ($0 == "- GEOIP,CN,DIRECT") {
        geoip_line = line
      }
      if (block_line == 0 && $0 ~ /,🛑 全球拦截$/) {
        block_line = line
      }
    }
    END {
      valid = claude_line > 0 &&
        geosite_line > claude_line &&
        geoip_line == geosite_line + 1 &&
        (block_line == 0 || geoip_line < block_line)
      exit valid ? 0 : 1
    }
  ' "$VERGE_DIR/clash-verge.yaml"
  then
    check "国内网站已优先直连" 1
  else
    check "国内网站已优先直连" 0
  fi
  if grep -Eq '^geo-auto-update:[[:space:]]*true[[:space:]]*$' "$VERGE_DIR/clash-verge.yaml" &&
    grep -Eq '^geo-update-interval:[[:space:]]*72[[:space:]]*$' "$VERGE_DIR/clash-verge.yaml"
  then
    check "GEO 数据每 72 小时自动更新" 1
  else
    check "GEO 数据每 72 小时自动更新" 0
  fi
  if awk '
    BEGIN {
      encrypted = 1
    }
    /^  default-nameserver:/ {
      inside = 1
      next
    }
    inside && /^  [[:alnum:]_-]+:/ {
      inside = 0
    }
    inside && /^[[:space:]]*-[[:space:]]*/ {
      found = 1
      value = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", value)
      gsub(/"/, "", value)
      gsub(/\047/, "", value)
      if (value !~ /^(https|tls):\/\//) {
        encrypted = 0
      }
    }
    END {
      exit found && encrypted ? 0 : 1
    }
  ' "$VERGE_DIR/clash-verge.yaml"
  then
    check "启动 DNS 已加密" 1
  else
    check "启动 DNS 已加密" 0
  fi
  if grep -qE '^hosts:|claude\.ai: 160' "$VERGE_DIR/clash-verge.yaml"; then
    # hosts 整段或写死 IP 都算脏
    if grep -q 'claude.ai: 160' "$VERGE_DIR/clash-verge.yaml"; then
      check "无 Claude 写死 hosts" 0
    else
      check "无 Claude 写死 hosts" 1
    fi
  else
    check "无 Claude 写死 hosts" 1
  fi
fi

echo
echo "总分: ${PASS}/${TOTAL}"
if [[ "$PASS" -eq "$TOTAL" ]]; then
  echo "结论: 通过"
  exit 0
fi
echo "结论: 未完全通过。请在 Verge 重新加载订阅/增强脚本后重试。"
echo "网页复查: https://ip.net.coffee/claude/"
exit 1
