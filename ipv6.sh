#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}请使用 root 权限运行：sudo $0${NC}"
        exit 1
    fi
}

# 备份文件
backup_file() {
    local file="$1"
    [ -f "$file" ] && cp "$file" "$file.bak.$(date +%Y%m%d_%H%M%S)"
}

# ==================== IPv6 控制（仅 sysctl） ====================
ipv6_available() {
    sysctl net.ipv6.conf.all.disable_ipv6 &>/dev/null
}

temp_disable_ipv6() {
    if ! ipv6_available; then
        echo -e "${RED}系统不支持 IPv6 或模块未加载。${NC}"
        return
    fi
    echo -e "${YELLOW}临时禁用 IPv6...${NC}"
    sysctl -w net.ipv6.conf.all.disable_ipv6=1
    sysctl -w net.ipv6.conf.default.disable_ipv6=1
    echo -e "${GREEN}IPv6 已临时禁用。${NC}"
}

temp_enable_ipv6() {
    if ! ipv6_available; then
        echo -e "${RED}系统不支持 IPv6 或模块未加载。${NC}"
        return
    fi
    echo -e "${YELLOW}临时启用 IPv6...${NC}"
    sysctl -w net.ipv6.conf.all.disable_ipv6=0
    sysctl -w net.ipv6.conf.default.disable_ipv6=0
    echo -e "${GREEN}IPv6 已临时启用。${NC}"
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

# ==================== 优先级控制 ====================
MARK="# ipv6_manager"

get_priority_config() {
    local gai="/etc/gai.conf"
    if grep -q "^precedence ::ffff:0:0/96.*$MARK" "$gai" 2>/dev/null; then
        echo "ipv4"
        return
    fi
    if grep -q "^label 2002::/16.*$MARK" "$gai" 2>/dev/null; then
        echo "ipv6"
        return
    fi
    echo "default"
}

# 本地分析优先级（不依赖外网）
analyze_priority_locally() {
    local result=""
    # 1. 检查是否有 IPv6 默认路由
    if ip -6 route show default 2>/dev/null | grep -q default; then
        ipv6_has_route=1
    else
        ipv6_has_route=0
    fi

    # 2. 检查 /etc/gai.conf 中的自定义规则（非脚本添加的）
    local gai="/etc/gai.conf"
    if [[ -f "$gai" ]]; then
        # 查找未注释的 precedence 行
        if grep -q '^precedence ::ffff:0:0/96' "$gai" | grep -v '^#' | grep -v "$MARK"; then
            result="ipv4"
        elif grep -q '^label 2002::/16' "$gai" | grep -v '^#' | grep -v "$MARK"; then
            result="ipv6"
        fi
    fi

    # 3. 如果仍不确定，通过 getent ahosts 测试域名解析顺序
    if [[ -z "$result" ]]; then
        # 选择一个常见的双栈域名（如 google.com），但为了避免依赖，使用本地测试
        # 实际系统默认优先级通常 IPv6 优先，但若 IPv6 路由不存在则 IPv4 优先
        if [[ $ipv6_has_route -eq 1 ]]; then
            # 有 IPv6 路由，可能是 IPv6 优先
            result="ipv6"
        else
            result="ipv4"
        fi
    fi

    echo "$result"
}

# 改进的优先级检测函数，使用外部检测 + 本地回退
check_priority_effective() {
    echo -e "${BLUE}实际检测网络优先级（IPv4/IPv6）：${NC}"
    if ! command -v curl &>/dev/null; then
        echo -e "${RED}curl 未安装，无法进行外部检测，将使用本地分析。${NC}"
        local_pri=$(analyze_priority_locally)
        if [[ "$local_pri" == "ipv4" ]]; then
            echo -e "${GREEN}本地分析：当前系统倾向于 IPv4 优先${NC}"
        elif [[ "$local_pri" == "ipv6" ]]; then
            echo -e "${GREEN}本地分析：当前系统倾向于 IPv6 优先${NC}"
        else
            echo -e "${YELLOW}本地分析：无法确定优先级，请检查网络配置。${NC}"
        fi
        return
    fi

    # 外部检测：测试 IPv4 和 IPv6 连通性
    local ipv4_reachable=0
    local ipv6_reachable=0
    local result=""

    # 测试 IPv4 可达性
    if curl -4 -s --max-time 3 -o /dev/null -w "%{http_code}" "https://ipv4.ip.sb" | grep -q "200"; then
        ipv4_reachable=1
    fi

    # 测试 IPv6 可达性
    if curl -6 -s --max-time 3 -o /dev/null -w "%{http_code}" "https://ipv6.ip.sb" | grep -q "200"; then
        ipv6_reachable=1
    fi

    # 根据双栈可达性判断优先级
    if [[ $ipv4_reachable -eq 1 && $ipv6_reachable -eq 0 ]]; then
        echo -e "${GREEN}当前生效：IPv4 优先（仅 IPv4 可达）${NC}"
        return
    elif [[ $ipv4_reachable -eq 0 && $ipv6_reachable -eq 1 ]]; then
        echo -e "${GREEN}当前生效：IPv6 优先（仅 IPv6 可达）${NC}"
        return
    elif [[ $ipv4_reachable -eq 1 && $ipv6_reachable -eq 1 ]]; then
        # 双栈都通，进一步判断优先使用哪个版本（通过 ip.sb:2095 返回的标识）
        result=$(curl -4 -s --max-time 3 "https://ip.sb:2095" 2>/dev/null | grep -Eo 'IPv[46]')
        if [[ "$result" == "IPv4" ]]; then
            echo -e "${GREEN}当前生效：IPv4 优先${NC}"
        elif [[ "$result" == "IPv6" ]]; then
            echo -e "${GREEN}当前生效：IPv6 优先${NC}"
        else
            echo -e "${YELLOW}双栈均可达，但无法判断优先级，使用本地分析...${NC}"
            local_pri=$(analyze_priority_locally)
            if [[ "$local_pri" == "ipv4" ]]; then
                echo -e "${GREEN}本地分析：系统倾向于 IPv4 优先${NC}"
            elif [[ "$local_pri" == "ipv6" ]]; then
                echo -e "${GREEN}本地分析：系统倾向于 IPv6 优先${NC}"
            else
                echo -e "${YELLOW}本地分析：无法确定，请检查网络配置。${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}外部检测失败：IPv4 和 IPv6 均不可达，使用本地分析...${NC}"
        local_pri=$(analyze_priority_locally)
        if [[ "$local_pri" == "ipv4" ]]; then
            echo -e "${GREEN}本地分析：系统倾向于 IPv4 优先${NC}"
        elif [[ "$local_pri" == "ipv6" ]]; then
            echo -e "${GREEN}本地分析：系统倾向于 IPv6 优先${NC}"
        else
            echo -e "${YELLOW}本地分析：无法确定，请检查网络配置。${NC}"
        fi
    fi
    echo ""
}

priority_ipv4() {
    echo -e "${YELLOW}设置网络优先级为 IPv4 优先...${NC}"
    backup_file "/etc/gai.conf"
    sed -i "/$MARK/d" /etc/gai.conf
    echo "precedence ::ffff:0:0/96  100 $MARK" >> /etc/gai.conf
    echo -e "${GREEN}已设置为 IPv4 优先，重启或重启网络服务后生效。${NC}"
    confirm_reboot_priority
}

priority_ipv6() {
    echo -e "${YELLOW}设置网络优先级为 IPv6 优先...${NC}"
    backup_file "/etc/gai.conf"
    sed -i "/$MARK/d" /etc/gai.conf
    echo "label 2002::/16   2 $MARK" >> /etc/gai.conf
    echo -e "${GREEN}已设置为 IPv6 优先，重启或重启网络服务后生效。${NC}"
    confirm_reboot_priority
}

priority_default() {
    echo -e "${YELLOW}还原网络优先级为系统默认...${NC}"
    backup_file "/etc/gai.conf"
    sed -i "/$MARK/d" /etc/gai.conf
    echo -e "${GREEN}已清除自定义优先级配置。${NC}"
    confirm_reboot_priority
}

confirm_reboot_priority() {
    echo -e "${YELLOW}优先级修改后，需要重启或重启网络服务才能完全生效。${NC}"
    read -p "是否立即重启系统? (y/n): " -r ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}系统正在重启...${NC}"
        reboot
    else
        echo -e "${BLUE}已取消重启。请稍后手动重启或运行网络服务重启命令。${NC}"
    fi
}

