/**
 * Clash Verge 全局增强脚本（Claude → 新加坡 SG-Team）
 *
 * 目标：
 * 1. 仅 Claude/Anthropic 相关流量走 SG-Team
 * 2. 其它流量保持订阅原有策略（自动选择等）
 * 3. 国内域名走国内 DNS，国外域名走 Cloudflare，Claude DNS 强制走 SG-Team
 * 4. 清理本机脏配置：写死 hosts、旧 Claude 规则、冲突 DNS 策略
 *
 * 使用方式见同目录 install-mac.sh
 */

const proxyName = "SG-Team";
const proxy = {
  name: proxyName,
  type: "http",
  server: "YOUR_SG_SERVER",
  port: 443,
  username: "YOUR_SG_USERNAME",
  password: "YOUR_SG_PASSWORD",
  tls: true,
  "skip-cert-verify": true,
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

// 对照 https://ip.net.coffee/claude/site.html
const managedKeywords = [
  "anthropic",
  "claude.ai",
  "claude.com",
  "clau.de",
  "claudemcp",
  "claudeusercontent",
  "160.79.104",
  "2607:6bc0",
  "399358",
  "servd-anthropic-website",
  "statsigapi",
  "browser-intake-us5-datadoghq",
  "usefathom",
  "category-ntp",
  "sentry.io",
  "intercom.io",
  "intercomcdn.com",
  "ghost.io",
  "auth0.com",
  "domain-keyword,datadog",
  "domain-keyword,sift",
  "domain-keyword,sentry",
  "sg-team",
];

const claudeSuffixDomains = [
  "anthropic.com",
  "claude.ai",
  "claude.com",
  "clau.de",
  "claudemcpclient.com",
  "claudemcpcontent.com",
  "claudeusercontent.com",
  "sentry.io",
  "statsigapi.net",
  "intercom.io",
  "intercomcdn.com",
];

const claudeExactDomains = [
  "servd-anthropic-website.b-cdn.net",
  "anthropic.com.cdn.cloudflare.net",
  "anthropic.auth0.com",
  "anthropic-com.ghost.io",
  "browser-intake-us5-datadoghq.com",
  "cdn.usefathom.com",
];

const claudeKeywords = ["datadog", "sift", "sentry"];

const claudeDnsPolicies = [
  "+.anthropic.com",
  "+.claude.ai",
  "+.claude.com",
  "+.clau.de",
  "+.claudemcpclient.com",
  "+.claudemcpcontent.com",
  "+.claudeusercontent.com",
  "+.sentry.io",
  "+.statsigapi.net",
  "+.intercom.io",
  "+.intercomcdn.com",
  "servd-anthropic-website.b-cdn.net",
  "anthropic.com.cdn.cloudflare.net",
  "anthropic.auth0.com",
  "anthropic-com.ghost.io",
  "browser-intake-us5-datadoghq.com",
  "cdn.usefathom.com",
  "geosite:anthropic",
];

const claudeFakeIpFilter = [
  "claude.com",
  "*.claude.com",
  "clau.de",
  "*.clau.de",
  "claudemcpclient.com",
  "*.claudemcpclient.com",
  "claudemcpcontent.com",
  "*.claudemcpcontent.com",
  "claudeusercontent.com",
  "*.claudeusercontent.com",
  "claude.ai",
  "*.claude.ai",
  "anthropic.com",
  "*.anthropic.com",
  "sentry.io",
  "*.sentry.io",
  "statsigapi.net",
  "*.statsigapi.net",
  "intercom.io",
  "*.intercom.io",
  "intercomcdn.com",
  "*.intercomcdn.com",
  "servd-anthropic-website.b-cdn.net",
  "anthropic.com.cdn.cloudflare.net",
  "anthropic.auth0.com",
  "anthropic-com.ghost.io",
  "browser-intake-us5-datadoghq.com",
  "cdn.usefathom.com",
];

const claudeIpv4Cidrs = ["160.79.104.0/21"];
const claudeIpv6Cidrs = ["2607:6bc0::/32"];
const claudeAsns = ["399358"];
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

function isManagedRule(rule) {
  const text = String(rule).toLowerCase();
  return (
    managedKeywords.some((k) => text.includes(k)) ||
    priorityDirectRules.some((item) => text === item.toLowerCase()) ||
    domesticDirectRules.some((item) => text === item.toLowerCase())
  );
}

function isClaudeHostKey(key) {
  const lower = String(key).toLowerCase();
  return (
    lower.includes("claude") ||
    lower.includes("anthropic") ||
    lower.includes("claudemcp") ||
    lower.includes("clau.de")
  );
}

function uniqueAppend(list, items) {
  const out = (list || []).slice();
  items.forEach((item) => {
    if (out.indexOf(item) === -1) {
      out.push(item);
    }
  });
  return out;
}

/**
 * 清理脏配置并写入 DNS：
 * - 删除写死的 Claude hosts（否则 DNS 策略不生效）
 * - 国内域名使用国内 DoH 并直连
 * - 国外域名使用 Cloudflare DoH 并按 Clash 规则转发
 * - Claude 相关使用 Cloudflare DoH 并强制经过 SG-Team
 */
function applyClaudeDns(config) {
  config.dns = config.dns || {};

  config.dns.enable = true;
  config.dns.ipv6 = false;
  config.dns["use-hosts"] = true;
  config.dns["use-system-hosts"] = false;
  config.dns.nameserver = cfDns.slice();
  config.dns["default-nameserver"] = bootstrapDns.slice();
  config.dns["direct-nameserver"] = cnDns.slice();
  config.dns["proxy-server-nameserver"] = cnDns.concat(["tls://223.5.5.5"]);
  config.dns["respect-rules"] = true;

  const oldPolicy = config.dns["nameserver-policy"] || {};
  const policy = {};

  // 保留明显的本地/内网策略，丢掉会干扰的旧 Claude/国外 CF 策略
  Object.keys(oldPolicy).forEach((key) => {
    const lower = String(key).toLowerCase();
    const keepLocal =
      lower.includes("your-proxy.example.com") ||
      lower.includes("netbird") ||
      lower.includes("wiretrustee") ||
      lower.includes("apple.com") ||
      lower.includes("icloud.com") ||
      lower.includes("lan") ||
      lower.includes("local");
    const dropClaudeOrForeignDns =
      isClaudeHostKey(key) ||
      lower.includes("geolocation-!cn") ||
      lower.includes("geosite:anthropic") ||
      lower.includes("sentry.io") ||
      lower.includes("statsigapi") ||
      lower.includes("intercom") ||
      lower.includes("usefathom") ||
      lower.includes("datadog") ||
      lower.includes("auth0") ||
      lower.includes("ghost.io") ||
      lower.includes("b-cdn.net");
    if (keepLocal && !dropClaudeOrForeignDns) {
      policy[key] = oldPolicy[key];
    }
  });

  policy["geosite:cn"] = cnDns.slice();
  policy["geosite:geolocation-!cn"] = cfDns.slice();
  claudeDnsPolicies.forEach((domain) => {
    policy[domain] = claudeCfDns.slice();
  });
  config.dns["nameserver-policy"] = policy;

  config.dns["fake-ip-filter"] = uniqueAppend(
    config.dns["fake-ip-filter"] || [],
    claudeFakeIpFilter
  );

  // 清掉写死 hosts（最常见脏配置）
  if (config.hosts && typeof config.hosts === "object") {
    Object.keys(config.hosts).forEach((key) => {
      if (isClaudeHostKey(key)) {
        delete config.hosts[key];
      }
    });
  }
}

function ensureSniffer(config) {
  config.sniffer = config.sniffer || {};
  config.sniffer.enable = true;
  config.sniffer["force-dns-mapping"] = true;
  config.sniffer["parse-pure-ip"] = true;
}

function main(config, profileName) {
  config["geo-auto-update"] = true;
  config["geo-update-interval"] = 72;

  // 1. 清理并重建 SG-Team 节点
  config.proxies = (config.proxies || []).filter((p) => p && p.name !== proxyName);
  config.proxies.push(proxy);

  // 2. DNS + 清脏 hosts
  applyClaudeDns(config);

  // 3. 删掉旧 Claude/冲突规则后置顶新规则
  const remainRules = (config.rules || []).filter((rule) => !isManagedRule(rule));

  // HTTP 代理不支持 UDP：先拒 Claude QUIC，避免掉进自动选择
  const udpRejectRules = [
    ...claudeSuffixDomains.map(
      (d) => `AND,((DOMAIN-SUFFIX,${d}),(NETWORK,udp)),REJECT`
    ),
    ...claudeExactDomains.map(
      (d) => `AND,((DOMAIN,${d}),(NETWORK,udp)),REJECT`
    ),
    `AND,((GEOSITE,anthropic),(NETWORK,udp)),REJECT`,
    ...claudeIpv4Cidrs.map(
      (cidr) => `AND,((IP-CIDR,${cidr}),(NETWORK,udp)),REJECT`
    ),
  ];

  const tcpRules = [
    ...claudeSuffixDomains.map((d) => `DOMAIN-SUFFIX,${d},${proxyName}`),
    ...claudeExactDomains.map((d) => `DOMAIN,${d},${proxyName}`),
    ...claudeKeywords.map((k) => `DOMAIN-KEYWORD,${k},${proxyName}`),
    `GEOSITE,anthropic,${proxyName}`,
    `GEOSITE,category-ntp,${proxyName}`,
    ...claudeIpv4Cidrs.map((cidr) => `IP-CIDR,${cidr},${proxyName},no-resolve`),
    ...claudeIpv6Cidrs.map((cidr) => `IP-CIDR6,${cidr},${proxyName},no-resolve`),
    ...claudeAsns.map((asn) => `IP-ASN,${asn},${proxyName},no-resolve`),
  ];

  config.rules = [
    ...priorityDirectRules,
    ...udpRejectRules,
    ...tcpRules,
    ...domesticDirectRules,
    ...remainRules,
  ];

  // 4. 打开嗅探，减少纯 IP 漏网
  ensureSniffer(config);

  // 5. 建议关闭 IPv6（若本机脏配置把它打开了）
  config.ipv6 = false;

  return config;
}
