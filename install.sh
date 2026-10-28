#!/bin/bash
set -Eeuo pipefail

LOG_FILE="/var/log/v2bx_v2node_init.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*"
}

error() {
  echo "[ERROR] $*"
}

log "脚本启动时间: $(date)"


# === 1. 安装基础依赖：curl / wget / unzip / zip / socat / pv / dnsutils ===

log "安装 curl/wget/unzip/zip/socat/pv/dnsutils..."

if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y

  for i in {1..5}; do
    if apt-get install -y \
      curl \
      wget \
      unzip \
      zip \
      socat \
      ca-certificates \
      pv \
      dnsutils; then
      break
    fi

    warn "apt 被锁定或安装失败，等待重试...($i/5)"
    sleep 5
  done

elif command -v yum >/dev/null 2>&1; then
  yum install -y epel-release || true
  yum install -y \
    curl \
    wget \
    unzip \
    zip \
    socat \
    ca-certificates \
    pv \
    bind-utils

elif command -v dnf >/dev/null 2>&1; then
  dnf install -y epel-release || true
  dnf install -y \
    curl \
    wget \
    unzip \
    zip \
    socat \
    ca-certificates \
    pv \
    bind-utils

elif command -v apk >/dev/null 2>&1; then
  apk update
  apk add --no-cache \
    curl \
    wget \
    unzip \
    zip \
    socat \
    ca-certificates \
    pv \
    bash \
    bind-tools

else
  error "未知的包管理器，无法自动安装必需依赖"
  exit 1
fi


# === 2. 安装哪吒 Agent，设置每 60 秒上报 ===

log "安装哪吒 Agent..."

cd /root || exit 1
rm -f agent.sh

curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh -o agent.sh
chmod +x agent.sh

NZ_SERVER=65.109.75.122:38888 \
NZ_TLS=false \
NZ_CLIENT_SECRET='UskD1XcYXcswqafCuTEI8EiPANRE8tDl' \
NZ_UUID='7d565bda-2236-2f41-4c36-248eae4f3464' \
./agent.sh

# === 4. 创建 TCP 端口转发脚本 ===

log "创建 TCP/IPv4+IPv6 端口转发脚本..."

install -d -m 755 /usr/local/bin

cat >/usr/local/bin/port_forward_env.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

PORT="${PORT:?missing PORT}"
TARGET_HOST="${TARGET_HOST:?missing TARGET_HOST}"
TARGET_PORT="${TARGET_PORT:?missing TARGET_PORT}"

echo "[INFO] socat $(date) [::]:${PORT} => ${TARGET_HOST}:${TARGET_PORT}"

exec socat -d -d \
  TCP6-LISTEN:${PORT},ipv6only=0,reuseaddr,fork,nodelay,keepalive \
  TCP:${TARGET_HOST}:${TARGET_PORT},nodelay,keepalive
EOF

chmod +x /usr/local/bin/port_forward_env.sh


# === 5. 创建 systemd 端口转发模板服务 ===

log "创建 port-forward@.service 模板..."

cat >/etc/systemd/system/port-forward@.service <<'EOF'
[Unit]
Description=TCP Forward 0.0.0.0:%i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/port-forward/%i.env
ExecStart=/usr/local/bin/port_forward_env.sh
Restart=always
RestartSec=2
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload


# === 6. 批量配置端口转发 ===

log "配置端口转发..."

declare -a MAPS=(
"31725 gb1.acyun.eu.org 15657"
"32265 tr.acyun.eu.org 8801"
"42048 kr1.acyun.eu.org 48644"
"35262 jp1.acyun.eu.org 23453"
"33351 tr.acyun.eu.org 12001"
"37265 hkaw.111165.xyz 39230"
"35245 sg1.acyun.eu.org 12337"
"37238 de1.acyun.eu.org 20160"
"25837 hkt-1.ddns-go.de 20470"
"31566 65.109.75.122 3388"
"51321 th.acyun.eu.org 20160"
"26807 in.acyun.eu.org 20520"
"51054 he1.acyun.eu.org 20200"
"35279 us2.acyun.eu.org 443"
"38745 vn.acyun.eu.org 20300"
"41244 hk1.acyun.eu.org 38878"
"47364 140.238.58.217 38878"
"36515 vn.acyun.eu.org 15654"
"46512 sg01.acyun.eu.org 15456"
"53561 id.acyun.eu.org 20140"
"41235 azhk27.acyun.eu.org 35265"
"57682 jp.acyun.eu.org 443"
"41654 vn.acyun.eu.org 35265"
"39514 129.154.217.251 42322"
"29366 sg1.acyun.eu.org 32132"
"34523 awshk.acyun.eu.org 37265"
"32142 hk1.acyun.eu.org 443"
"41324 se.acyun.eu.org 23654"
"34340 akile-hinet-chfb73.645781.xyz 20620"
"45247 156.224.78.247 16554"
"24169 156.229.167.236 15346"
)

