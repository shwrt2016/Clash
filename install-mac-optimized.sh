#!/usr/bin/env bash
#
# Clash Claude SG Optimized
# 适用环境：macOS + Clash Verge Rev
#
# 功能：
# - Claude 全量相关域名走 SG-Team，其它流量保留订阅原策略
# - 腾讯图片域名置顶直连，避免订阅广告规则误拦截微信资源
# - 中国出口检测域名置顶直连，避免海外 CDN 导致检测结果失真
# - 国内网站优先直连，绕过订阅中的国内广告拦截规则
# - 国内域名走国内 DNS，国外域名走 Cloudflare，Claude DNS 强制走 SG-Team
# - 国内 DNS 使用基于 IP 的加密 DoH，避免解析器域名超时
# - 启动 DNS 使用基于 IP 的 Cloudflare DoH，不发送明文 DNS
# - GEO 数据自动更新，更新间隔为 72 小时
# - 清理 Claude 相关脏 hosts、旧规则和冲突 DNS 策略
# - 保留企业域名、自定义 DNS 和其它非 Claude 配置
# - 私密备份现有脚本，不修改运行时 clash-verge.yaml
#
# 默认遇到非空的订阅后置脚本会停止，避免误覆盖：
#   ./install-mac-optimized.sh --force-profile-script
#

set -euo pipefail
umask 077

SCRIPT_VERSION="2.7.0"
FORCE_PROFILE_SCRIPT=false
NON_INTERACTIVE=false
SKIP_RUNNING_CHECK=false
VERIFY_ONLY=false
ROOT="$(cd "$(dirname "$0")" && pwd)"
SELF_CHECK="$ROOT/self-check.sh"

usage() {
  cat <<'EOF'
用法：
  ./install-mac-optimized.sh [选项]

选项：
  --force-profile-script  备份并替换当前订阅的后置脚本
  --non-interactive       从环境变量读取代理参数
  --skip-running-check    跳过 Clash Verge 运行状态检查
  --verify                验证运行配置和 Claude 实际出口
  -h, --help              显示帮助

非交互环境变量：
  SG_SERVER
  SG_PORT
  SG_USERNAME
  SG_PASSWORD
  SG_SKIP_CERT_VERIFY     true 或 false，默认 false
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-profile-script)
      FORCE_PROFILE_SCRIPT=true
      ;;
    --non-interactive)
      NON_INTERACTIVE=true
      ;;
    --skip-running-check)
      SKIP_RUNNING_CHECK=true
      ;;
    --verify)
      VERIFY_ONLY=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "错误：未知参数 $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "错误：此脚本仅适用于 macOS。" >&2
  exit 1
fi

if [[ ! -x "$SELF_CHECK" ]]; then
  echo "错误：缺少可执行的自检脚本 $SELF_CHECK" >&2
  echo "请完整下载仓库，并执行 chmod +x self-check.sh。" >&2
  exit 1
fi

if [[ "$VERIFY_ONLY" == true ]]; then
  if [[ "$SKIP_RUNNING_CHECK" == true ]]; then
    exec "$SELF_CHECK" --skip-running-check
  fi
  exec "$SELF_CHECK"
fi

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

VERGE_DIR="$(find_verge_dir || true)"
if [[ -z "$VERGE_DIR" ]]; then
  echo "错误：未找到 Clash Verge 配置目录。" >&2
  echo "请先安装并启动一次 Clash Verge Rev。" >&2
  exit 1
fi

PROFILES_YAML="$VERGE_DIR/profiles.yaml"
PROFILES_DIR="$VERGE_DIR/profiles"
VERGE_YAML="$VERGE_DIR/verge.yaml"
if [[ ! -f "$PROFILES_YAML" || ! -d "$PROFILES_DIR" ]]; then
  echo "错误：Clash Verge 配置不完整，缺少 profiles.yaml 或 profiles 目录。" >&2
  exit 1
fi

if [[ "$SKIP_RUNNING_CHECK" != true ]] &&
  pgrep -f '/Clash Verge\.app/Contents/MacOS/(clash-verge|verge-mihomo)' >/dev/null 2>&1
