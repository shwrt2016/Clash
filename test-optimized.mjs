import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import vm from "node:vm";

const packageDir = dirname(fileURLToPath(import.meta.url));
const installerPath = join(packageDir, "install-mac-optimized.sh");

function createFixture() {
  const home = mkdtempSync(join(tmpdir(), "clash-claude-test-"));
  const appDir = join(
    home,
    "Library/Application Support/io.github.clash-verge-rev.clash-verge-rev",
  );
  const profilesDir = join(appDir, "profiles");
  mkdirSync(profilesDir, { recursive: true });

  const profilesYaml = `current: remote-profile
items:
- uid: Script
  type: script
  file: Script.js
- uid: profile-script
  type: script
  file: profile-script.js
- uid: remote-profile
  type: remote
  name: 测试订阅
  file: remote-profile.yaml
  option:
    script: profile-script
`;
  writeFileSync(join(appDir, "profiles.yaml"), profilesYaml);
  writeFileSync(
    join(profilesDir, "Script.js"),
    "function main(config) { config.globalDirty = true; return config; }\n",
  );
  writeFileSync(
    join(profilesDir, "profile-script.js"),
    "function main(config) { config.profileDirty = true; return config; }\n",
  );
  writeFileSync(
    join(appDir, "clash-verge.yaml"),
    "runtime-marker: must-stay-untouched\n",
  );
  writeFileSync(
    join(appDir, "dns_config.yaml"),
    "dns-marker: must-stay-untouched\n",
  );
  writeFileSync(
    join(appDir, "verge.yaml"),
    "enable_dns_settings: true\nenable_tun_mode: true\n",
  );

  return {
    home,
    appDir,
    profilesDir,
    profilesYaml,
    globalScript: join(profilesDir, "Script.js"),
    profileScript: join(profilesDir, "profile-script.js"),
  };
}

function installerEnv(home) {
  return {
    ...process.env,
    HOME: home,
    SG_SERVER: "sg-proxy.example.com",
    SG_PORT: "443",
    SG_USERNAME: "test-user",
    SG_PASSWORD: "test-password",
    SG_SKIP_CERT_VERIFY: "false",
  };
}

function runInstaller(fixture, extraArgs = []) {
  return spawnSync(
    "bash",
    [
      installerPath,
      "--non-interactive",
      "--skip-running-check",
      ...extraArgs,
    ],
    {
      encoding: "utf8",
      env: installerEnv(fixture.home),
    },
  );
}

function loadMain(scriptPath) {
  const source = readFileSync(scriptPath, "utf8");
  const context = { console };
  vm.createContext(context);
  vm.runInContext(`${source}\n;globalThis.__main = main;`, context, {
    filename: scriptPath,
  });
  return {
    main: context.__main,
    source,
  };
}

function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

test("分发文件只用占位符，安装脚本靠环境变量注入账号", () => {
  assert.equal(existsSync(installerPath), true, "尚未生成优化安装脚本");
  const installer = readFileSync(installerPath, "utf8");
  const script = readFileSync(join(packageDir, "Script.js"), "utf8");

  assert.match(installer, /SG_SERVER/);
  assert.match(installer, /SG_PASSWORD/);
  assert.match(script, /YOUR_SG_SERVER/);
  assert.match(script, /YOUR_SG_PASSWORD/);
});

test("新旧验证脚本均检查 GEO 72 小时自动更新", () => {
  const optimizedSource = readFileSync(installerPath, "utf8");
  const legacySource = readFileSync(join(packageDir, "verify.sh"), "utf8");

  for (const source of [optimizedSource, legacySource]) {
    assert.match(source, /geo-auto-update/);
    assert.match(source, /geo-update-interval/);
    assert.match(source, /72/);
  }
});

test("新旧验证脚本均检查启动 DNS 加密", () => {
  const optimizedSource = readFileSync(installerPath, "utf8");
  const legacySource = readFileSync(join(packageDir, "verify.sh"), "utf8");

  for (const source of [optimizedSource, legacySource]) {
    assert.match(source, /default-nameserver/);
    assert.match(source, /启动 DNS 已加密/);
  }
});

