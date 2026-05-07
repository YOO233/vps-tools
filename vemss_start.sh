#!/bin/bash

# ==========================================
# Debian VPS 交互式终极调优与安全部署脚本 v2.0
# 特性: 依赖自愈 | 动态防火墙 | 实时反馈 | DNS竞速
# ==========================================

# 颜色定义
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

clear
echo -e "${CYAN}====================================================${RESET}"
echo -e "${CYAN}      VPS 交互式高级网络调优与安全配置脚本 v2.0      ${RESET}"
echo -e "${CYAN}====================================================${RESET}\n"

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 用户运行此脚本 (执行 sudo -i 后再试)。${RESET}"
  exit 1
fi

# ================= 阶段零：依赖自测与补全 =================
echo -e "${YELLOW}>>> [初始化] 正在检测并补全系统必备运行依赖...${RESET}"
apt-get update -y >/dev/null 2>&1
# 强制安装必备的基础网络和下载工具包
echo -n "检查依赖包: curl, wget, iproute2, net-tools, iputils-ping, awk... "
apt-get install -y curl wget iproute2 net-tools iputils-ping gawk >/dev/null 2>&1
echo -e "${GREEN}[完成]${RESET}\n"


# ================= 第一阶段：前置参数收集 =================
echo -e "${YELLOW}>>> 阶段一：参数设定 (请根据提示输入，直接回车使用默认值)${RESET}\n"

# 1. MTU 收集
MAIN_NIC=$(ip -4 route show default | awk '{print $5}' | head -n 1)
read -p "1. 请输入主网卡 ($MAIN_NIC) 的 MTU 数值 [默认 1420]: " USER_MTU
USER_MTU=${USER_MTU:-1420}

# 2. UFW 与 SSH 安全策略收集
USE_UFW="n"
if command -v ufw >/dev/null 2>&1; then
    USE_UFW="y"
    echo -e "2. 防火墙检测: ${GREEN}已检测到 UFW 安装。${RESET}"
else
    echo -e "2. 防火墙检测: ${RED}系统未安装 UFW 防火墙。${RESET}"
    read -p "   是否自动安装并配置 UFW 以保护服务器？ [y/n, 默认 y]: " INSTALL_UFW
    INSTALL_UFW=${INSTALL_UFW:-y}
    if [[ "$INSTALL_UFW" =~ ^[Yy]$ ]]; then
        USE_UFW="y"
    fi
fi

if [ "$USE_UFW" == "y" ]; then
    # 动态抓取真正的 SSH 端口，绝不默认 22
    CURRENT_SSH=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F':' '{print $NF}' | head -n 1)
    if [ -n "$CURRENT_SSH" ]; then
        read -p "   >> 检测到当前运行的 SSH 端口为 ${CURRENT_SSH}，请输入要放行的端口 [默认 ${CURRENT_SSH}]: " USER_SSH_PORT
        USER_SSH_PORT=${USER_SSH_PORT:-$CURRENT_SSH}
    else
        read -p "   >> ${RED}警告：未检测到运行中的 SSH 服务！${RESET} 请手动输入需要放行的 SSH 端口 [留空则不放行任何 SSH 端口]: " USER_SSH_PORT
    fi
fi

# 3. WARP 收集
read -p "3. 脚本执行完毕后，是否自动拉起 Cloudflare WARP 安装向导？ [y/n, 默认 y]: " INSTALL_WARP
INSTALL_WARP=${INSTALL_WARP:-y}

echo -e "\n${GREEN}参数收集完毕！系统即将开始自动化部署...${RESET}\n"
sleep 2


# ================= 第二阶段：自动化部署 =================

# 任务 1: 内核优化
echo -e "${YELLOW}>>> [1/5] 正在注入内核网络优化参数 (BBR, 禁用IPv6)...${RESET}"
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
echo -e "内核参数注入完成。"

# 任务 2: MTU 锁定
echo -e "\n${YELLOW}>>> [2/5] 通过 systemd 强制锁定网卡 MTU 为 ${USER_MTU}...${RESET}"
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
echo -e "MTU 守护进程已启动。"

# 任务 3: DNS 竞速
echo -e "\n${YELLOW}>>> [3/5] 正在全球公共 DNS 竞速测速...${RESET}"
DNS_SERVERS=("1.1.1.1" "8.8.8.8" "9.9.9.9" "208.67.222.222")
BEST_DNS="8.8.8.8"
MIN_MS=9999

for dns in "${DNS_SERVERS[@]}"; do
    echo -n "   - 测试 $dns ... "
    MS=$(ping -c 2 -w 2 $dns | grep -oP '(?<=time=)[0-9\.]+' | awk '{ sum += $1 } END { if (NR > 0) print sum / NR }')
    if [[ -n "$MS" ]]; then
        echo "${MS} ms"
        if awk "BEGIN {exit !($MS < $MIN_MS)}"; then
            MIN_MS=$MS
            BEST_DNS=$dns
        fi
    else
        echo "超时"
    fi
