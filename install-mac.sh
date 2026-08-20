#!/usr/bin/env bash
# 在另一台 Mac 上安装 Claude→新加坡 配置，并清理常见脏配置
# 用法：
#   chmod +x install-mac.sh
#   ./install-mac.sh
#
# 适配：Clash Verge / Clash Verge Rev

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC_SCRIPT="$ROOT/Script.js"
SRC_DNS="$ROOT/dns_config.yaml"

VERGE_DIR="${HOME}/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
if [[ ! -d "$VERGE_DIR" ]]; then
  VERGE_DIR="${HOME}/Library/Application Support/io.github.clash-verge.clash-verge"
fi
if [[ ! -d "$VERGE_DIR" ]]; then
  echo "未找到 Clash Verge 配置目录。"
  echo "请先安装并至少启动一次 Clash Verge Rev，再重试。"
  exit 1
fi

PROFILES_DIR="$VERGE_DIR/profiles"
GLOBAL_SCRIPT="$PROFILES_DIR/Script.js"
DNS_FILE="$VERGE_DIR/dns_config.yaml"
RUNTIME_YAML="$VERGE_DIR/clash-verge.yaml"
VERGE_YAML="$VERGE_DIR/verge.yaml"
STAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP_DIR="$ROOT/backup-$STAMP"

echo "==> Clash Verge 目录: $VERGE_DIR"
mkdir -p "$BACKUP_DIR" "$PROFILES_DIR"

backup_if_exists() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -p "$f" "$BACKUP_DIR/$(basename "$f")"
    echo "    已备份: $f"
  fi
}

echo "==> 备份旧文件到: $BACKUP_DIR"
backup_if_exists "$GLOBAL_SCRIPT"
backup_if_exists "$DNS_FILE"
backup_if_exists "$RUNTIME_YAML"
backup_if_exists "$VERGE_YAML"

echo "==> 写入全局脚本 Script.js"
cp "$SRC_SCRIPT" "$GLOBAL_SCRIPT"

echo "==> 写入 dns_config.yaml"
cp "$SRC_DNS" "$DNS_FILE"

echo "==> 清理运行配置中的脏 hosts / 旧 DNS 残留（若存在）"
if [[ -f "$RUNTIME_YAML" ]]; then
  python3 - <<'PY' "$RUNTIME_YAML"
import re, sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="ignore")
original = text

# 删除顶层 hosts 里 claude/anthropic 相关项；若 hosts 只剩这些则整段删除
def strip_hosts(t: str) -> str:
    m = re.search(r"^hosts:\n((?:  .*\n)*)", t, flags=re.M)
    if not m:
        return t
    body = m.group(1)
    kept = []
    for line in body.splitlines(True):
        low = line.lower()
        if any(k in low for k in ["claude", "anthropic", "claudemcp", "clau.de"]):
            continue
        kept.append(line)
    if not any(x.strip() for x in kept):
        return t[:m.start()] + t[m.end():]
    return t[:m.start()] + "hosts:\n" + "".join(kept) + t[m.end():]

text = strip_hosts(text)

# 删除错误残留顶层键 ns:（曾出现过的脏片段）
text = re.sub(r"^ns:\n(?:  .*\n)*", "", text, flags=re.M)

if text != original:
    path.write_text(text, encoding="utf-8")
    print("    已清理 clash-verge.yaml 脏片段")
else:
    print("    clash-verge.yaml 无明显脏 hosts/ns 片段")
PY
fi

echo "==> 尝试开启 Verge DNS 覆盖 / TUN（不强制开系统代理）"
if [[ -f "$VERGE_YAML" ]]; then
  python3 - <<'PY' "$VERGE_YAML"
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="ignore")
lines = text.splitlines()
out = []
seen = {"enable_dns_settings": False, "enable_tun_mode": False, "enable_system_proxy": False}
for line in lines:
    if line.startswith("enable_dns_settings:"):
        out.append("enable_dns_settings: true")
        seen["enable_dns_settings"] = True
    elif line.startswith("enable_tun_mode:"):
        out.append("enable_tun_mode: true")
        seen["enable_tun_mode"] = True
    elif line.startswith("enable_system_proxy:"):
        # 另一台若脏配置只靠系统代理且 IPv6 泄露，这里仍建议保留用户原值；
        # 仅在字段缺失时不追加强制关闭。
        out.append(line)
        seen["enable_system_proxy"] = True
    else:
        out.append(line)
if not seen["enable_dns_settings"]:
    out.append("enable_dns_settings: true")
if not seen["enable_tun_mode"]:
    out.append("enable_tun_mode: true")
path.write_text("\n".join(out) + "\n", encoding="utf-8")
print("    已确保 enable_dns_settings=true, enable_tun_mode=true")
PY
fi

echo
echo "安装完成。"
echo
echo "请在另一台电脑按顺序操作："
echo "  1) 打开 Clash Verge"
echo "  2) 设置 → 打开「DNS 覆盖 / 启用 DNS 设置」"
echo "  3) 配置 → 全局扩展脚本：确认已启用（Script）"
echo "  4) 对当前订阅点「重新加载 / 增强」或切换一次订阅再切回"
echo "  5) 模式保持 rule；开启 TUN"
echo "  6) 系统时区建议设为新加坡（你已改过可忽略）"
echo "  7) 建议关闭系统 IPv6，避免只开 TUN 时泄露"
echo
echo "验证："
echo "  ./verify.sh"
echo "  或打开 https://ip.net.coffee/claude/ 看 Claude 出口是否为新加坡"
echo
echo "若全局脚本未生效，把 Script.js 内容粘贴到："
echo "  当前订阅 → 编辑增强脚本（script）"
echo "备份目录: $BACKUP_DIR"
