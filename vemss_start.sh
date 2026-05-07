#!/bin/bash

# ==========================================
# Debian VPS 生产级自动调优与部署脚本 v5.0
# 特性: 实时日志、日志静默、SSH决策、X-UI集成
# ==========================================

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

# 强制非交互模式
export DEBIAN_FRONTEND=noninteractive

clear
echo -e "${CYAN}====================================================${RESET}"
echo -e "${CYAN}      VPS 生产级高级网络调优与安全配置脚本 v5.0      ${RESET}"
echo -e "${CYAN}====================================================${RESET}\n"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误: 请使用 root 用户运行此脚本。${RESET}"
  exit 1
fi

# ================= 阶段一：参数收集 (决定权交给你) =================
echo -e "${YELLOW}>>> 阶段一：交互式配置收集${RESET}"

# 1. MTU 探测
MAIN_NIC=$(ip -4 route show default | awk '{print $5}' | head -n 1)
read -p "1. 输入网卡 ($MAIN_NIC) 的 MTU 值 [默认 1420]: " USER_MTU
USER_MTU=${USER_MTU:-1420}

# 2. SSH 端口决策
ALLOW_SSH="n"
CURRENT_SSH=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F':' '{print $NF}' | head -n 1)
if [ -n "$CURRENT_SSH" ]; then
    echo -e "2. ${GREEN}检测到 SSH 正在运行，端口为: $CURRENT_SSH${RESET}"
    read -p "   是否放行此端口？(如果不放行且你正通过此端口连接，可能会失联) [y/n, 默认 y]: " CONFIRM_SSH
    CONFIRM_SSH=${CONFIRM_SSH:-y}
    if [[ "$CONFIRM_SSH" =~ ^[Yy]$ ]]; then
        ALLOW_SSH="y"
        USER_SSH_PORT=$CURRENT_SSH
    fi
else
    echo -e "2. ${RED}未检测到标准 SSH 服务。${RESET}"
    read -p "   是否手动输入一个要开放的 SSH 端口？[留空则不放行]: " USER_SSH_PORT
    if [ -n "$USER_SSH_PORT" ]; then ALLOW_SSH="y"; fi
fi

# 3. 安装偏好
read -p "3. 是否安装 X-UI 面板？ [y/n, 默认 y]: " INSTALL_XUI
INSTALL_XUI=${INSTALL_XUI:-y}

read -p "4. 是否安装 Cloudflare WARP (解锁Gemini)？ [y/n, 默认 y]: " INSTALL_WARP
INSTALL_WARP=${INSTALL_WARP:-y}

echo -e "\n${GREEN}配置收集完毕，开始部署。如遇网络下载卡顿，脚本会自动尝试跳过。${RESET}\n"
sleep 2

# ================= 阶段二：依赖安装与防火墙预处理 =================
echo -e "${YELLOW}>>> [1/6] 正在同步软件源并安装依赖...${RESET}"
# 使用 timeout 预防 apt 彻底卡死
timeout 300s apt-get update -y
apt-get install -y curl wget iproute2 net-tools iputils-ping gawk ufw

# [关键改动] 立即关闭 UFW 日志，防止刷屏
if command -v ufw >/dev/null 2>&1; then
    ufw logging off >/dev/null 2>&1
    echo -e "   ${GREEN}[日志静默] 已关闭 UFW 核心日志，确保脚本输出清晰。${RESET}"
fi

# ================= 阶段三：底层调优 =================
echo -e "\n${YELLOW}>>> [2/6] 注入内核优化参数 (BBR + 禁用IPv6)...${RESET}"
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

echo -e "${YELLOW}>>> [3/6] 部署 MTU 锁定服务 (${USER_MTU})...${RESET}"
cat <<EOF > /etc/systemd/system/force-mtu.service
[Unit] Description=Force Set MTU [Service] Type=oneshot
ExecStart=/sbin/ip link set dev $MAIN_NIC mtu $USER_MTU
RemainAfterExit=yes
[Install] WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable force-mtu.service >/dev/null 2>&1
systemctl start force-mtu.service