then
  echo "错误：Clash Verge 正在运行。" >&2
  echo "请完全退出 Clash Verge 后重新执行，避免配置被程序覆盖。" >&2
  exit 3
fi

item_field() {
  local uid="$1"
  local field="$2"
  awk -v target_uid="$uid" -v target_field="$field" '
    $0 == "- uid: " target_uid {
      inside = 1
      next
    }
    inside && /^- uid:/ {
      exit
    }
    inside {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (index(line, target_field ":") == 1) {
        sub("^[^:]+:[[:space:]]*", "", line)
        print line
        exit
      }
    }
  ' "$PROFILES_YAML"
}

CURRENT_UID="$(awk '/^current:[[:space:]]*/ { print $2; exit }' "$PROFILES_YAML")"
GLOBAL_SCRIPT_FILE="$(item_field "Script" "file")"

if [[ -z "$GLOBAL_SCRIPT_FILE" ]]; then
  echo "错误：profiles.yaml 中未找到全局脚本项 uid=Script。" >&2
  echo "请先在 Clash Verge 中创建一次全局扩展脚本，然后重试。" >&2
  exit 1
fi

GLOBAL_SCRIPT_PATH="$PROFILES_DIR/$GLOBAL_SCRIPT_FILE"
PROFILE_SCRIPT_UID=""
PROFILE_SCRIPT_FILE=""
PROFILE_SCRIPT_PATH=""

if [[ -n "$CURRENT_UID" ]]; then
  PROFILE_SCRIPT_UID="$(item_field "$CURRENT_UID" "script")"
fi
if [[ -n "$PROFILE_SCRIPT_UID" ]]; then
  PROFILE_SCRIPT_FILE="$(item_field "$PROFILE_SCRIPT_UID" "file")"
fi
if [[ -n "$PROFILE_SCRIPT_FILE" ]]; then
  PROFILE_SCRIPT_PATH="$PROFILES_DIR/$PROFILE_SCRIPT_FILE"
fi

is_optimized_script() {
  local path="$1"
  [[ -f "$path" ]] && grep -q "Clash Claude SG Optimized" "$path"
}

is_noop_script() {
  local path="$1"
  local compact
  if [[ ! -f "$path" || ! -s "$path" ]]; then
    return 0
  fi
  compact="$(
    awk '!/^[[:space:]]*\/\//' "$path" |
      tr -d '[:space:]'
  )"
  case "$compact" in
    "functionmain(config){returnconfig;}"|\
    "functionmain(config,profileName){returnconfig;}"|\
    "functionmain(config,_name){returnconfig;}")
      return 0
      ;;
  esac
  return 1
}

# 所有破坏性操作前完成检查，避免半安装。
if [[ -n "$PROFILE_SCRIPT_PATH" ]] &&
  [[ "$PROFILE_SCRIPT_PATH" != "$GLOBAL_SCRIPT_PATH" ]] &&
  ! is_noop_script "$PROFILE_SCRIPT_PATH" &&
  ! is_optimized_script "$PROFILE_SCRIPT_PATH" &&
  [[ "$FORCE_PROFILE_SCRIPT" != true ]]
then
  echo "检测到当前订阅存在非空后置脚本：" >&2
  echo "  $PROFILE_SCRIPT_PATH" >&2
  echo "它会在全局脚本之后运行，可能覆盖 Claude 配置。" >&2
  echo "请先人工检查，确认可替换后执行：" >&2
  echo "  $0 --force-profile-script" >&2
  exit 2
fi