test("目录脚本和 DNS 配置实现三层 DNS 出站", () => {
  const { main } = loadMain(join(packageDir, "Script.js"));
  const config = plain(main({ dns: {}, proxies: [], rules: [] }, "目录脚本"));

  assert.equal(config["geo-auto-update"], true);
  assert.equal(config["geo-update-interval"], 72);
  assert.deepEqual(config.dns["default-nameserver"], [
    "https://1.1.1.1/dns-query",
    "https://1.0.0.1/dns-query",
  ]);
  assert.deepEqual(config.dns.nameserver, [
    "https://1.1.1.1/dns-query#RULES",
    "https://1.0.0.1/dns-query#RULES",
  ]);
  assert.deepEqual(config.dns["nameserver-policy"]["geosite:cn"], [
    "https://223.5.5.5/dns-query#DIRECT",
    "https://1.12.12.12/dns-query#DIRECT",
  ]);
  assert.deepEqual(
    config.dns["nameserver-policy"]["geosite:geolocation-!cn"],
    [
      "https://1.1.1.1/dns-query#RULES",
      "https://1.0.0.1/dns-query#RULES",
    ],
  );
  assert.deepEqual(config.dns["nameserver-policy"]["+.claude.ai"], [
    "https://1.1.1.1/dns-query#SG-Team",
    "https://1.0.0.1/dns-query#SG-Team",
  ]);
  assert.deepEqual(config.rules.slice(0, 5), [
    "DOMAIN-SUFFIX,qlogo.cn,DIRECT",
    "DOMAIN-SUFFIX,qpic.cn,DIRECT",
    "DOMAIN-SUFFIX,gtimg.cn,DIRECT",
    "DOMAIN-SUFFIX,ip138.com,DIRECT",
    "DOMAIN-SUFFIX,ip.cn,DIRECT",
  ]);
  assert.equal(
    config.rules.indexOf("GEOSITE,CN,DIRECT") >
      config.rules.indexOf("DOMAIN-SUFFIX,claude.ai,SG-Team"),
    true,
  );
  assert.equal(
    config.rules.indexOf("GEOIP,CN,DIRECT"),
    config.rules.indexOf("GEOSITE,CN,DIRECT") + 1,
  );

  const dnsSource = readFileSync(join(packageDir, "dns_config.yaml"), "utf8");
  assert.match(dnsSource, /https:\/\/223\.5\.5\.5\/dns-query#DIRECT/);
  assert.match(dnsSource, /https:\/\/1\.12\.12\.12\/dns-query#DIRECT/);
  assert.equal(dnsSource.includes("doh.pub"), false);
  assert.equal(dnsSource.includes("dns.alidns.com"), false);
  assert.match(dnsSource, /https:\/\/1\.1\.1\.1\/dns-query#RULES/);
  assert.match(dnsSource, /https:\/\/1\.1\.1\.1\/dns-query#SG-Team/);
});

test("默认拒绝覆盖非空的订阅后置脚本，且不产生部分修改", () => {
  const fixture = createFixture();
  const beforeGlobal = readFileSync(fixture.globalScript, "utf8");
  const beforeProfile = readFileSync(fixture.profileScript, "utf8");

  const result = runInstaller(fixture);

  assert.equal(result.status, 2, `${result.stdout}\n${result.stderr}`);
  assert.equal(readFileSync(fixture.globalScript, "utf8"), beforeGlobal);
  assert.equal(readFileSync(fixture.profileScript, "utf8"), beforeProfile);
  assert.equal(
    readFileSync(join(fixture.appDir, "clash-verge.yaml"), "utf8"),
    "runtime-marker: must-stay-untouched\n",
  );
});

test("验证模式检查运行配置和 Claude 新加坡出口", () => {
  const fixture = createFixture();
  writeFileSync(
    join(fixture.appDir, "clash-verge.yaml"),
    `mixed-port: 7897
geo-auto-update: true
geo-update-interval: 72
dns:
  default-nameserver:
  - 'https://1.1.1.1/dns-query'
  - 'https://1.0.0.1/dns-query'
  nameserver:
  - 'https://1.1.1.1/dns-query#RULES'
  - 'https://1.0.0.1/dns-query#RULES'
  nameserver-policy:
    geosite:cn:
    - 'https://223.5.5.5/dns-query#DIRECT'
    - 'https://1.12.12.12/dns-query#DIRECT'
    geosite:geolocation-!cn:
    - 'https://1.1.1.1/dns-query#RULES'
    - 'https://1.0.0.1/dns-query#RULES'
    +.claude.ai:
    - 'https://1.1.1.1/dns-query#SG-Team'
rules:
- DOMAIN-SUFFIX,qlogo.cn,DIRECT
- DOMAIN-SUFFIX,qpic.cn,DIRECT
- DOMAIN-SUFFIX,gtimg.cn,DIRECT
- DOMAIN-SUFFIX,ip138.com,DIRECT
- DOMAIN-SUFFIX,ip.cn,DIRECT
- DOMAIN-SUFFIX,claude.ai,SG-Team
- GEOSITE,CN,DIRECT
- GEOIP,CN,DIRECT
- DOMAIN-SUFFIX,ad.qq.com,🛑 全球拦截
- MATCH,Auto
`,
  );

  const fakeBin = join(fixture.home, "fake-bin");
  mkdirSync(fakeBin);
  const fakeCurl = join(fakeBin, "curl");
  writeFileSync(
    fakeCurl,
    `#!/usr/bin/env bash
case "$*" in
  *claude.ai/cdn-cgi/trace*)
    printf 'ip=138.75.58.11\\nloc=SG\\ncolo=SIN\\n'
    ;;
  *cloudflare.com/cdn-cgi/trace*)
    printf 'ip=192.0.2.1\\nloc=US\\ncolo=LAX\\n'
    ;;
esac
`,
  );
  chmodSync(fakeCurl, 0o755);

  const result = spawnSync(
    "bash",
    [installerPath, "--verify", "--skip-running-check"],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        HOME: fixture.home,
        PATH: `${fakeBin}:${process.env.PATH}`,
      },
    },
  );

  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /验证通过/);
  assert.match(result.stdout, /GEO 数据每 72 小时自动更新/);
  assert.match(result.stdout, /启动 DNS 已加密/);
  assert.match(result.stdout, /腾讯图片域名已置顶直连/);
  assert.match(result.stdout, /中国出口检测域名已置顶直连/);
  assert.match(result.stdout, /国内网站已优先直连/);
  assert.match(result.stdout, /loc=SG/);
});

test("强制模式私密备份后安装到全局及订阅后置脚本", () => {
  const fixture = createFixture();
  const result = runInstaller(fixture, ["--force-profile-script"]);

  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.equal(result.stdout.includes("test-password"), false);
  assert.equal(result.stderr.includes("test-password"), false);

  const globalSource = readFileSync(fixture.globalScript, "utf8");
  const profileSource = readFileSync(fixture.profileScript, "utf8");
  assert.equal(globalSource, profileSource);
  assert.match(globalSource, /Clash Claude SG Optimized/);
  assert.equal(statSync(fixture.globalScript).mode & 0o777, 0o600);
  assert.equal(statSync(fixture.profileScript).mode & 0o777, 0o600);

  const backupRoot = join(fixture.appDir, "claude-sg-backups");
  assert.equal(existsSync(backupRoot), true);
  assert.equal(statSync(backupRoot).mode & 0o777, 0o700);
  const backups = readdirSync(backupRoot);
  assert.equal(backups.length, 1);
  assert.equal(
    existsSync(join(backupRoot, backups[0], "Script.js")),
    true,
  );
  assert.equal(
    existsSync(join(backupRoot, backups[0], "profile-script.js")),
    true,
  );

  assert.equal(
    readFileSync(join(fixture.appDir, "clash-verge.yaml"), "utf8"),
    "runtime-marker: must-stay-untouched\n",
  );
  assert.equal(
    readFileSync(join(fixture.appDir, "dns_config.yaml"), "utf8"),
    "dns-marker: must-stay-untouched\n",
  );
  assert.equal(
    readFileSync(join(fixture.appDir, "profiles.yaml"), "utf8"),
    fixture.profilesYaml,
  );
  assert.match(
    readFileSync(join(fixture.appDir, "verge.yaml"), "utf8"),
    /enable_dns_settings: false/,
  );
});

test("增强脚本清理 Claude 脏项，同时保留企业配置并保持幂等", () => {
  const fixture = createFixture();
  const install = runInstaller(fixture, ["--force-profile-script"]);
  assert.equal(install.status, 0, `${install.stdout}\n${install.stderr}`);

  const { main } = loadMain(fixture.globalScript);

  const dirtyConfig = {
    ipv6: true,
    hosts: {
      "claude.ai": "1.2.3.4",
      "api.anthropic.com": "1.2.3.5",
      "internal.corp.example": "10.0.0.8",
    },
    dns: {
      enable: true,
      ipv6: true,
      nameserver: ["https://8.8.8.8/dns-query"],
      "nameserver-policy": {
        "+.corp.example": ["tls://10.0.0.53"],
        "+.claude.ai": ["https://8.8.8.8/dns-query"],
        "geosite:geolocation-!cn": ["https://8.8.8.8/dns-query"],
      },
      "fake-ip-filter": [
        "+.corp.example",
        "*.claude.ai",
        "claude.ai",
      ],
    },
    proxies: [
      { name: "Auto-Node", type: "ss" },
      { name: "SG-Team", type: "http", server: "dirty.example.com" },
    ],
    rules: [
      "DOMAIN-SUFFIX,claude.ai,SG-Team",
      "DOMAIN-SUFFIX,claude.ai,US-Node",
      "DOMAIN-SUFFIX,qlogo.cn,DIRECT",
      "DOMAIN-SUFFIX,gu.qlogo.cn,🛑 全球拦截",
      "DOMAIN-SUFFIX,ip138.com,DIRECT",
      "GEOSITE,CN,🎯 全球直连",
      "DOMAIN-SUFFIX,ad.qq.com,🛑 全球拦截",
      "DOMAIN-SUFFIX,corp.example,DIRECT",
      "GEOSITE,category-ntp,DIRECT",
      "MATCH,Auto",
    ],
  };

  const once = plain(main(structuredClone(dirtyConfig), "测试订阅"));
  const twice = plain(main(structuredClone(once), "测试订阅"));

  assert.deepEqual(twice, once, "重复增强必须得到相同结果");
  assert.equal(once.ipv6, false);
  assert.equal(once["geo-auto-update"], true);
  assert.equal(once["geo-update-interval"], 72);
  assert.equal(once.dns.ipv6, false);
  assert.deepEqual(once.dns["default-nameserver"], [
    "https://1.1.1.1/dns-query",
    "https://1.0.0.1/dns-query",
  ]);
  assert.deepEqual(once.dns.nameserver, [
    "https://1.1.1.1/dns-query#RULES",
    "https://1.0.0.1/dns-query#RULES",
  ]);
  assert.deepEqual(once.dns["nameserver-policy"]["+.corp.example"], [
    "tls://10.0.0.53",
  ]);
  assert.deepEqual(once.dns["nameserver-policy"]["geosite:cn"], [
    "https://223.5.5.5/dns-query#DIRECT",
    "https://1.12.12.12/dns-query#DIRECT",
  ]);
  assert.deepEqual(
    once.dns["nameserver-policy"]["+.claude.ai"],
    [
      "https://1.1.1.1/dns-query#SG-Team",
      "https://1.0.0.1/dns-query#SG-Team",
    ],
  );
  assert.deepEqual(
    once.dns["nameserver-policy"]["+.datadoghq.com"],
    [
      "https://1.1.1.1/dns-query#SG-Team",
      "https://1.0.0.1/dns-query#SG-Team",
    ],
  );
  assert.deepEqual(
    once.dns["nameserver-policy"]["geosite:geolocation-!cn"],
    [
      "https://1.1.1.1/dns-query#RULES",
      "https://1.0.0.1/dns-query#RULES",
    ],
  );
  assert.equal("claude.ai" in once.hosts, false);
  assert.equal("api.anthropic.com" in once.hosts, false);
  assert.equal(once.hosts["internal.corp.example"], "10.0.0.8");
  assert.equal(
    once.dns["fake-ip-filter"].filter((item) => item === "+.claude.ai")
      .length,
    1,
  );
  assert.equal(
    once.dns["fake-ip-filter"].some(
      (item) => item === "*.claude.ai" || item === "claude.ai",
    ),
    false,
  );

  const sgProxies = once.proxies.filter((item) => item.name === "SG-Team");
  assert.equal(sgProxies.length, 1);
  assert.equal(sgProxies[0].server, "sg-proxy.example.com");
  assert.equal(sgProxies[0].port, 443);
  assert.equal(sgProxies[0].username, "test-user");
  assert.equal(sgProxies[0].password, "test-password");
  assert.equal(sgProxies[0]["skip-cert-verify"], false);

  assert.equal(
    once.rules.filter(
      (rule) => rule === "DOMAIN-SUFFIX,claude.ai,SG-Team",
    ).length,
    1,
  );
  assert.deepEqual(once.rules.slice(0, 5), [
    "DOMAIN-SUFFIX,qlogo.cn,DIRECT",
    "DOMAIN-SUFFIX,qpic.cn,DIRECT",
    "DOMAIN-SUFFIX,gtimg.cn,DIRECT",
    "DOMAIN-SUFFIX,ip138.com,DIRECT",
    "DOMAIN-SUFFIX,ip.cn,DIRECT",
  ]);
  assert.equal(
    once.rules.filter(
      (rule) => rule === "DOMAIN-SUFFIX,qlogo.cn,DIRECT",
    ).length,
    1,
  );
  assert.equal(
    once.rules.indexOf("DOMAIN-SUFFIX,qlogo.cn,DIRECT") <
      once.rules.indexOf("DOMAIN-SUFFIX,gu.qlogo.cn,🛑 全球拦截"),
    true,
  );
  assert.equal(
    once.rules.filter(
      (rule) => rule === "DOMAIN-SUFFIX,ip138.com,DIRECT",
    ).length,
    1,
  );
  assert.equal(
    once.rules.filter((rule) => rule === "GEOSITE,CN,DIRECT").length,
    1,
  );
  assert.equal(
    once.rules.filter((rule) => rule === "GEOIP,CN,DIRECT").length,
    1,
  );
  assert.equal(
    once.rules.indexOf("DOMAIN-SUFFIX,claude.ai,SG-Team") <
      once.rules.indexOf("GEOSITE,CN,DIRECT"),
    true,
  );
  assert.equal(
    once.rules.indexOf("GEOSITE,CN,DIRECT") <
      once.rules.indexOf("DOMAIN-SUFFIX,ad.qq.com,🛑 全球拦截"),
    true,
  );
  assert.equal(
    once.rules.includes("DOMAIN-SUFFIX,sentry.io,SG-Team"),
    true,
  );
  assert.equal(
    once.rules.includes("DOMAIN-KEYWORD,datadog,SG-Team"),
    true,
  );
  assert.equal(
    once.rules.includes(
      "AND,((DOMAIN-SUFFIX,claude.ai),(NETWORK,udp)),REJECT",
    ),
    true,
  );
  assert.equal(
    once.rules.includes("GEOSITE,category-ntp,DIRECT"),
    true,
  );
  assert.equal(
    once.rules.some(
      (rule) =>
        rule.includes("category-ntp") && rule.includes("SG-Team"),
    ),
    false,
  );
  assert.equal(
    once.rules.includes("DOMAIN-SUFFIX,corp.example,DIRECT"),
    true,
  );
});

test("生成配置通过本机 Mihomo 内核校验", (context) => {
  const mihomoPath =
    "/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo";
  const mihomoDataDir = join(
    process.env.HOME,
    "Library/Application Support/io.github.clash-verge-rev.clash-verge-rev",
  );
  if (!existsSync(mihomoPath) || !existsSync(mihomoDataDir)) {
    context.skip("本机未安装 Clash Verge Rev");
    return;
  }

  const fixture = createFixture();
  const install = runInstaller(fixture, ["--force-profile-script"]);
  assert.equal(install.status, 0, `${install.stdout}\n${install.stderr}`);
  const { main } = loadMain(fixture.globalScript);

  const config = plain(
    main(
      {
        "mixed-port": 17897,
        mode: "rule",
        "log-level": "silent",
        "allow-lan": false,
        dns: {
          enable: true,
          listen: "127.0.0.1:10553",
        },
        proxies: [],
        rules: ["MATCH,DIRECT"],
      },
      "测试订阅",
    ),
  );
  const configPath = join(fixture.home, "mihomo-config.json");
  writeFileSync(configPath, JSON.stringify(config, null, 2));

  const result = spawnSync(
    mihomoPath,
    ["-t", "-d", mihomoDataDir, "-f", configPath],
    { encoding: "utf8" },
  );
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
});

test("安装脚本通过 Bash 语法检查", () => {
  assert.equal(existsSync(installerPath), true, "尚未生成优化安装脚本");
  execFileSync("bash", ["-n", installerPath], { stdio: "pipe" });
});