echo -e "${YELLOW}>>> [4/6] DNS 竞速优化...${RESET}"
DNS_SERVERS=("1.1.1.1" "8.8.8.8" "9.9.9.9")
BEST_DNS="8.8.8.8"; MIN_MS=9999
for dns in "${DNS_SERVERS[@]}"; do
    echo -n "   测试 $dns ... "
    MS=$(ping -c 2 -w 2 $dns | grep -oP '(?<=time=)[0-9\.]+' | awk '{ sum += $1 } END { if (NR > 0) print sum / NR }')
    if [[ -n "$MS" ]]; then
        echo -e "${MS}ms"
        if awk "BEGIN {exit !($MS < $MIN_MS)}"; then MIN_MS=$MS; BEST_DNS=$dns; fi
    else
        echo -e "${RED}超时${RESET}"
    fi
done
echo -e "nameserver $BEST_DNS\nnameserver 8.8.4.4" > /etc/resolv.conf

# ================= 阶段四：防火墙策略 =================
echo -e "\n${YELLOW}>>> [5/6] 部署安全防火墙规则...${RESET}"
ufw --force reset >/dev/null 2>&1
ufw logging off  # 再次确保关闭

if [ "$ALLOW_SSH" == "y" ]; then
    ufw allow $USER_SSH_PORT/tcp >/dev/null 2>&1
    echo -e "   - 已根据用户决策放行 SSH 端口: $USER_SSH_PORT"
else
    echo -e "   - ${YELLOW}警告: 未开放任何 SSH 端口。${RESET}"
fi

ufw allow 443/tcp >/dev/null 2>&1
echo -e "   - 正在拉取 Cloudflare IP 列表 (带超时保护)..."
timeout 20s bash -c "for i in \$(curl -s https://www.cloudflare.com/ips-v4); do ufw allow proto tcp from \$i to any port 8880 >/dev/null 2>&1; done"

ufw default deny incoming
ufw default allow outgoing
ufw --force enable >/dev/null 2>&1
echo -e "   ${GREEN}防火墙启用完成。${RESET}"

# ================= 阶段五：组件安装 =================
if [[ "$INSTALL_XUI" =~ ^[Yy]$ ]]; then
    echo -e "\n${YELLOW}>>> [6/6] 正在拉取 X-UI 安装向导...${RESET}"
    echo -e "${RED}重要: 面板端口请务必手动输入 8880 以通过防火墙！${RESET}"
    sleep 3
    bash <(curl -Ls https://raw.githubusercontent.com/FranzKafkaYu/x-ui/master/install.sh)
fi

# ================= 阶段六：状态验收报告 (纯净版) =================
echo -e "\n${CYAN}====================================================${RESET}"
echo -e "${CYAN}               本机配置状态验收报告                 ${RESET}"
echo -e "${CYAN}====================================================${RESET}"

VAL_MTU=$(ip link show $MAIN_NIC | grep -oP '(?<=mtu )[0-9]+')
[ "$VAL_MTU" == "$USER_MTU" ] && echo -e "1. MTU 状态: ${GREEN}正常 ($VAL_MTU)${RESET}" || echo -e "1. MTU 状态: ${RED}异常 (当前 $VAL_MTU)${RESET}"

VAL_BBR=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
[ "$VAL_BBR" == "bbr" ] && echo -e "2. BBR 状态: ${GREEN}已激活${RESET}" || echo -e "2. BBR 状态: ${RED}未激活${RESET}"

echo -e "3. 系统 DNS: ${GREEN}$BEST_DNS${RESET}"

echo -e "4. 关键防火墙规则状态:"
ufw status | grep -E "($USER_SSH_PORT/tcp|443/tcp|8880/tcp)"

# ================= 阶段七：WARP 引导与测速 =================
if [[ "$INSTALL_WARP" =~ ^[Yy]$ ]]; then
    echo -e "\n${YELLOW}>>> 正在启动 Cloudflare WARP 配置向导...${RESET}"
    sleep 2
    wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh
fi

echo -e "\n${CYAN}====================================================${RESET}"
read -p ">> 是否执行最终的 NextTrace 回程追踪与网络带宽测试？ [y/N]: " FINAL_TEST
if [[ "$FINAL_TEST" =~ ^[Yy]$ ]]; then
    echo -e "\n${YELLOW}正在运行回程路由追踪...${RESET}"
    curl -s nxtrace.org/nt | bash
    echo -e "\n${YELLOW}正在运行 YABS 带宽测试 (仅网络)...${RESET}"
    curl -sL yabs.sh | bash -s -- -i -g
else
    echo -e "\n${GREEN}部署圆满结束。${RESET}"
fi