read_credentials() {
  local input=""

  if [[ "$NON_INTERACTIVE" == true ]]; then
    : "${SG_SERVER:?非交互模式缺少 SG_SERVER}"
    : "${SG_PORT:?非交互模式缺少 SG_PORT}"
    : "${SG_USERNAME:?非交互模式缺少 SG_USERNAME}"
    : "${SG_PASSWORD:?非交互模式缺少 SG_PASSWORD}"
    SG_SKIP_CERT_VERIFY="${SG_SKIP_CERT_VERIFY:-false}"
    return
  fi

  if [[ -z "${SG_SERVER:-}" ]]; then
    read -r -p "SG 代理服务器域名或 IP: " SG_SERVER
  fi
  if [[ -z "${SG_PORT:-}" ]]; then
    read -r -p "SG 代理端口: " SG_PORT
  fi
  if [[ -z "${SG_USERNAME:-}" ]]; then
    read -r -p "SG 代理用户名: " SG_USERNAME
  fi
  if [[ -z "${SG_PASSWORD:-}" ]]; then
    read -r -s -p "SG 代理密码（输入时不显示）: " SG_PASSWORD
    echo
  fi
  if [[ -z "${SG_SKIP_CERT_VERIFY:-}" ]]; then
    read -r -p "是否跳过 TLS 证书校验？[y/N]: " input
    case "$input" in
      y|Y|yes|YES)
        SG_SKIP_CERT_VERIFY=true
        ;;
      *)
        SG_SKIP_CERT_VERIFY=false
        ;;
    esac
  fi
}

read_credentials

if [[ -z "${SG_SERVER:-}" || "$SG_SERVER" =~ [[:space:]] ]]; then
  echo "错误：SG_SERVER 不能为空或包含空白字符。" >&2
  exit 1
fi
if [[ ! "${SG_PORT:-}" =~ ^[0-9]+$ ]] ||
  (( SG_PORT < 1 || SG_PORT > 65535 ))
then
  echo "错误：SG_PORT 必须是 1～65535 的整数。" >&2
  exit 1
fi
if [[ -z "${SG_USERNAME:-}" || -z "${SG_PASSWORD:-}" ]]; then
  echo "错误：用户名和密码不能为空。" >&2
  exit 1
fi
case "${SG_SKIP_CERT_VERIFY:-false}" in
  true|false)
    ;;
  *)
    echo "错误：SG_SKIP_CERT_VERIFY 只能是 true 或 false。" >&2
    exit 1
    ;;
esac

to_hex() {
  LC_ALL=C od -An -v -tx1 | tr -d ' \n'
}

SERVER_HEX="$(printf '%s' "$SG_SERVER" | to_hex)"
USERNAME_HEX="$(printf '%s' "$SG_USERNAME" | to_hex)"
PASSWORD_HEX="$(printf '%s' "$SG_PASSWORD" | to_hex)"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clash-claude-sg.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
TEMPLATE_PATH="$TEMP_DIR/Script.template.js"
GENERATED_SCRIPT="$TEMP_DIR/Script.js"

cat > "$TEMPLATE_PATH" <<'JAVASCRIPT'
/**
 * Clash Claude SG Optimized
 *
 * 激进全覆盖模式：
 * - 腾讯图片域名置顶直连，避免订阅广告规则误拦截微信资源
 * - 中国出口检测域名置顶直连，避免海外 CDN 导致检测结果失真
 * - 国内网站优先直连，绕过订阅中的国内广告拦截规则
 * - Claude/Anthropic 核心、认证、CDN、监控和第三方端点走 SG-Team
 * - 国内域名走国内 DNS，国外域名走 Cloudflare，Claude DNS 强制走 SG-Team
 * - 国内 DNS 使用基于 IP 的加密 DoH，避免解析器域名超时
 * - 启动 DNS 使用基于 IP 的 Cloudflare DoH，不发送明文 DNS
 * - GEO 数据自动更新，更新间隔为 72 小时
 * - NTP 保持原规则，不尝试通过不支持 UDP 的 HTTP 代理
 */

const scriptVersion = "2.7.0";
const proxyName = "SG-Team";

function decodeHexUtf8(hex) {
  let encoded = "";
  for (let index = 0; index < hex.length; index += 2) {
    encoded += `%${hex.slice(index, index + 2)}`;
  }
  return decodeURIComponent(encoded);
}

const proxy = {
  name: proxyName,
  type: "http",
  server: decodeHexUtf8("__SG_SERVER_HEX__"),
  port: __SG_PORT__,
  username: decodeHexUtf8("__SG_USERNAME_HEX__"),
  password: decodeHexUtf8("__SG_PASSWORD_HEX__"),
  tls: true,
  udp: false,
  "skip-cert-verify": __SG_SKIP_CERT_VERIFY__,
};

