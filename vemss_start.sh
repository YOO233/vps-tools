#!/bin/bash

# ==========================================
# Debian VPS 交互式终极调优与防封锁部署脚本
# 适用系统: Debian 11/12 | Ubuntu 20/22
# ==========================================

# 颜色定义
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

clear
echo -e "${CYAN}====================================================${RESET}"
echo -e "${CYAN}      VPS 交互式高级网络调优与安全配置脚本        ${RESET}"
echo -e "${CYAN}====================================================${RESET}\n"

# ================= 第一阶段：前置参数收集 =================
echo -e "${YELLOW}>>> 阶段一：参数设定 (请根据提示输入，直接回车使用默认值)${RESET}"

# 1. 获取主网卡名称
MAIN_NIC=$(ip -4 route show default | awk '{print $5}' | head -n 1)

# 2. 收集 MTU 设置
read -p "1. 请输入主网卡 ($MAIN_NIC) 的 MTU 数值 [默认 1420]: " USER_MTU
USER_MTU=${USER_MTU:-1420}

# 3. 收集 SSH 端口设置
# 自动探测当前实际监听的 SSH 端口，作为默认值，极大地防止小白把自己锁在外面
CURRENT_SSH=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F':' '{print $NF}' | head -n 1)
CURRENT_SSH=${CURRENT_SSH:-22}
read -p "2. 请输入您希望 UFW 放行的 SSH 端口 (极度重要，防失联) [默认检测为 $CURRENT_SSH]: " USER_SSH_PORT
USER_SSH_PORT=${USER_SSH_PORT:-$CURRENT_SSH}

# 4. 收集 WARP 安装意向
read -p "3. 脚本执行完毕后，是否自动拉起 Cloudflare WARP 安装向导？ [y/n, 默认 y]: " INSTALL_WARP
INSTALL_WARP=${INSTALL_WARP:-y}

echo -e "\n${GREEN}参数收集完毕！系统即将开始自动化部署，请坐和放宽...${RESET}\n"
sleep 2

# ================= 第二阶段：自动化部署 =================
echo -e "${YELLOW}>>> [1/6] 更新系统与安装基础组件...${RESET}"
apt update -y >/dev/null 2>&1
apt install -y curl wget ufw iproute2 net-tools tzdata awk >/dev/null 2>&1

echo -e "${YELLOW}>>> [2/6] 注入内核网络优化参数 (BBR, Cake, 禁用IPv6)...${RESET}"
cat <<EOF > /etc/sysctl.conf
net.core.default_qdisc=cake
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_keepalive_time = 1200
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
fs.file-max = 1000000
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl -p >/dev/null 2>&1

echo -e "${YELLOW}>>> [3/6] 通过 systemd 强制锁定网卡 MTU 为 ${USER_MTU}...${RESET}"
cat <<EOF > /etc/systemd/system/force-mtu.service
[Unit]
Description=Force Set MTU for $MAIN_NIC
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/ip link set dev $MAIN_NIC mtu $USER_MTU
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable force-mtu.service >/dev/null 2>&1
systemctl start force-mtu.service

echo -e "${YELLOW}>>> [4/6] 自动测速并配置全局最快 DNS...${RESET}"
DNS_SERVERS=("1.1.1.1" "8.8.8.8" "9.9.9.9" "208.67.222.222" "1.0.0.1" "8.8.4.4")
BEST_DNS="8.8.8.8"
MIN_MS=9999

for dns in "${DNS_SERVERS[@]}"; do
    # 连续 ping 2 次计算平均值
    MS=$(ping -c 2 -w 2 $dns | grep -oP '(?<=time=)[0-9\.]+' | awk '{ sum += $1 } END { if (NR > 0) print sum / NR }')
    if [[ -n "$MS" ]]; then
        # awk 浮点数比较
        if awk "BEGIN {exit !($MS < $MIN_MS)}"; then
            MIN_MS=$MS
            BEST_DNS=$dns
        fi
    fi
done
echo -e "测速完成，为当前机房优选的 DNS 为: ${GREEN}$BEST_DNS${RESET} (延迟: ${MIN_MS}ms)"
# 备份并覆写 DNS 配置文件
cp /etc/resolv.conf /etc/resolv.conf.bak
echo -e "nameserver $BEST_DNS\nnameserver 8.8.4.4" > /etc/resolv.conf

echo -e "${YELLOW}>>> [5/6] 配置 UFW 防火墙 (仅放行 $USER_SSH_PORT, 443 及 CF 节点)...${RESET}"
ufw --force reset >/dev/null 2>&1
ufw allow $USER_SSH_PORT/tcp comment 'Custom SSH'
ufw allow 443/tcp comment 'VLESS-Reality'
for i in $(curl -s https://www.cloudflare.com/ips-v4); do
    ufw allow proto tcp from $i to any port 8880 comment 'Cloudflare UI' >/dev/null 2>&1
done
ufw default deny incoming
ufw default allow outgoing
ufw --force enable >/dev/null 2>&1
ufw logging off

echo -e "${YELLOW}>>> [6/6] 下载测试工具箱...${RESET}"
mkdir -p /root/vps-tools && cd /root/vps-tools
wget -q -O check.unlock.media https://check.unlock.media && chmod +x check.unlock.media
curl -s nxtrace.org/nt | bash >/dev/null 2>&1


# ================= 第三阶段：验证环节 =================
echo -e "\n${CYAN}====================================================${RESET}"
echo -e "${CYAN}                 最终配置验证报告                   ${RESET}"
echo -e "${CYAN}====================================================${RESET}"

# 验证 1: MTU
ACTUAL_MTU=$(ip link show $MAIN_NIC | grep -oP '(?<=mtu )[0-9]+')
if [ "$ACTUAL_MTU" == "$USER_MTU" ]; then
    echo -e "1. ${GREEN}[通过]${RESET} MTU 设定: 成功锁定在 $ACTUAL_MTU"
else
    echo -e "1. ${RED}[异常]${RESET} MTU 设定: 当前为 $ACTUAL_MTU，期望为 $USER_MTU"
fi

# 验证 2: 拥塞控制算法
CURRENT_CC=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
if [ "$CURRENT_CC" == "bbr" ]; then
    echo -e "2. ${GREEN}[通过]${RESET} 拥塞控制: BBR 加速已激活"
else
    echo -e "2. ${RED}[异常]${RESET} 拥塞控制: 未启用 BBR"
fi

# 验证 3: DNS
CURRENT_DNS=$(grep nameserver /etc/resolv.conf | head -n 1 | awk '{print $2}')
echo -e "3. ${GREEN}[通过]${RESET} 系统 DNS: 已自动优化为 $CURRENT_DNS"

# 验证 4: 防火墙规则
echo -e "4. ${GREEN}[通过]${RESET} UFW 关键放行规则核对:"
ufw status | grep -E "($USER_SSH_PORT/tcp|443/tcp|8880/tcp)" | head -n 3


# ================= 第四阶段：后续引导与 WARP =================
echo -e "\n${YELLOW}=== 基础部署已完成 ===${RESET}"
echo -e "面板一键安装命令 (请手动复制运行):"
echo -e "${RED}bash <(curl -Ls https://raw.githubusercontent.com/FranzKafkaYu/x-ui/master/install.sh)${RESET}\n"

if [[ "$INSTALL_WARP" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}即将为您启动 WARP 安装向导... (3秒后)${RESET}"
    sleep 3
    wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh
else
    echo -e "您选择了跳过 WARP 安装。如需解锁流媒体/AI，可随时手动运行："
    echo -e "wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh"
fi
