#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}请使用 root 权限运行：sudo $0${NC}"
        exit 1
    fi
}

backup_file() {
    [ -f "$1" ] && cp "$1" "$1.bak.$(date +%Y%m%d_%H%M%S)"
}

ipv6_available() {
    sysctl net.ipv6.conf.all.disable_ipv6 &>/dev/null
}

# -------------------- IPv6 控制 --------------------
temp_disable_ipv6() {
    if ! ipv6_available; then
        echo -e "${RED}IPv6 不可用。${NC}"
        return
    fi
    echo -e "${YELLOW}临时禁用 IPv6...${NC}"
    sysctl -w net.ipv6.conf.all.disable_ipv6=1
    sysctl -w net.ipv6.conf.default.disable_ipv6=1
    echo -e "${GREEN}已临时禁用 IPv6。${NC}"
}

temp_enable_ipv6() {
    if ! ipv6_available; then
        echo -e "${RED}IPv6 不可用。${NC}"
        return
    fi
    echo -e "${YELLOW}临时启用 IPv6...${NC}"
    sysctl -w net.ipv6.conf.all.disable_ipv6=0
    sysctl -w net.ipv6.conf.default.disable_ipv6=0
    echo -e "${GREEN}已临时启用 IPv6。${NC}"
}

permanent_disable_ipv6() {
    echo -e "${YELLOW}永久禁用 IPv6...${NC}"
    backup_file "/etc/sysctl.conf"
    backup_file "/etc/sysctl.d/99-ipv6-disable.conf"
    sed -i '/^net.ipv6.conf.*disable_ipv6/d' /etc/sysctl.conf
    rm -f /etc/sysctl.d/99-ipv6-disable.conf
    cat >> /etc/sysctl.conf << EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
    cat > /etc/sysctl.d/99-ipv6-disable.conf << EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
    sysctl --system >/dev/null 2>&1
    echo -e "${GREEN}永久禁用配置完成，重启后保持禁用。${NC}"
    confirm_reboot
}

permanent_enable_ipv6() {
    echo -e "${YELLOW}永久恢复 IPv6...${NC}"
    backup_file "/etc/sysctl.conf"
    backup_file "/etc/sysctl.d/99-ipv6-disable.conf"
    sed -i '/^net.ipv6.conf.*disable_ipv6/d' /etc/sysctl.conf
    rm -f /etc/sysctl.d/99-ipv6-disable.conf
    cat >> /etc/sysctl.conf << EOF
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
EOF
    sysctl --system >/dev/null 2>&1
    echo -e "${GREEN}永久恢复配置完成，重启后 IPv6 启用。${NC}"
    confirm_reboot
}

# -------------------- 优先级控制 --------------------
MARK="# ipv6_manager"

get_priority_config() {
    if grep -q "^precedence ::ffff:0:0/96.*$MARK" /etc/gai.conf 2>/dev/null; then
        echo "ipv4"
    elif grep -q "^label 2002::/16.*$MARK" /etc/gai.conf 2>/dev/null; then
        echo "ipv6"
    else
        echo "default"
    fi
}

# 本地分析（不依赖外网）
analyze_priority_locally() {
    if ip -6 route show default 2>/dev/null | grep -q default; then
        ipv6_has_route=1
    else
        ipv6_has_route=0
    fi
    if [[ -f /etc/gai.conf ]]; then
        if grep -q '^precedence ::ffff:0:0/96' /etc/gai.conf | grep -v '^#' | grep -v "$MARK"; then
            echo "ipv4"
            return
        fi
        if grep -q '^label 2002::/16' /etc/gai.conf | grep -v '^#' | grep -v "$MARK"; then
            echo "ipv6"
            return
        fi
    fi
    [[ $ipv6_has_route -eq 1 ]] && echo "ipv6" || echo "ipv4"
}

# 外部检测（使用 Cloudflare 端点，容忍重定向）
check_priority_effective() {
    echo -e "${BLUE}实际检测网络优先级（IPv4/IPv6）：${NC}"
    if ! command -v curl &>/dev/null; then
        local_pri=$(analyze_priority_locally)
        echo -e "${GREEN}本地分析（curl 未安装）：系统倾向于 ${local_pri^^} 优先${NC}"
        return
    fi

    local ipv4_reachable=0
    local ipv6_reachable=0

    # 测试 IPv4 可达性（Cloudflare DNS，接受 2xx/3xx 状态码）
    local v4_status=$(curl -4 -s --max-time 3 -o /dev/null -w "%{http_code}" "http://1.1.1.1" 2>/dev/null)
    if [[ "$v4_status" =~ ^[23] ]]; then
        ipv4_reachable=1
    fi

    # 测试 IPv6 可达性（Cloudflare IPv6 DNS）
    local v6_status=$(curl -6 -s --max-time 3 -o /dev/null -w "%{http_code}" "http://[2606:4700:4700::1111]" 2>/dev/null)
    if [[ "$v6_status" =~ ^[23] ]]; then
        ipv6_reachable=1
    fi

    if [[ $ipv4_reachable -eq 1 && $ipv6_reachable -eq 0 ]]; then
        echo -e "${GREEN}当前生效：IPv4 优先（仅 IPv4 可达）${NC}"
    elif [[ $ipv4_reachable -eq 0 && $ipv6_reachable -eq 1 ]]; then
        echo -e "${GREEN}当前生效：IPv6 优先（仅 IPv6 可达）${NC}"
    elif [[ $ipv4_reachable -eq 1 && $ipv6_reachable -eq 1 ]]; then
        # 双栈均通，通过访问 /cdn-cgi/trace 获取实际出口 IP
        local v4_ip=$(curl -4 -s --max-time 3 "http://1.1.1.1/cdn-cgi/trace" 2>/dev/null | grep "ip=" | cut -d= -f2)
        local v6_ip=$(curl -6 -s --max-time 3 "http://[2606:4700:4700::1111]/cdn-cgi/trace" 2>/dev/null | grep "ip=" | cut -d= -f2)
        if [[ -n "$v4_ip" && -z "$v6_ip" ]]; then
            echo -e "${GREEN}当前生效：IPv4 优先${NC}"
        elif [[ -z "$v4_ip" && -n "$v6_ip" ]]; then
            echo -e "${GREEN}当前生效：IPv6 优先${NC}"
        else
            # 使用默认 curl 出口
            primary_ip=$(curl -s --max-time 3 "http://1.1.1.1/cdn-cgi/trace" 2>/dev/null | grep "ip=" | cut -d= -f2)
            if [[ "$primary_ip" =~ ":" ]]; then
                echo -e "${GREEN}当前生效：IPv6 优先${NC}"
            else
                echo -e "${GREEN}当前生效：IPv4 优先${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}外部检测失败（双栈均不可达），使用本地分析...${NC}"
        local_pri=$(analyze_priority_locally)
        echo -e "${GREEN}本地分析：系统倾向于 ${local_pri^^} 优先${NC}"
    fi
    echo ""
}