done
echo -e "   ${GREEN}>> 优选 DNS 为: $BEST_DNS${RESET}"
cp /etc/resolv.conf /etc/resolv.conf.bak
echo -e "nameserver $BEST_DNS\nnameserver 8.8.4.4" > /etc/resolv.conf

# 任务 4: UFW 部署
if [ "$USE_UFW" == "y" ]; then
    echo -e "\n${YELLOW}>>> [4/5] 正在构建 UFW 防火墙体系...${RESET}"
    if ! command -v ufw >/dev/null 2>&1; then
        echo "   - 正在安装 ufw 组件..."
        apt-get install -y ufw >/dev/null 2>&1
    fi
    ufw --force reset >/dev/null 2>&1
    
    if [ -n "$USER_SSH_PORT" ]; then
        echo "   - 放行 SSH 端口: $USER_SSH_PORT"
        ufw allow $USER_SSH_PORT/tcp comment 'Custom SSH' >/dev/null 2>&1
    else
        echo "   - ${RED}未放行任何 SSH 端口${RESET}"
    fi
    
    echo "   - 放行节点端口: 443"
    ufw allow 443/tcp comment 'VLESS-Reality' >/dev/null 2>&1
    
    echo "   - 正在拉取 Cloudflare IPv4 白名单放行 UI 端口 8880..."
    for i in $(curl -s https://www.cloudflare.com/ips-v4); do
        ufw allow proto tcp from $i to any port 8880 comment 'Cloudflare UI' >/dev/null 2>&1
    done
    
    ufw default deny incoming
    ufw default allow outgoing
    ufw --force enable >/dev/null 2>&1
    ufw logging off
    echo -e "   ${GREEN}防火墙规则部署完毕！${RESET}"
else
    echo -e "\n${YELLOW}>>> [4/5] 用户选择跳过防火墙部署。${RESET}"
fi

# 任务 5: 工具箱下载 (带进度展示)
echo -e "\n${YELLOW}>>> [5/5] 正在下载测试工具箱到 /root/vps-tools...${RESET}"
mkdir -p /root/vps-tools && cd /root/vps-tools

echo -e "   1. 下载流媒体解锁测试脚本 (check.unlock.media):"
wget --progress=bar:force -O check.unlock.media https://check.unlock.media
chmod +x check.unlock.media

echo -e "   2. 安装 NextTrace 路由追踪工具:"
curl -s nxtrace.org/nt | bash
echo -e "   ${GREEN}工具箱准备就绪！${RESET}"


# ================= 第三阶段：验证环节 =================
echo -e "\n${CYAN}====================================================${RESET}"
echo -e "${CYAN}                 最终配置验证报告                   ${RESET}"
echo -e "${CYAN}====================================================${RESET}"

ACTUAL_MTU=$(ip link show $MAIN_NIC | grep -oP '(?<=mtu )[0-9]+')
if [ "$ACTUAL_MTU" == "$USER_MTU" ]; then
    echo -e "1. ${GREEN}[通过]${RESET} MTU 设定: $ACTUAL_MTU"
else
    echo -e "1. ${RED}[异常]${RESET} MTU 设定: 当前 $ACTUAL_MTU，期望 $USER_MTU"
fi

CURRENT_CC=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
if [ "$CURRENT_CC" == "bbr" ]; then
    echo -e "2. ${GREEN}[通过]${RESET} 拥塞控制: BBR 已激活"
else
    echo -e "2. ${RED}[异常]${RESET} 拥塞控制: 未启用 BBR"
fi

echo -e "3. ${GREEN}[通过]${RESET} 系统 DNS: $BEST_DNS"

if [ "$USE_UFW" == "y" ]; then
    echo -e "4. ${GREEN}[通过]${RESET} UFW 关键放行规则核对:"
    ufw status | grep -E "($USER_SSH_PORT/tcp|443/tcp|8880/tcp)" | head -n 3
else
    echo -e "4. ${YELLOW}[跳过]${RESET} 防火墙未启用"
fi

# ================= 第四阶段：后续引导与 WARP =================
echo -e "\n${YELLOW}=== 基础部署已完成 ===${RESET}"
echo -e "面板一键安装命令 (请手动复制运行):"
echo -e "${RED}bash <(curl -Ls https://raw.githubusercontent.com/FranzKafkaYu/x-ui/master/install.sh)${RESET}\n"

if [[ "$INSTALL_WARP" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}即将为您启动 WARP 安装向导... (3秒后)${RESET}"
    sleep 3
    wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh
else
    echo -e "您选择了跳过 WARP 安装。后续如需解锁流媒体/AI，可运行："
    echo -e "wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh"
fi
