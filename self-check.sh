#!/usr/bin/env bash

set -euo pipefail

MODE="runtime"
EXPECTED_SCRIPT=""
GLOBAL_SCRIPT=""
PROFILE_SCRIPT=""
VERGE_YAML=""
SKIP_RUNNING_CHECK=false

usage() {
  cat <<'EOF'
用法：
  ./self-check.sh
  ./self-check.sh --post-install --expected-script PATH --global-script PATH \
    [--profile-script PATH] [--verge-yaml PATH]

选项：
  --post-install        检查安装文件内容、权限和 DNS 开关
  --skip-running-check  跳过 Clash Verge 运行状态检查
  -h, --help            显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --post-install)
      MODE="post-install"
      ;;
    --expected-script|--global-script|--profile-script|--verge-yaml)
      option="$1"
      shift
      if [[ $# -eq 0 ]]; then
        echo "错误：$option 缺少路径。" >&2
        exit 2
      fi
      case "$option" in
        --expected-script) EXPECTED_SCRIPT="$1" ;;
        --global-script) GLOBAL_SCRIPT="$1" ;;
        --profile-script) PROFILE_SCRIPT="$1" ;;
        --verge-yaml) VERGE_YAML="$1" ;;
      esac
      ;;
    --skip-running-check)
      SKIP_RUNNING_CHECK=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "错误：未知参数 $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

pass_count=0
total_count=0

check_pass() {
  total_count=$((total_count + 1))
  pass_count=$((pass_count + 1))
  echo "✅ $1"
}

check_fail() {
  total_count=$((total_count + 1))
  echo "❌ $1"
}

finish_checks() {
  local label="$1"
  echo
  echo "${label}：${pass_count}/${total_count}"
  if [[ "$pass_count" -eq "$total_count" ]]; then
    echo "${label}通过。"
    return 0
  fi
  echo "${label}未通过。"
  return 1
}

check_script_file() {
  local label="$1"
  local path="$2"

  if [[ -f "$path" ]] && cmp -s "$EXPECTED_SCRIPT" "$path"; then
    check_pass "${label}内容一致"
  else
    check_fail "${label}内容一致"
  fi

  if [[ -f "$path" ]] && [[ "$(stat -f '%Lp' "$path" 2>/dev/null || true)" == "600" ]]; then
    check_pass "${label}权限为 600"
  else
    check_fail "${label}权限为 600"
  fi
}

run_post_install_checks() {
  if [[ -z "$EXPECTED_SCRIPT" || -z "$GLOBAL_SCRIPT" ]]; then
    echo "错误：--post-install 必须提供 --expected-script 和 --global-script。" >&2
    return 2
  fi
  if [[ ! -f "$EXPECTED_SCRIPT" ]]; then
    echo "错误：预期脚本不存在。" >&2
    return 2
  fi

  echo "Clash Claude SG 安装文件自检"
  echo
  check_script_file "全局脚本" "$GLOBAL_SCRIPT"
  if [[ -n "$PROFILE_SCRIPT" ]]; then
    check_script_file "订阅后置脚本" "$PROFILE_SCRIPT"
  fi

  if [[ -n "$VERGE_YAML" ]]; then
    if [[ -f "$VERGE_YAML" ]] &&
      grep -Eq '^enable_dns_settings:[[:space:]]*false[[:space:]]*$' "$VERGE_YAML"
    then
      check_pass "GUI DNS 覆盖已关闭"
    else
      check_fail "GUI DNS 覆盖已关闭"
    fi
  fi

  finish_checks "安装文件自检"
}