const cfDns = [
  "https://1.1.1.1/dns-query#RULES",
  "https://1.0.0.1/dns-query#RULES",
];
const claudeCfDns = [
  `https://1.1.1.1/dns-query#${proxyName}`,
  `https://1.0.0.1/dns-query#${proxyName}`,
];
const bootstrapDns = [
  "https://1.1.1.1/dns-query",
  "https://1.0.0.1/dns-query",
];
const cnDns = [
  "https://223.5.5.5/dns-query#DIRECT",
  "https://1.12.12.12/dns-query#DIRECT",
];

const coreSuffixDomains = [
  "anthropic.com",
  "claude.ai",
  "claude.com",
  "clau.de",
  "claudemcpclient.com",
  "claudemcpcontent.com",
  "claudeusercontent.com",
];

const sharedSuffixDomains = [
  "sentry.io",
  "statsigapi.net",
  "datadoghq.com",
  "intercom.io",
  "intercomcdn.com",
];

const exactDomains = [
  "servd-anthropic-website.b-cdn.net",
  "anthropic.com.cdn.cloudflare.net",
  "anthropic.auth0.com",
  "anthropic-com.ghost.io",
  "browser-intake-us5-datadoghq.com",
  "cdn.usefathom.com",
];

const domainKeywords = ["datadog", "sift", "sentry"];
const processNames = ["Claude", "Claude Helper", "claude"];
const suffixDomains = [...coreSuffixDomains, ...sharedSuffixDomains];
const ipv4Cidrs = ["160.79.104.0/21"];
const ipv6Cidrs = ["2607:6bc0::/32"];
const asns = ["399358"];
const priorityDirectRules = [
  "DOMAIN-SUFFIX,qlogo.cn,DIRECT",
  "DOMAIN-SUFFIX,qpic.cn,DIRECT",
  "DOMAIN-SUFFIX,gtimg.cn,DIRECT",
  "DOMAIN-SUFFIX,ip138.com,DIRECT",
  "DOMAIN-SUFFIX,ip.cn,DIRECT",
];
const domesticDirectRules = [
  "GEOSITE,CN,DIRECT",
  "GEOIP,CN,DIRECT",
];

const dnsPolicyKeys = [
  ...suffixDomains.map((domain) => `+.${domain}`),
  ...exactDomains,
  "geosite:anthropic",
];

const fakeIpFilters = [
  ...suffixDomains.map((domain) => `+.${domain}`),
  ...exactDomains,
];

const generatedRejectFragments = [
  ...suffixDomains,
  ...exactDomains,
  ...ipv4Cidrs,
  "geosite,anthropic",
  ...processNames.map((name) => `process-name,${name.toLowerCase()}`),
];

function normalizeDomainPattern(value) {
  let normalized = String(value).trim().toLowerCase();
  if (normalized.startsWith("+.") || normalized.startsWith("*.")) {
    normalized = normalized.slice(2);
  }
  return normalized;
}

function matchesManagedDomain(value) {
  const domain = normalizeDomainPattern(value);
  return (
    suffixDomains.some(
      (suffix) => domain === suffix || domain.endsWith(`.${suffix}`)
    ) || exactDomains.includes(domain)
  );
}

function isManagedDnsPolicy(key) {
  const normalized = String(key).trim().toLowerCase();
  return normalized === "geosite:anthropic" || matchesManagedDomain(normalized);
}

function isManagedHostKey(key) {
  return matchesManagedDomain(key);
}

function isManagedFakeIpFilter(item) {
  return matchesManagedDomain(item);
}

function isGeneratedRule(rule) {
  const text = String(rule).trim().toLowerCase();
  const target = proxyName.toLowerCase();
  if (
    priorityDirectRules.some((item) => text === item.toLowerCase()) ||
    domesticDirectRules.some((item) => text === item.toLowerCase())
  ) {
    return true;
  }
  if (text.endsWith(`,${target}`) || text.includes(`,${target},`)) {
    return true;
  }
  return (
    text.startsWith("and,") &&
    text.endsWith(",reject") &&
    generatedRejectFragments.some((fragment) =>
      text.includes(fragment.toLowerCase())
    )
  );
}