open_port() {
  local port="$1"

  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${port}/tcp" || true
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${port}/tcp" || true
    firewall-cmd --add-port="${port}/tcp" || true
    firewall-cmd --reload || true
  else
    warn "未检测到 ufw/firewalld，跳过开端口 ${port}/tcp。如果服务器没有防火墙，可以忽略。"
  fi
}

install -d -m 755 /etc/port-forward

for line in "${MAPS[@]}"; do
  read -r PORT HOST RPORT <<<"$line"

  cat >"/etc/port-forward/${PORT}.env" <<EOF
PORT=${PORT}
TARGET_HOST=${HOST}
TARGET_PORT=${RPORT}
EOF

  systemctl disable --now "port-forward-${PORT}.service" 2>/dev/null || true
  systemctl disable --now "port-forward@${PORT}.service" 2>/dev/null || true

  open_port "${PORT}"

  systemctl enable --now "port-forward@${PORT}.service"

  log "已启动端口转发：0.0.0.0:${PORT} => ${HOST}:${RPORT}"
done

log "端口转发全部配置完成。"

# === 2. 安装 v2node ===
wget -N https://raw.githubusercontent.com/wyx2685/v2node/master/script/install.sh && \
bash install.sh \
--api-host 'https://yyds.acyun.eu.org' \
--node-id 66 \
--api-key 'kjdfbsfvbbiinbi@#@$'


# === 安装并运行 Cloudflare DNS 聚合脚本 ===

log "下载并运行 cf_sync_cdnce1.sh..."

cd /root || exit 1

wget -O /root/cf_sync_cdnce1.sh "https://github.com/acyuncf/acawsjp/releases/download/%E8%A7%A3%E6%9E%90/cf_sync_cdnce1.sh"

chmod +x /root/cf_sync_cdnce1.sh

bash /root/cf_sync_cdnce1.sh

# === 12. cdn安装 ===

cat >/root/install_edge_node.sh <<'EOF'
#!/bin/bash
set -Eeuo pipefail

cd /root

rm -rf /root/edge-node /root/edge-node.zip

wget -O /root/edge-node.zip https://github.com/acyuncf/acawsjp/releases/download/cdn/edge-node.zip

unzip -o /root/edge-node.zip -d /root

chmod +x /root/edge-node/bin/edge-node

cd /root/edge-node

./bin/edge-node -v

nohup ./bin/edge-node start >/dev/null 2>&1 &

sleep 2

./bin/edge-node status
EOF

chmod +x /root/install_edge_node.sh
bash /root/install_edge_node.sh

curl -4 -L --retry 3 --connect-timeout 15 \
  -o /root/restart_dl.sh \
  "https://github.com/acyuncf/acawsjp/releases/download/restartdl/restart_dl.sh"

chmod +x /root/restart_dl.sh

echo "[INFO] restart_dl.sh 下载完成并已赋予执行权限"

# === 12. 最后启用 root 登录 ===

log "最后启用 root 登录..."

echo "root:d9aEPC!bDzF:g6Jdse,-th" | chpasswd

if [ -f /etc/ssh/sshd_config ]; then
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
else
  warn "未找到 /etc/ssh/sshd_config，跳过 SSH 配置修改。"
fi


echo
log "全部完成！日志保存在：$LOG_FILE"
echo
echo "常用命令："
echo "  systemctl status v2bx --no-pager -l"
echo "  journalctl -u v2bx -f"
echo "  systemctl status v2node --no-pager -l"
echo "  journalctl -u v2node -f"
echo "  systemctl status port-forward@31725 --no-pager"
echo "  journalctl -u port-forward@31725 -f"
echo "  systemctl disable --now port-forward@31725"
echo
log "脚本结束时间: $(date)"
