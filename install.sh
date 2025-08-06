#!/bin/bash

LOG_FILE="/var/log/v2bx_init.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[INFO] 脚本启动时间: $(date)"

# === 0. 等待网络就绪（最多等待30秒）===
echo "[INFO] 检查网络连接..."
for i in {1..6}; do
    ping -c 1 -W 2 1.1.1.1 >/dev/null && break
    echo "[WARN] 网络未就绪，等待中...(尝试 $i/6)"
    sleep 5
done

# === 1. 启用 root 登录 ===
echo "[INFO] 启用 root 登录..."
echo root:'MHTmht123@' | sudo chpasswd root
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo systemctl restart sshd

# === 2. 自动安装 unzip 和 zip（含重试）===
echo "[INFO] 安装 unzip 和 zip..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    for i in {1..5}; do
        apt-get install -y unzip zip && break
        echo "[WARN] apt 被锁定或失败，等待重试...($i/5)"
        sleep 5
    done
elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release
    yum install -y unzip zip
else
    echo "[ERROR] 未知的包管理器，无法自动安装 unzip 和 zip"
    exit 1
fi

# === 安装 nyanpass 客户端 ===
echo "[INFO] 安装 nyanpass 客户端..."
S=nyanpass OPTIMIZE=1 bash <(curl -fLSs https://dl.nyafw.com/download/nyanpass-install.sh) rel_nodeclient "-o -t e1fa8b04-f707-41d6-b443-326a0947fa2f -u https://ny.321337.xyz"

# === 安装哪啦 Agent，设置每 60 秒上报 ===
echo "[INFO] 安装哪啦 Agent..."
cd /root
curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/install.sh -o nezha.sh
chmod +x nezha.sh
./nezha.sh install_agent 65.109.75.122 5555 ATj1oOMobYvsX1ZDDD -u 60

# === 3. 安装 V2bX ===
echo "[INFO] 从 GitHub Releases 下载 V2bX 主程序..."
mkdir -p /etc/V2bX
cd /etc/V2bX

wget -O V2bX https://github.com/acyuncf/acawsjp/releases/download/123/V2bX || {
    echo "[ERROR] V2bX 下载失败，退出"
    exit 1
}
chmod +x V2bX

# 下载配置文件
echo "[INFO] 下载其余配置文件..."
config_url="https://wd1.acyun.eu.org/v2bx"
for file in LICENSE README.md config.json custom_inbound.json custom_outbound.json dns.json geoip.dat geosite.dat route.json; do
    wget "$config_url/$file" || {
        echo "[ERROR] 下载 $file 失败"
        exit 1
    }
done

# === 启动 V2bX（后台运行）===
echo "[INFO] 启动 V2bX..."
nohup /etc/V2bX/V2bX server -c /etc/V2bX/config.json > /etc/V2bX/v2bx.log 2>&1 &

# === 注册 V2bX 为 systemd 服务 ===
echo "[INFO] 注册 V2bX 为 systemd 服务..."
cat > /etc/systemd/system/v2bx.service <<EOF
[Unit]
Description=V2bX Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/etc/V2bX
ExecStart=/etc/V2bX/V2bX server -c /etc/V2bX/config.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable v2bx
systemctl start v2bx

echo "[SUCCESS] 所有组件安装完成，日志保存在 $LOG_FILE"