find_verge_dir() {
  local candidate
  for candidate in \
    "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev" \
    "$HOME/Library/Application Support/io.github.clash-verge.clash-verge"
  do
    if [[ -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

run_runtime_checks() {
  local verge_dir=""
  local runtime_yaml=""
  local mixed_port=""
  local trace=""
  local location=""
  local other_trace=""

  verge_dir="$(find_verge_dir || true)"
  if [[ -z "$verge_dir" ]]; then
    echo "错误：未找到 Clash Verge 配置目录。" >&2
    return 1
  fi
  runtime_yaml="$verge_dir/clash-verge.yaml"
  if [[ ! -f "$runtime_yaml" ]]; then
    echo "错误：未找到运行配置 $runtime_yaml" >&2
    echo "请先启动 Clash Verge 并重新加载当前订阅。" >&2
    return 1
  fi
  if [[ "$SKIP_RUNNING_CHECK" != true ]] &&
    ! pgrep -f '/Clash Verge\.app/Contents/MacOS/(clash-verge|verge-mihomo)' >/dev/null 2>&1
  then
    echo "错误：Clash Verge 未运行，请启动并重新加载订阅后再自检。" >&2
    return 1
  fi

  echo "Clash Claude SG 运行自检"
  echo

  if grep -Fq "DOMAIN-SUFFIX,claude.ai,SG-Team" "$runtime_yaml"; then
    check_pass "Claude 路由规则已加载"
  else
    check_fail "Claude 路由规则已加载"
  fi

  if awk '
    /^rules:/ { inside = 1; next }
    inside && /^-/ {
      count++
      expected[1] = "- DOMAIN-SUFFIX,qlogo.cn,DIRECT"
      expected[2] = "- DOMAIN-SUFFIX,qpic.cn,DIRECT"
      expected[3] = "- DOMAIN-SUFFIX,gtimg.cn,DIRECT"
      if (count <= 3 && $0 != expected[count]) invalid = 1
      if (count == 3) exit
    }
    END { exit count >= 3 && !invalid ? 0 : 1 }
  ' "$runtime_yaml"; then
    check_pass "腾讯图片域名已置顶直连"
  else
    check_fail "腾讯图片域名已置顶直连"
  fi

  if awk '
    /^rules:/ { inside = 1; next }
    inside && /^-/ {
      count++
      if (count == 4 && $0 != "- DOMAIN-SUFFIX,ip138.com,DIRECT") invalid = 1
      if (count == 5 && $0 != "- DOMAIN-SUFFIX,ip.cn,DIRECT") invalid = 1
      if (count == 5) exit
    }
    END { exit count >= 5 && !invalid ? 0 : 1 }
  ' "$runtime_yaml"; then
    check_pass "中国出口检测域名已置顶直连"
  else
    check_fail "中国出口检测域名已置顶直连"
  fi

  if awk '
    /^rules:/ { inside = 1; next }
    inside && /^-/ {
      line++
      if ($0 == "- DOMAIN-SUFFIX,claude.ai,SG-Team") claude = line
      if ($0 == "- GEOSITE,CN,DIRECT") geosite = line
      if ($0 == "- GEOIP,CN,DIRECT") geoip = line
      if (!block && $0 ~ /,🛑 全球拦截$/) block = line
    }
    END {
      valid = claude > 0 && geosite > claude && geoip == geosite + 1 &&
        (!block || geoip < block)
      exit valid ? 0 : 1
    }
  ' "$runtime_yaml"; then
    check_pass "国内网站已优先直连"
  else
    check_fail "国内网站已优先直连"
  fi

  if grep -Fq "+.claude.ai:" "$runtime_yaml" &&
    grep -Fq "https://1.1.1.1/dns-query#SG-Team" "$runtime_yaml"
  then
    check_pass "Claude DNS 使用 Cloudflare DoH 并经过 SG-Team"
  else
    check_fail "Claude DNS 使用 Cloudflare DoH 并经过 SG-Team"
  fi

  if grep -Fq "geosite:geolocation-!cn:" "$runtime_yaml" &&
    grep -Fq "https://1.1.1.1/dns-query#RULES" "$runtime_yaml"
  then
    check_pass "国外域名使用 Cloudflare DoH 并按规则转发"
  else
    check_fail "国外域名使用 Cloudflare DoH 并按规则转发"
  fi

  if grep -Fq "geosite:cn:" "$runtime_yaml" &&
    grep -Fq "https://223.5.5.5/dns-query#DIRECT" "$runtime_yaml" &&
    grep -Fq "https://1.12.12.12/dns-query#DIRECT" "$runtime_yaml"
  then
    check_pass "国内域名使用国内 DoH 并直连"
  else
    check_fail "国内域名使用国内 DoH 并直连"
  fi

  if grep -Eq '^geo-auto-update:[[:space:]]*true[[:space:]]*$' "$runtime_yaml" &&
    grep -Eq '^geo-update-interval:[[:space:]]*72[[:space:]]*$' "$runtime_yaml"
  then
    check_pass "GEO 数据每 72 小时自动更新"
  else
    check_fail "GEO 数据每 72 小时自动更新"
  fi

  if awk '
    BEGIN { encrypted = 1 }
    /^  default-nameserver:/ { inside = 1; next }
    inside && /^  [[:alnum:]_-]+:/ { inside = 0 }
    inside && /^[[:space:]]*-[[:space:]]*/ {
      found = 1
      value = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", value)
      gsub(/["\047]/, "", value)
      if (value !~ /^(https|tls):\/\//) encrypted = 0
    }
    END { exit found && encrypted ? 0 : 1 }
  ' "$runtime_yaml"; then
    check_pass "启动 DNS 已加密"
  else
    check_fail "启动 DNS 已加密"
  fi

  if awk '
    /^hosts:/ { inside = 1; next }
    inside && /^[^[:space:]]/ { inside = 0 }
    inside && tolower($0) ~ /(claude|anthropic|clau\.de)/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$runtime_yaml"; then
    check_fail "未写死 Claude hosts"
  else
    check_pass "未写死 Claude hosts"
  fi

  if grep -Eq "category-ntp.*,SG-Team|category-ntp,SG-Team" "$runtime_yaml"; then
    check_fail "NTP 未错误指向 HTTP 代理"
  else
    check_pass "NTP 未错误指向 HTTP 代理"
  fi

  mixed_port="$(awk '/^mixed-port:[[:space:]]*/ { print $2; exit }' "$runtime_yaml")"
  mixed_port="${mixed_port:-7897}"
  trace="$(
    curl -sS --max-time 10 \
      -x "http://127.0.0.1:${mixed_port}" \
      "https://claude.ai/cdn-cgi/trace" 2>/dev/null || true
  )"
  location="$(printf '%s\n' "$trace" | awk -F= '/^loc=/{ print $2; exit }')"
  printf '%s\n' "$trace" | awk -F= '/^(ip|loc|colo)=/{ print }'
  if [[ "$location" == "SG" ]]; then
    check_pass "Claude 实际出口为新加坡"
  else
    check_fail "Claude 实际出口为新加坡"
  fi

  other_trace="$(
    curl -sS --max-time 10 \
      -x "http://127.0.0.1:${mixed_port}" \
      "https://cloudflare.com/cdn-cgi/trace" 2>/dev/null || true
  )"
  echo "非 Claude 出口（仅供对照）："
  printf '%s\n' "$other_trace" | awk -F= '/^(ip|loc|colo)=/{ print }'

  finish_checks "验证"
}

if [[ "$MODE" == "post-install" ]]; then
  run_post_install_checks
else
  run_runtime_checks
fi
