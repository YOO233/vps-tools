#!/bin/bash

# ==========================================
# Debian VPS 生产级自动调优与部署脚本 v4.0
# 特性: 过程透明化 | 智能超时 | 依赖自愈 | X-UI 直装
# ==========================================

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

# 强制非交互模式，防止 apt 弹出菜单挂起脚本
export DEBIAN_FRONTEND=noninteractive

clear
echo -e "${CYAN}====================================================${RESET}"
echo -e "${CYAN}      VPS 生产级高级网络调优与安全配置脚本 v4.0      ${RESET}"
echo -e "${CYAN}====================================================${RESET}\n"

# 权限检查
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 用户运行此脚本。${RESET}"
  exit 1
fi

# ================= 阶段一：参数前置收集 =================
# 在执行任何耗时操作前，先收集所有用户指令
echo -e "${YELLOW}>>> 阶段一：参数设定${RESET}"

# 1. 自动探测网卡
MAIN_NIC=$(ip -4 route show default | awk '{print $5}' | head -n 1)
read -p "1. 请输入网卡 ($MAIN_NIC) 的 MTU 值 [默认 1420]: " USER_MTU
USER_MTU=${USER_MTU:-1420}

# 2. SSH 端口深度探测
CURRENT_SSH=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F':' '{print $NF}' | head -n 1)
if [ -n "$CURRENT_SSH" ]; then
    echo -e "2. 检测到当前 SSH 端口为: ${GREEN}${CURRENT_SSH}${RESET}"
    USER_SSH_PORT=$CURRENT_SSH
else
    echo -e "2. ${RED}未检测到标准 SSH 服务端口，防火墙将不会默认开放 22 端口。${RESET}"
    USER_SSH_PORT=""
fi

# 3. 安装选项
read -p "3. 是否安装 X-UI 面板？ [y/n, 默认 y]: " INSTALL_XUI
INSTALL_XUI=${INSTALL_XUI:-y}

read -p "4. 是否安装 Cloudflare WARP (解锁Gemini)？ [y/n, 默认 y]: " INSTALL_WARP
INSTALL_WARP=${INSTALL_WARP:-y}

echo -e "\n${GREEN}配置收集完毕，准备开始部署...${RESET}\n"
sleep 2

# ================= 阶段二：依赖安装 (日志可见) =================
echo -e "${YELLOW}>>> [1/6] 正在同步软件源并安装依赖 (实时日志)...${RESET}"
# 为 apt-get 增加超时保护，防止源失效卡死
timeout 120s apt-get update -y
if [ $? -ne 0 ]; then
    echo -e "${RED}软件源更新超时或失败，尝试继续安装必备组件...${RESET}"
fi

# 安装过程不再屏蔽输出，方便用户观察进度
apt-get install -y curl wget iproute2 net-tools iputils-ping gawk ufw
if [ $? -eq 0 ]; then
    echo -e "${GREEN}基础组件安装完成。${RESET}"
else
    echo -e "${RED}基础组件安装出现异常，脚本尝试继续执行核心配置。${RESET}"
fi

# ================= 阶段三：底层调优 =================
echo -e "\n${YELLOW}>>> [2/6] 注入内核参数 (BBR + 禁用IPv6)...${RESET}"
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

echo -e "${YELLOW}>>> [4/6] DNS 竞速优化...${RESET}"
DNS_SERVERS=("1.1.1.1" "8.8.8.8" "9.9.9.9")
BEST_DNS="8.8.8.8"
MIN_MS=9999
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

# ================= 阶段四：防火墙逻辑 =================
echo -e "\n${YELLOW}>>> [5/6] 部署防火墙安全策略...${RESET}"
ufw --force reset >/dev/null 2>&1
if [ -n "$USER_SSH_PORT" ]; then
    ufw allow $USER_SSH_PORT/tcp >/dev/null 2>&1
    echo -e "   - 已放行 SSH 端口: $USER_SSH_PORT"
fi
ufw allow 443/tcp >/dev/null 2>&1
# 增加 Cloudflare IP 拉取超时保护
timeout 15s bash -c "for i in \$(curl -s https://www.cloudflare.com/ips-v4); do ufw allow proto tcp from \$i to any port 8880 >/dev/null 2>&1; done"
ufw default deny incoming
ufw default allow outgoing
ufw --force enable >/dev/null 2>&1
echo -e "   ${GREEN}防火墙配置完成。${RESET}"

# ================= 阶段五：组件安装 =================
if [[ "$INSTALL_XUI" =~ ^[Yy]$ ]]; then
    echo -e "\n${YELLOW}>>> [6/6] 正在安装 X-UI 面板...${RESET}"
    echo -e "${RED}！！请务必在接下来的向导中将端口手动设为 8880 ！！${RESET}"
    sleep 3
    # 保持 X-UI 的安装交互，因为需要用户设置账号密码
    bash <(curl -Ls https://raw.githubusercontent.com/FranzKafkaYu/x-ui/master/install.sh)
fi

# ================= 阶段六：自我验证报告 =================
echo -e "\n${CYAN}====================================================${RESET}"
echo -e "${CYAN}               本机配置状态核验报告                 ${RESET}"
echo -e "${CYAN}====================================================${RESET}"

# 1. 验证 MTU
VAL_MTU=$(ip link show $MAIN_NIC | grep -oP '(?<=mtu )[0-9]+')
[ "$VAL_MTU" == "$USER_MTU" ] && echo -e "1. MTU 状态: ${GREEN}正常 ($VAL_MTU)${RESET}" || echo -e "1. MTU 状态: ${RED}异常 (当前 $VAL_MTU)${RESET}"

# 2. 验证 BBR
VAL_BBR=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
[ "$VAL_BBR" == "bbr" ] && echo -e "2. BBR 状态: ${GREEN}已激活${RESET}" || echo -e "2. BBR 状态: ${RED}未激活${RESET}"

# 3. 验证防火墙端口
echo -e "3. 关键端口放行情况:"
ufw status | grep -E "($USER_SSH_PORT/tcp|443/tcp|8880/tcp)"

# ================= 阶段七：WARP 引导与测速选项 =================
if [[ "$INSTALL_WARP" =~ ^[Yy]$ ]]; then
    echo -e "\n${YELLOW}>>> 即将拉起 WARP 安装向导...${RESET}"
    sleep 2
    wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh
fi

echo -e "\n${CYAN}====================================================${RESET}"
read -p ">> 全部核心部署完成！是否运行 NextTrace 回程追踪和 YABS 测速？ [y/N]: " FINAL_TEST
if [[ "$FINAL_TEST" =~ ^[Yy]$ ]]; then
    echo -e "\n${YELLOW}>>> 正在运行回程路由追踪...${RESET}"
    curl -s nxtrace.org/nt | bash
    echo -e "\n${YELLOW}>>> 正在运行 YABS 带宽测试 (仅网络)...${RESET}"
    curl -sL yabs.sh | bash -s -- -i -g
else
    echo -e "\n${GREEN}部署圆满结束。请使用 http://域名:8880 访问您的面板。${RESET}"
fi
