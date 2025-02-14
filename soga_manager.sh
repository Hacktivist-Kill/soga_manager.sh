#!/bin/bash

##############################################################################
#                             彩色输出配置
##############################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

##############################################################################
#                           全局配置
##############################################################################
SOGA_DIR="/usr/local/soga"
BACKUP_DIR="/root/soga_backup"
LOG_FILE="/var/log/soga_manager.log"

RECOVERY_SCRIPT="/usr/local/bin/soga_recovery.sh"
CHECK_SCRIPT="/usr/local/bin/check_soga.sh"

RECOVERY_SERVICE="/etc/systemd/system/soga-recovery.service"
REBOOT_SERVICE="/etc/systemd/system/soga-autoreboot.service"
REBOOT_TIMER="/etc/systemd/system/soga-autoreboot.timer"

REBOOT_TIME="04:30"  # 默认自动重启时间

##############################################################################
#                           美观输出函数
##############################################################################
print_banner() {
    echo -e "${CYAN}"
    echo "  ____  ____   ___    ____   "
    echo " / ___||  _ \\ / _ \\  / ___|  "
    echo " \\___ \\| |_) | | | | \\___ \\  "
    echo "  ___) |  __/| |_| |  ___) | "
    echo " |____/|_|    \\___/  |____/  "
    echo "   SOGA Manager (Beautified)  "
    echo -e "${NC}"
}

log() {
    echo -e "[${BLUE}$(date '+%Y-%m-%d %H:%M:%S')${NC}] $1" | tee -a "$LOG_FILE"
}

pause() {
    echo -e "${YELLOW}按回车键继续...${NC}"
    read -r
}

##############################################################################
# 6. 主菜单
##############################################################################
show_menu() {
    echo -e "${MAGENTA}=================================================${NC}"
    echo -e "${CYAN}           SOGA 服务管理工具 (美化版)${NC}"
    echo -e "${MAGENTA}=================================================${NC}"
    echo -e "${GREEN}1.${NC} 安装/更新恢复服务 (含原子替换, 防止文本忙)"
    echo -e "${GREEN}2.${NC} 配置/修改自动重启时间"
    echo -e "${GREEN}3.${NC} 立即备份"
    echo -e "${GREEN}4.${NC} 立即恢复"
    echo -e "${GREEN}5.${NC} 查看状态"
    echo -e "${GREEN}6.${NC} 立即重启"
    echo -e "${GREEN}0.${NC} 退出"
    echo -e "${MAGENTA}=================================================${NC}"

    # 如果是交互式终端，等待用户输入
    if [[ -t 0 ]]; then
        read -p "请选择操作 [0-6]: " choice
    else
        choice=1  # 自动执行选项 1
    fi
}

##############################################################################
# 7. 主要功能逻辑
##############################################################################
main() {
    clear
    print_banner

    # 仅执行一次，不使用 while true
    show_menu
    case "$choice" in
        1)
            log "开始安装/更新恢复服务..."
            create_recovery_script
            create_check_script
            create_systemd_services
            setup_auto_reboot
            log "安装/更新完成"
            ;;
        2)
            read -p "请输入每日自动重启时间 (格式 HH:MM，默认 ${REBOOT_TIME}): " new_time
            if [[ $new_time =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                REBOOT_TIME="$new_time"
                create_systemd_services
                setup_auto_reboot
            else
                log "错误: 时间格式不正确"
            fi
            ;;
        3)
            log "执行备份..."
            "${RECOVERY_SCRIPT}" backup
            ;;
        4)
            log "执行恢复..."
            "${RECOVERY_SCRIPT}" restore
            ;;
        5)
            log "查看状态..."
            "${RECOVERY_SCRIPT}" status
            systemctl status soga-autoreboot.timer --no-pager
            ;;
        6)
            reboot_now
            ;;
        0)
            log "退出程序"
            exit 0
            ;;
        *)
            log "无效选择"
            ;;
    esac
    exit 0  # 让脚本运行完毕后退出
}

main