function unique(items) {
  return Array.from(new Set(items));
}

function applyDns(config) {
  config.dns =
    config.dns && typeof config.dns === "object" ? config.dns : {};

  const oldPolicy =
    config.dns["nameserver-policy"] &&
    typeof config.dns["nameserver-policy"] === "object"
      ? config.dns["nameserver-policy"]
      : {};
  const policy = {};

  Object.keys(oldPolicy).forEach((key) => {
    if (!isManagedDnsPolicy(key)) {
      policy[key] = oldPolicy[key];
    }
  });

  // 三层 DNS：国内直连、国外按规则、Claude 强制走 SG-Team。
  policy["geosite:cn"] = cnDns.slice();
  policy["geosite:geolocation-!cn"] = cfDns.slice();
  dnsPolicyKeys.forEach((key) => {
    policy[key] = claudeCfDns.slice();
  });

  const oldFilters = Array.isArray(config.dns["fake-ip-filter"])
    ? config.dns["fake-ip-filter"]
    : [];
  const retainedFilters = oldFilters.filter(
    (item) => !isManagedFakeIpFilter(item)
  );

  config.dns.enable = true;
  config.dns.ipv6 = false;
  config.dns["enhanced-mode"] = "fake-ip";
  config.dns["fake-ip-range"] =
    config.dns["fake-ip-range"] || "198.18.0.1/16";
  config.dns["fake-ip-filter"] = unique([
    ...retainedFilters,
    ...fakeIpFilters,
  ]);
  config.dns.nameserver = cfDns.slice();
  config.dns["default-nameserver"] = bootstrapDns.slice();
  config.dns["direct-nameserver"] = cnDns.slice();
  config.dns["direct-nameserver-follow-policy"] = false;
  config.dns["proxy-server-nameserver"] = [
    ...cnDns,
    "tls://223.5.5.5#DIRECT",
  ];
  config.dns["nameserver-policy"] = policy;
  config.dns.fallback = [];
  delete config.dns["fallback-filter"];
  config.dns["prefer-h3"] = false;
  config.dns["respect-rules"] = true;
  config.dns["use-hosts"] = true;
  config.dns["use-system-hosts"] = false;
}

function cleanHosts(config) {
  if (
    !config.hosts ||
    typeof config.hosts !== "object" ||
    Array.isArray(config.hosts)
  ) {
    return;
  }
  Object.keys(config.hosts).forEach((key) => {
    if (isManagedHostKey(key)) {
      delete config.hosts[key];
    }
  });
}

function buildRules() {
  const processUdpRejectRules = processNames.map(
    (name) => `AND,((PROCESS-NAME,${name}),(NETWORK,udp)),REJECT`
  );
  const domainUdpRejectRules = [
    ...suffixDomains.map(
      (domain) =>
        `AND,((DOMAIN-SUFFIX,${domain}),(NETWORK,udp)),REJECT`
    ),
    ...exactDomains.map(
      (domain) => `AND,((DOMAIN,${domain}),(NETWORK,udp)),REJECT`
    ),
    "AND,((GEOSITE,anthropic),(NETWORK,udp)),REJECT",
    ...ipv4Cidrs.map(
      (cidr) => `AND,((IP-CIDR,${cidr}),(NETWORK,udp)),REJECT`
    ),
  ];

  return [
    ...priorityDirectRules,
    ...processUdpRejectRules,
    ...domainUdpRejectRules,
    ...processNames.map((name) => `PROCESS-NAME,${name},${proxyName}`),
    ...suffixDomains.map(
      (domain) => `DOMAIN-SUFFIX,${domain},${proxyName}`
    ),
    ...exactDomains.map((domain) => `DOMAIN,${domain},${proxyName}`),
    ...domainKeywords.map(
      (keyword) => `DOMAIN-KEYWORD,${keyword},${proxyName}`
    ),
    `GEOSITE,anthropic,${proxyName}`,
    ...ipv4Cidrs.map(
      (cidr) => `IP-CIDR,${cidr},${proxyName},no-resolve`
    ),
    ...ipv6Cidrs.map(
      (cidr) => `IP-CIDR6,${cidr},${proxyName},no-resolve`
    ),
    ...asns.map((asn) => `IP-ASN,${asn},${proxyName},no-resolve`),
    ...domesticDirectRules,
  ];
}

