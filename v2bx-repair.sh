#!/usr/bin/env bash
# v2bx-repair.sh
# 用途：检测 V2bX 是否在运行；不运行则认为可能安装不完整 → 清空 /etc/V2bX → 重新下载并启动
# 记录日志：/var/log/v2bx_repair.log
# 幂等：可反复执行；带文件锁，避免并发；失败会退出非零码

set -euo pipefail

LOG_FILE="/var/log/v2bx_repair.log"
LOCK_FILE="/var/lock/v2bx-repair.lock"
exec 9>"$LOCK_FILE" || true
flock -n 9 || { echo "[WARN] another repair is running, exit"; exit 0; }

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "========== [START] $(date '+%F %T') v2bx-repair =========="

# ===== 基本参数（按需修改）=====
V2BX_DIR="/etc/V2bX"
V2BX_BIN="${V2BX_DIR}/V2bX"
V2BX_CFG="${V2BX_DIR}/config.json"
SERVICE_NAME="v2bx.service"

BIN_URL="https://github.com/acyuncf/acawsjp/releases/download/123/V2bX"
CFG_BASE="https://wd1.acyun.eu.org/v2bx"
FILES=( "LICENSE" "README.md" "V2bX" "config.json" "custom_inbound.json" "custom_outbound.json" "dns.json" "geoip.dat" "geosite.dat" "route.json" )

# 是否保留备份（true|false），true 则把旧目录移到 /etc/V2bX.bak-时间戳
BACKUP_OLD=true

# ===== 工具函数 =====
wait_net() {
  echo "[INFO] waiting for network..."
  for i in {1..6}; do
    if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
      echo "[OK] network is up"; return 0
    fi
    echo "[WARN] network not ready ($i/6)"; sleep 5
  done
}

have() { command -v "$1" >/dev/null 2>&1; }

install_pkg() {
  local pkgs=("$@")
  if have apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || true
    for i in {1..5}; do
      if apt-get install -y "${pkgs[@]}"; then break; fi
      echo "[WARN] apt install failed/locked, retry ($i/5)"; sleep 5
    done
  elif have yum; then
    yum install -y epel-release || true
    yum install -y "${pkgs[@]}"
  elif have dnf; then
    dnf install -y "${pkgs[@]}"
  else
    echo "[ERROR] unknown package manager"; exit 1
  fi
}

need_bin() { have "$1" || install_pkg "$2"; }

clean_and_recreate_dir() {
  mkdir -p /etc
  if [[ -d "$V2BX_DIR" ]]; then
    if $BACKUP_OLD; then
      local ts; ts=$(date +%Y%m%d-%H%M%S)
      echo "[INFO] backup old ${V2BX_DIR} -> ${V2BX_DIR}.bak-${ts}"
      mv "$V2BX_DIR" "${V2BX_DIR}.bak-${ts}" || true
    else
      echo "[INFO] remove old ${V2BX_DIR}"
      rm -rf "${V2BX_DIR}"
    fi
  fi
  mkdir -p "$V2BX_DIR"
}

register_service() {
  cat >"/etc/systemd/system/${SERVICE_NAME}" <<EOF
[Unit]
Description=V2bX Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${V2BX_DIR}
ExecStart=${V2BX_BIN} server -c ${V2BX_CFG}
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
}

start_and_verify() {
  echo "[INFO] starting ${SERVICE_NAME}..."
  systemctl restart "${SERVICE_NAME}" || true
  sleep 2
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    echo "[OK] systemd service is active"
  else
    echo "[WARN] service not active, try nohup fallback"
    nohup "${V2BX_BIN}" server -c "${V2BX_CFG}" >/dev/null 2>&1 &
    sleep 2
  fi

  if pgrep -x "V2bX" >/dev/null 2>&1; then
    echo "[OK] V2bX process is running"
    return 0
  else
    echo "[ERROR] V2bX failed to start"
    return 1
  fi
}

# ===== 1) 快速检测：若已在运行直接退出 =====
if pgrep -x "V2bX" >/dev/null 2>&1; then
  echo "[OK] V2bX is running, nothing to do"
  echo "========== [DONE] $(date '+%F %T') =========="; exit 0
fi
echo "[WARN] V2bX not running → will re-install all files"

# ===== 2) 准备环境 =====
wait_net
need_bin curl curl
need_bin wget wget
need_bin unzip unzip
need_bin zip zip

# ===== 3) 清空并重装 =====
clean_and_recreate_dir
cd "$V2BX_DIR"

echo "[INFO] downloading V2bX binary..."
wget -O "V2bX" "$BIN_URL"
chmod +x "V2bX"

echo "[INFO] downloading configs..."
for f in "${FILES[@]}"; do
  [[ "$f" == "V2bX" ]] && continue
  wget -O "$f" "${CFG_BASE}/${f}"
done

# ===== 4) 注册服务并启动 =====
register_service
if start_and_verify; then
  echo "========== [DONE] $(date '+%F %T') OK =========="; exit 0
else
  echo "========== [DONE] $(date '+%F %T') FAIL =========="; exit 1
fi
