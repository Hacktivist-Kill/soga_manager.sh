#!/bin/bash

##############################################################################
# 彩色输出配置
##############################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

##############################################################################
# 全局配置
##############################################################################
SOGA_DIR="/usr/local/soga"
BACKUP_DIR="/root/soga_backup"
LOG_FILE="/var/log/soga_manager.log"

RECOVERY_SCRIPT="/usr/local/bin/soga_recovery.sh"
CHECK_SCRIPT="/usr/local/bin/check_soga.sh"

REBOOT_SERVICE="/etc/systemd/system/soga-autoreboot.service"
REBOOT_TIMER="/etc/systemd/system/soga-autoreboot.timer"

REBOOT_TIME="04:30"  # 默认自动重启时间

##############################################################################
# 日志函数
##############################################################################
log() {
    echo -e "[${BLUE}$(date '+%Y-%m-%d %H:%M:%S')${NC}] $1" | tee -a "$LOG_FILE"
}

##############################################################################
# 1. 创建恢复脚本
##############################################################################
create_recovery_script() {
    cat > "$RECOVERY_SCRIPT" << 'EOF'
#!/bin/bash
SOGA_DIR="/usr/local/soga"
BACKUP_DIR="/root/soga_backup"
LOG_FILE="/var/log/soga_recovery.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

backup_files() {
    log "开始备份..."
    rm -rf "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    cp -r "$SOGA_DIR"/* "$BACKUP_DIR/"
    log "备份完成"
}

restore_files() {
    log "开始恢复..."
    cp -r "$BACKUP_DIR"/* "$SOGA_DIR/"
    log "恢复完成"
}

case "$1" in
    backup) backup_files ;;
    restore) restore_files ;;
    *) echo "用法: $0 {backup|restore}" ;;
esac
EOF
    chmod +x "$RECOVERY_SCRIPT"
    log "恢复脚本已创建: $RECOVERY_SCRIPT"
}

##############################################################################
# 2. 创建检查脚本
##############################################################################
create_check_script() {
    cat > "$CHECK_SCRIPT" << 'EOF'
#!/bin/bash
LOG_FILE="/var/log/soga_check.log"
SOGA_DIR="/usr/local/soga"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

check_services() {
    log "检查 SOGA 服务..."
    for service in $(systemctl list-units --type=service --all | grep "soga_" | awk '{print $1}'); do
        if ! systemctl is-active "$service" &>/dev/null; then
            log "重启服务: $service"
            systemctl restart "$service"
        fi
    done
}

main() {
    check_services
}

main
EOF
    chmod +x "$CHECK_SCRIPT"
    log "检查脚本已创建: $CHECK_SCRIPT"
}

##############################################################################
# 3. 创建 systemd 服务
##############################################################################
create_systemd_services() {
    cat > "$REBOOT_SERVICE" << EOF
[Unit]
Description=SOGA Auto-reboot Service
Before=reboot.target

[Service]
Type=oneshot
ExecStart=$CHECK_SCRIPT
ExecStart=/sbin/reboot
EOF

    cat > "$REBOOT_TIMER" << EOF
[Unit]
Description=SOGA Daily Auto-reboot Timer

[Timer]
OnCalendar=*-*-* ${REBOOT_TIME}:00
AccuracySec=1s
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable soga-autoreboot.timer
    systemctl start soga-autoreboot.timer
    log "systemd 服务已创建/更新"
}

##############################################################################
# 4. 配置自动重启
##############################################################################
setup_auto_reboot() {
    log "配置自动重启..."
    create_systemd_services
}

##############################################################################
# 5. 立即重启
##############################################################################
reboot_now() {
    log "系统将在 10 秒后重启..."
    sleep 10
    reboot
}

##############################################################################
# 6. 主菜单
##############################################################################
show_menu() {
    echo -e "${MAGENTA}=================================================${NC}"
    echo -e "${CYAN}           SOGA 服务管理工具${NC}"
    echo -e "${MAGENTA}=================================================${NC}"
    echo -e "${GREEN}1.${NC} 安装/更新恢复服务"
    echo -e "${GREEN}2.${NC} 配置自动重启"
    echo -e "${GREEN}3.${NC} 立即备份"
    echo -e "${GREEN}4.${NC} 立即恢复"
    echo -e "${GREEN}5.${NC} 查看状态"
    echo -e "${GREEN}6.${NC} 立即重启"
    echo -e "${GREEN}0.${NC} 退出"
    echo -e "${MAGENTA}=================================================${NC}"

    if [[ -t 0 ]]; then
        read -p "请选择操作 [0-6]: " choice
    else
        choice=1  # 自动执行选项 1
    fi
}

##############################################################################
# 7. 主要逻辑
##############################################################################
main() {
    clear
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
        2) setup_auto_reboot ;;
        3) log "备份数据..." && "$RECOVERY_SCRIPT" backup ;;
        4) log "恢复数据..." && "$RECOVERY_SCRIPT" restore ;;
        5) log "查看系统状态..." && systemctl status soga-autoreboot.timer --no-pager ;;
        6) reboot_now ;;
        0) log "退出程序"; exit 0 ;;
        *) log "无效选择" ;;
    esac
    exit 0
}

main