function main(config, _profileName) {
  config["geo-auto-update"] = true;
  config["geo-update-interval"] = 72;

  config.proxies = Array.isArray(config.proxies)
    ? config.proxies.filter(
        (item) => item && item.name !== proxyName
      )
    : [];
  config.proxies.push(proxy);

  applyDns(config);
  cleanHosts(config);

  const oldRules = Array.isArray(config.rules) ? config.rules : [];
  const retainedRules = oldRules.filter((rule) => !isGeneratedRule(rule));
  config.rules = [...buildRules(), ...retainedRules];

  config.sniffer =
    config.sniffer && typeof config.sniffer === "object"
      ? config.sniffer
      : {};
  config.sniffer.enable = true;
  config.sniffer["force-dns-mapping"] = true;
  config.sniffer["parse-pure-ip"] = true;

  config.ipv6 = false;
  return config;
}
JAVASCRIPT

sed \
  -e "s/__SG_SERVER_HEX__/$SERVER_HEX/g" \
  -e "s/__SG_PORT__/$SG_PORT/g" \
  -e "s/__SG_USERNAME_HEX__/$USERNAME_HEX/g" \
  -e "s/__SG_PASSWORD_HEX__/$PASSWORD_HEX/g" \
  -e "s/__SG_SKIP_CERT_VERIFY__/$SG_SKIP_CERT_VERIFY/g" \
  "$TEMPLATE_PATH" > "$GENERATED_SCRIPT"
chmod 600 "$GENERATED_SCRIPT"

if command -v node >/dev/null 2>&1; then
  node --check "$GENERATED_SCRIPT"
fi

STAMP="$(date '+%Y%m%d-%H%M%S')-$$"
BACKUP_ROOT="$VERGE_DIR/claude-sg-backups"
BACKUP_DIR="$BACKUP_ROOT/$STAMP"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_ROOT" "$BACKUP_DIR"

backup_file() {
  local source="$1"
  local target_name="$2"
  if [[ -f "$source" ]]; then
    cp -p "$source" "$BACKUP_DIR/$target_name"
    chmod 600 "$BACKUP_DIR/$target_name"
  fi
}

backup_file "$GLOBAL_SCRIPT_PATH" "Script.js"
backup_file "$PROFILES_YAML" "profiles.yaml"
backup_file "$VERGE_YAML" "verge.yaml"
if [[ -n "$PROFILE_SCRIPT_PATH" ]] &&
  [[ "$PROFILE_SCRIPT_PATH" != "$GLOBAL_SCRIPT_PATH" ]]
then
  backup_file "$PROFILE_SCRIPT_PATH" "$PROFILE_SCRIPT_FILE"
fi

GLOBAL_SCRIPT_EXISTED=false
PROFILE_SCRIPT_EXISTED=false
VERGE_YAML_EXISTED=false
if [[ -f "$GLOBAL_SCRIPT_PATH" ]]; then
  GLOBAL_SCRIPT_EXISTED=true
  cp -p "$GLOBAL_SCRIPT_PATH" "$TEMP_DIR/global-script.before"
fi
if [[ -n "$PROFILE_SCRIPT_PATH" ]] &&
  [[ "$PROFILE_SCRIPT_PATH" != "$GLOBAL_SCRIPT_PATH" ]] &&
  [[ -f "$PROFILE_SCRIPT_PATH" ]]
then
  PROFILE_SCRIPT_EXISTED=true
  cp -p "$PROFILE_SCRIPT_PATH" "$TEMP_DIR/profile-script.before"
fi
if [[ -f "$VERGE_YAML" ]]; then
  VERGE_YAML_EXISTED=true
  cp -p "$VERGE_YAML" "$TEMP_DIR/verge.before"
fi

