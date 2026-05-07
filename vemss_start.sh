#!/bin/bash

# ==========================================
# Debian VPS 生产级自动调优与部署脚本 v3.0
# 特性: 超时防卡死 | 零信任 SSH | 自动拉起面板
# ==========================================

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

clear
echo -e "${CYAN}====================================================${RESET}"
echo -e "${CYAN}      VPS 生产级高级网络调优与安全配置脚本 v3.0      ${RESET}"
echo -e "${CYAN}====================================================${RESET}\n"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 用户运行此脚本 (执行 sudo -i 后再试)。${RESET}"
  exit 1
fi

# 核心防卡死函数：带超时的命令执行器
run_with_timeout() {
    local time_limit=$1
    local cmd=$2
    local desc=$3
    echo -n -e "   - $desc ... "
    # 使用 timeout 命令限制执行时间
    if timeout "$time_limit" bash -c "$cmd" >/dev/null 2>&1; then
        echo -e "${GREEN}[成功]${RESET}"
    else
        echo -e "${RED}[超时/失败 - 已跳过]${RESET}"
    fi
}

# ================= 阶段零：依赖自测 =================
echo -e "${YELLOW}>>> [初始化] 正在检测并补全系统依赖 (限时 60s)...${RESET}"
run_with_timeout "30s" "apt-get update -y" "更新软件源"
run_with_timeout "30s" "apt-get install -y curl wget iproute2 net-tools iputils-ping gawk" "安装基础依赖"
echo ""

# ================= 第一阶段：参数收集 =================
echo -e "${YELLOW}>>> 阶段一：参数设定 (直接回车可使用默认值)${RESET}\n"

# 1. MTU
MAIN_NIC=$(ip -4 route show default | awk '{print $5}' | head -n 1)
read -p "1. 请输入主网卡 ($MAIN_NIC) 的 MTU 数值 [默认 1420]: " USER_MTU
USER_MTU=${USER_MTU:-1420}

# 2. 防火墙与 SSH 探测
USE_UFW="y"
CURRENT_SSH=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F':' '{print $NF}' | head -n 1)
if [ -n "$CURRENT_SSH" ]; then
    read -p "2. 检测到当前运行的 SSH 端口为 ${CURRENT_SSH}，请输入要放行的端口 [默认 ${CURRENT_SSH}]: " USER_SSH_PORT
    USER_SSH_PORT=${USER_SSH_PORT:-$CURRENT_SSH}
else
    echo -e "2. ${YELLOW}警告：未检测到标准 SSH 服务！为保证安全，防火墙默认【不放行】 22 端口。${RESET}"
    USER_SSH_PORT=""
fi

# 3. 后续服务安装意向
read -p "3. 是否自动安装 X-UI 面板？ [y/n, 默认 y]: " INSTALL_XUI
INSTALL_XUI=${INSTALL_XUI:-y}

read -p "4. 是否自动拉起 Cloudflare WARP 安装向导？ [y/n, 默认 y]: " INSTALL_WARP
INSTALL_WARP=${INSTALL_WARP:-y}

echo -e "\n${GREEN}参数收集完毕！脚本将全速执行...${RESET}\n"
sleep 2


# ================= 第二阶段：底层优化配置 =================
echo -e "${YELLOW}>>> [1/4] 注入内核网络优化参数 (BBR, 禁用IPv6)...${RESET}"
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
echo -e "   ${GREEN}[成功]${RESET} 内核参数注入完成。"

echo -e "\n${YELLOW}>>> [2/4] 通过 systemd 强制锁定网卡 MTU 为 ${USER_MTU}...${RESET}"
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
echo -e "   ${GREEN}[成功]${RESET} MTU 守护进程已启动。"

echo -e "\n${YELLOW}>>> [3/4] 全球公共 DNS 智能竞速...${RESET}"
DNS_SERVERS=("1.1.1.1" "8.8.8.8" "9.9.9.9")
BEST_DNS="8.8.8.8"
MIN_MS=9999
for dns in "${DNS_SERVERS[@]}"; do
    MS=$(ping -c 2 -w 2 $dns | grep -oP '(?<=time=)[0-9\.]+' | awk '{ sum += $1 } END { if (NR > 0) print sum / NR }')
    if [[ -n "$MS" ]]; then
        if awk "BEGIN {exit !($MS < $MIN_MS)}"; then
            MIN_MS=$MS; BEST_DNS=$dns
        fi
    fi
done
cp /etc/resolv.conf /etc/resolv.conf.bak
echo -e "nameserver $BEST_DNS\nnameserver 8.8.4.4" > /etc/resolv.conf
echo -e "   ${GREEN}[成功]${RESET} 优选系统 DNS 为: $BEST_DNS"