priority_ipv4() {
    echo -e "${YELLOW}设置 IPv4 优先...${NC}"
    backup_file /etc/gai.conf
    sed -i "/$MARK/d" /etc/gai.conf
    echo "precedence ::ffff:0:0/96  100 $MARK" >> /etc/gai.conf
    confirm_reboot_priority
}

priority_ipv6() {
    echo -e "${YELLOW}设置 IPv6 优先...${NC}"
    backup_file /etc/gai.conf
    sed -i "/$MARK/d" /etc/gai.conf
    echo "label 2002::/16   2 $MARK" >> /etc/gai.conf
    confirm_reboot_priority
}

priority_default() {
    echo -e "${YELLOW}还原默认优先级...${NC}"
    backup_file /etc/gai.conf
    sed -i "/$MARK/d" /etc/gai.conf
    confirm_reboot_priority
}

confirm_reboot_priority() {
    echo -e "${YELLOW}需重启或重启网络服务生效。${NC}"
    read -p "立即重启? (y/n): " ans
    [[ "$ans" =~ ^[Yy]$ ]] && { echo -e "${GREEN}重启...${NC}"; reboot; } || echo -e "${BLUE}已取消。${NC}"
}

confirm_reboot() {
    echo -e "${YELLOW}需重启使配置生效。${NC}"
    read -p "立即重启? (y/n): " ans
    [[ "$ans" =~ ^[Yy]$ ]] && { echo -e "${GREEN}重启...${NC}"; reboot; } || echo -e "${BLUE}已取消。${NC}"
}

# -------------------- 状态查看 --------------------
show_status() {
    echo -e "${BLUE}========== IPv6 状态 ==========${NC}"
    if ipv6_available; then
        val=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null | tr -d ' \n\r')
        [[ "$val" == "1" ]] && echo -e "IPv6 状态：${RED}已禁用${NC}" || echo -e "IPv6 状态：${GREEN}已启用${NC}"
    else
        echo -e "IPv6 状态：${RED}不可用${NC}"
    fi
    echo -e "${BLUE}===============================${NC}"
}

show_status_advanced() {
    echo -e "${BLUE}========== 优先级详细状态 ==========${NC}"
    if ipv6_available; then
        val=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null | tr -d ' \n\r')
        [[ "$val" == "1" ]] && echo -e "IPv6 状态：${RED}已禁用${NC}" || echo -e "IPv6 状态：${GREEN}已启用${NC}"
    else
        echo -e "IPv6 状态：${RED}不可用${NC}"
    fi
    echo ""
    pri=$(get_priority_config)
    case $pri in
        ipv4) echo -e "配置优先级：${GREEN}IPv4 优先${NC}" ;;
        ipv6) echo -e "配置优先级：${GREEN}IPv6 优先${NC}" ;;
        *)    echo -e "配置优先级：${YELLOW}系统默认（通常 IPv6 优先）${NC}" ;;
    esac
    echo ""
    check_priority_effective
    echo -e "${BLUE}=====================================${NC}"
}

# -------------------- 主菜单 --------------------
main_menu() {
    while true; do
        clear
        echo -e "${GREEN}========== 网络配置管理脚本 ==========${NC}"
        echo -e "${GREEN}[1]${NC} 临时禁用 IPv6"
        echo -e "${GREEN}[2]${NC} 临时启用 IPv6"
        echo -e "${GREEN}[3]${NC} 永久禁用 IPv6"
        echo -e "${GREEN}[4]${NC} 永久恢复 IPv6"
        echo -e "${GREEN}[5]${NC} 查看 IPv6 当前状态"
        echo -e "${GREEN}[6]${NC} 优先使用 IPv4 访问网络"
        echo -e "${GREEN}[7]${NC} 优先使用 IPv6 访问网络"
        echo -e "${GREEN}[8]${NC} 还原网络优先级为默认"
        echo -e "${GREEN}[9]${NC} 优先级详细状态"
        echo -e "${GREEN}[0]${NC} 退出"
        echo -n "请选择 [0-9]: "
        read -r choice
        case $choice in
            1) temp_disable_ipv6 ;;
            2) temp_enable_ipv6 ;;
            3) permanent_disable_ipv6 ;;
            4) permanent_enable_ipv6 ;;
            5) show_status ;;
            6) priority_ipv4 ;;
            7) priority_ipv6 ;;
            8) priority_default ;;
            9) show_status_advanced ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项。${NC}"; sleep 2 ;;
        esac
        echo ""
        read -p "按回车键返回主菜单..." dummy
    done
}

check_root
main_menu