restore_target() {
  local existed="$1"
  local snapshot="$2"
  local target="$3"

  if [[ "$existed" == true ]]; then
    cp -p "$snapshot" "$target"
  else
    rm -f "$target"
  fi
}

rollback_installation() {
  local failed=false

  restore_target \
    "$GLOBAL_SCRIPT_EXISTED" \
    "$TEMP_DIR/global-script.before" \
    "$GLOBAL_SCRIPT_PATH" || failed=true
  if [[ -n "$PROFILE_SCRIPT_PATH" ]] &&
    [[ "$PROFILE_SCRIPT_PATH" != "$GLOBAL_SCRIPT_PATH" ]]
  then
    restore_target \
      "$PROFILE_SCRIPT_EXISTED" \
      "$TEMP_DIR/profile-script.before" \
      "$PROFILE_SCRIPT_PATH" || failed=true
  fi
  if [[ "$VERGE_YAML_EXISTED" == true ]]; then
    restore_target true "$TEMP_DIR/verge.before" "$VERGE_YAML" || failed=true
  fi

  if [[ "$failed" == true ]]; then
    echo "错误：自动恢复不完整，请从私密备份手工恢复：$BACKUP_DIR" >&2
    return 1
  fi
  echo "安装后自检失败，已恢复安装前配置。" >&2
}

install -m 600 "$GENERATED_SCRIPT" "$GLOBAL_SCRIPT_PATH"
if [[ -n "$PROFILE_SCRIPT_PATH" ]] &&
  [[ "$PROFILE_SCRIPT_PATH" != "$GLOBAL_SCRIPT_PATH" ]]
then
  install -m 600 "$GENERATED_SCRIPT" "$PROFILE_SCRIPT_PATH"
fi

# 关闭 GUI DNS 覆盖，让增强脚本成为唯一 DNS 配置源，避免 dns_config.yaml 脏配置回写。
if [[ -f "$VERGE_YAML" ]]; then
  VERGE_TEMP="$TEMP_DIR/verge.yaml"
  awk '
    BEGIN {
      replaced = 0
    }
    /^enable_dns_settings:/ {
      print "enable_dns_settings: false"
      replaced = 1
      next
    }
    {
      print
    }
    END {
      if (!replaced) {
        print "enable_dns_settings: false"
      }
    }
  ' "$VERGE_YAML" > "$VERGE_TEMP"
  install -m 600 "$VERGE_TEMP" "$VERGE_YAML"
fi

SELF_CHECK_ARGS=(
  --post-install
  --expected-script "$GENERATED_SCRIPT"
  --global-script "$GLOBAL_SCRIPT_PATH"
)
if [[ -n "$PROFILE_SCRIPT_PATH" ]] &&
  [[ "$PROFILE_SCRIPT_PATH" != "$GLOBAL_SCRIPT_PATH" ]]
then
  SELF_CHECK_ARGS+=(--profile-script "$PROFILE_SCRIPT_PATH")
fi
if [[ -f "$VERGE_YAML" ]]; then
  SELF_CHECK_ARGS+=(--verge-yaml "$VERGE_YAML")
fi

if ! "$SELF_CHECK" "${SELF_CHECK_ARGS[@]}"; then
  rollback_installation || true
  exit 4
fi

echo "安装完成：Clash Claude SG Optimized v$SCRIPT_VERSION"
echo "全局脚本：$GLOBAL_SCRIPT_PATH"
if [[ -n "$PROFILE_SCRIPT_PATH" ]] &&
  [[ "$PROFILE_SCRIPT_PATH" != "$GLOBAL_SCRIPT_PATH" ]]
then
  echo "订阅后置脚本：$PROFILE_SCRIPT_PATH"
fi
echo "私密备份：$BACKUP_DIR"
echo
echo "下一步："
echo "1. 启动 Clash Verge，保持 Rule 模式并开启 TUN。"
echo "2. DNS 设置由增强脚本接管，GUI 的 DNS 覆盖应保持关闭。"
echo "3. 在系统网络设置中关闭 IPv6，避免 TUN 外 IPv6 泄露。"
echo "4. 重新加载订阅后运行 ./self-check.sh 检查实际配置和出口。"