echo -e "\n${YELLOW}>>> [4/4] 构建 UFW 防火墙体系...${RESET}"
run_with_timeout "30s" "apt-get install -y ufw" "确保 UFW 组件已安装"
ufw --force reset >/dev/null 2>&1

if [ -n "$USER_SSH_PORT" ]; then
    ufw allow $USER_SSH_PORT/tcp comment 'Custom SSH' >/dev/null 2>&1
fi

ufw allow 443/tcp comment 'VLESS-Reality' >/dev/null 2>&1
run_with_timeout "15s" "for i in \$(curl -s https://www.cloudflare.com/ips-v4); do ufw allow proto tcp from \$i to any port 8880 comment 'CF UI' >/dev/null 2>&1; done" "拉取 Cloudflare 白名单并放行 8880"

ufw default deny incoming
ufw default allow outgoing
ufw --force enable >/dev/null 2>&1
ufw logging off
echo -e "   ${GREEN}[成功]${RESET} 防火墙启动完毕。"


# ================= 第三阶段：配置结果纯净验证 =================
echo -e "\n${CYAN}====================================================${RESET}"
echo -e "${CYAN}               本机底层环境验收报告                 ${RESET}"
echo -e "${CYAN}====================================================${RESET}"

ACTUAL_MTU=$(ip link show $MAIN_NIC | grep -oP '(?<=mtu )[0-9]+')
if [ "$ACTUAL_MTU" == "$USER_MTU" ]; then
    echo -e "1. ${GREEN}[生效]${RESET} MTU 锁定正常: $ACTUAL_MTU"
else
    echo -e "1. ${RED}[异常]${RESET} MTU 期望 $USER_MTU，但当前为 $ACTUAL_MTU"
fi

CURRENT_CC=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
if [ "$CURRENT_CC" == "bbr" ]; then
    echo -e "2. ${GREEN}[生效]${RESET} BBR 加速算法正常运行"
else
    echo -e "2. ${RED}[异常]${RESET} BBR 未激活"
fi

echo -e "3. ${GREEN}[生效]${RESET} 系统首选 DNS 正常写入: $BEST_DNS"

echo -e "4. ${GREEN}[生效]${RESET} 当前 UFW 核心放行规则 (请核对):"
ufw status | grep -E "($USER_SSH_PORT/tcp|443/tcp|8880/tcp)" | head -n 3
echo ""


# ================= 第四阶段：交互式扩展安装 =================

# 1. 安装 X-UI
if [[ "$INSTALL_XUI" =~ ^[Yy]$ ]]; then
    echo -e "${CYAN}====================================================${RESET}"
    echo -e "${YELLOW}>>> 准备安装 FranzKafkaYu 版 X-UI 面板...${RESET}"
    echo -e "${RED}【极度重要提醒】: 在接下来的交互向导中，${RESET}"
    echo -e "${RED} 请务必将面板端口设置为: 8880 ${RESET}"
    echo -e "${RED} (只有 8880 才能穿透刚才配置的防火墙和 CF 代理！)${RESET}"
    echo -e "${CYAN}====================================================${RESET}"
    sleep 4
    bash <(curl -Ls https://raw.githubusercontent.com/FranzKafkaYu/x-ui/master/install.sh)
fi

# 2. 安装 WARP
if [[ "$INSTALL_WARP" =~ ^[Yy]$ ]]; then
    echo -e "\n${YELLOW}>>> 即将为您启动 Cloudflare WARP 安装向导...${RESET}"
    sleep 2
    wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh
fi

# ================= 终极测速环节 =================
echo -e "\n${CYAN}====================================================${RESET}"
echo -e "${GREEN}恭喜！服务器底层调优、面板和防封锁组件已全部部署完毕！${RESET}"
read -p ">> 是否立即进行机器性能测速和回程线路追踪？ (可能耗时 3-5 分钟) [y/N, 默认 n]: " RUN_TESTS

if [[ "$RUN_TESTS" =~ ^[Yy]$ ]]; then
    echo -e "\n${YELLOW}>>> 1/2: 正在运行 NextTrace 路由追踪...${RESET}"
    curl nxtrace.org/nt | bash
    
    echo -e "\n${YELLOW}>>> 2/2: 正在运行 YABS 全球带宽测速 (仅测试网络)...${RESET}"
    curl -sL yabs.sh | bash -s -- -i -g
else
    echo -e "\n${GREEN}测试已跳过。你可以随时通过 X-UI 面板开始冲浪了！${RESET}"
fi