confirm_reboot() {
    echo -e "${YELLOW}需要立即重启使 IPv6 配置完全生效吗？${NC}"
    read -p "重启系统? (y/n): " -r ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}系统正在重启...${NC}"
        reboot
    else
        echo -e "${BLUE}已取消重启。请稍后手动重启。${NC}"
    fi
}

# ==================== 查看状态 ====================
show_status() {
    echo -e "${BLUE}========== IPv6 状态 ==========${NC}"
    if ipv6_available; then
        val=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null | tr -d ' \n\r')
        if [[ "$val" == "1" ]]; then
            echo -e "IPv6 状态：${RED}已禁用${NC}"
        else
            echo -e "IPv6 状态：${GREEN}已启用${NC}"
        fi
    else
        echo -e "IPv6 状态：${RED}不可用${NC}"
    fi
    echo -e "${BLUE}===============================${NC}"
}

show_status_advanced() {
    echo -e "${BLUE}========== 优先级详细状态 ==========${NC}"
    if ipv6_available; then
        val=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null | tr -d ' \n\r')
        if [[ "$val" == "1" ]]; then
            echo -e "IPv6 状态：${RED}已禁用${NC}"
        else
            echo -e "IPv6 状态：${GREEN}已启用${NC}"
        fi
    else
        echo -e "IPv6 状态：${RED}不可用${NC}"
    fi
    echo ""

    pri=$(get_priority_config)
    case "$pri" in
        ipv4)   echo -e "配置优先级：${GREEN}IPv4 优先${NC}" ;;
        ipv6)   echo -e "配置优先级：${GREEN}IPv6 优先${NC}" ;;
        *)      echo -e "配置优先级：${YELLOW}系统默认（通常 IPv6 优先）${NC}" ;;
    esac
    echo ""

    check_priority_effective
    echo -e "${BLUE}=====================================${NC}"
}

# ==================== 主菜单 ====================
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
        case "$choice" in
            1) temp_disable_ipv6 ;;
            2) temp_enable_ipv6 ;;
            3) permanent_disable_ipv6 ;;
            4) permanent_enable_ipv6 ;;
            5) show_status ;;
            6) priority_ipv4 ;;
            7) priority_ipv6 ;;
            8) priority_default ;;
            9) show_status_advanced ;;
            0) echo -e "${GREEN}退出。${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选项。${NC}"; sleep 2; continue ;;
        esac
        echo ""
        read -p "按回车键返回主菜单..." dummy
    done
}

# 入口
check_root
main_menu