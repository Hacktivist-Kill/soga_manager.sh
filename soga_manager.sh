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
    # 日志输出，同时打印到屏幕和文件
    echo -e "[${BLUE}$(date '+%Y-%m-%d %H:%M:%S')${NC}] $1" | tee -a "$LOG_FILE"
}

pause() {
    # 用于在执行完某些功能后暂停，等待用户回车
    echo -e "${YELLOW}按回车键继续...${NC}"
    read -r
}

##############################################################################
# 1. 创建恢复脚本 (soga_recovery.sh)
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

get_running_services() {
    log "获取正在运行的服务信息..."
    mkdir -p "$BACKUP_DIR"
    > "$BACKUP_DIR/service_info.txt"

    local services
    services=$(systemctl list-units --type=service --all | grep "soga_" | awk '{print $1}')
    for service in $services; do
        local service_name=${service%.service}
        local service_type
        service_type=$(echo "$service_name" | cut -d'_' -f2)
        local service_mode
        service_mode=$(echo "$service_name" | cut -d'_' -f3)
        local service_id
        service_id=$(echo "$service_name" | cut -d'_' -f4)

        echo "${service_type}|${service_mode}|${service_id}" >> "$BACKUP_DIR/service_info.txt"
        log "发现服务: ${service_type} - ${service_mode} - ${service_id}"
    done
}

backup_files() {
    log "开始备份文件..."
    
    # 1. 先删除旧备份目录（可选：如果想完全清空备份，可以用 rm -rf ）
    rm -rf "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    
    # 2. 重新获取当前正在运行的服务信息
    get_running_services
    
    # 3. 复制最新文件到备份目录
    for file in "$SOGA_DIR"/soga_*; do
        if [ -f "$file" ]; then
            cp -p "$file" "$BACKUP_DIR/"
            log "已备份: $file"
        fi
    done
}


restore_files() {
    log "开始恢复文件..."
    mkdir -p "$SOGA_DIR"

    if [ ! -f "$BACKUP_DIR/service_info.txt" ]; then
        log "错误: 找不到服务信息文件"
        return 1
    fi

    declare -A service_types
    while IFS='|' read -r type mode id; do
        service_types["$type"]=1
    done < "$BACKUP_DIR/service_info.txt"

    for type in "${!service_types[@]}"; do
        log "处理服务类型: $type"
        local configs
        configs=$(grep "^$type|" "$BACKUP_DIR/service_info.txt")
        while IFS='|' read -r t mode id; do
            local backup_file="$BACKUP_DIR/soga_${type}_${mode}_${id}"
            local target_file="$SOGA_DIR/soga_${type}_${mode}_${id}"

            if [ -f "$backup_file" ]; then
                # 原子替换：先复制到 .tmp，再 mv 到正式文件
                cp -p "$backup_file" "${target_file}.tmp"
                mv -f "${target_file}.tmp" "$target_file"
                chmod 755 "$target_file"
                chown root:root "$target_file"
                log "已恢复: $target_file"
            else
                local source_file
                source_file=$(ls "$BACKUP_DIR"/soga_${type}_* 2>/dev/null | head -n 1)
                if [ -n "$source_file" ]; then
                    cp -p "$source_file" "${target_file}.tmp"
                    mv -f "${target_file}.tmp" "$target_file"
                    chmod 755 "$target_file"
                    chown root:root "$target_file"
                    log "已从 $source_file 复制到: $target_file"
                else
                    log "错误: 无法找到 $type 类型的源文件"
                fi
            fi
        done <<< "$configs"
    done

    log "文件已恢复，正在验证..."
    ls -l "$SOGA_DIR"/soga_* 2>/dev/null || true

    # 恢复完成后，统一重启所有 soga_*.service，避免使用旧文件
    log "重启所有 soga_*.service ..."
    systemctl daemon-reload
    for svc in $(systemctl list-units --type=service --all | grep "soga_" | awk '{print $1}'); do
        systemctl restart "$svc" || true
    done
}

show_status() {
    log "当前服务状态:"
    systemctl list-units --type=service --all | grep "soga_"
    log "当前文件列表:"
    ls -l "$SOGA_DIR"/soga_* 2>/dev/null || true
}

case "$1" in
    backup)
        backup_files
        ;;
    restore)
        restore_files
        ;;
    status)
        show_status
        ;;
    *)
        echo "用法: $0 {backup|restore|status}"
        exit 1
        ;;
esac
EOF

    chmod +x "$RECOVERY_SCRIPT"
    log "恢复脚本已创建: $RECOVERY_SCRIPT"
}

##############################################################################
# 2. 创建检查脚本 (check_soga.sh)
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
    local failed=0
    local service
    for service in $(systemctl list-units --type=service --all | grep "soga_" | awk '{print $1}'); do
        if ! systemctl is-active "$service" &>/dev/null; then
            log "服务异常: $service"
            failed=1
            systemctl restart "$service"
            log "尝试重启服务: $service"
        fi
    done
    return $failed
}

check_files() {
    local missing=0
    local file
    for file in "$SOGA_DIR"/soga_*; do
        [ -e "$file" ] || continue
        if [ ! -f "$file" ] || [ ! -x "$file" ]; then
            log "文件异常: $file"
            missing=1
        fi
    done

    if [ $missing -eq 1 ]; then
        log "检测到文件异常，执行恢复..."
        /usr/local/bin/soga_recovery.sh restore
    fi

    return $missing
}

main() {
    log "开始检查SOGA服务..."
    local status=0
    check_files || status=1
    check_services || status=1

    if [ $status -eq 0 ]; then
        log "检查完成，一切正常"
    else
        log "检查完成，发现并处理了一些问题"
    fi
    return $status
}

main
EOF

    chmod +x "$CHECK_SCRIPT"
    log "检查脚本已创建: $CHECK_SCRIPT"
}

##############################################################################
# 3. 创建 systemd 单元
##############################################################################
create_systemd_services() {
    # soga-recovery.service
    cat > "/etc/systemd/system/soga-recovery.service" << EOF
[Unit]
Description=SOGA Recovery Service
Before=soga_*.service
After=network.target

[Service]
Type=oneshot
ExecStart=${RECOVERY_SCRIPT} restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    # soga-autoreboot.service
    cat > "/etc/systemd/system/soga-autoreboot.service" << EOF
[Unit]
Description=SOGA Auto-reboot Service
Before=reboot.target

[Service]
Type=oneshot
ExecStart=${CHECK_SCRIPT}
ExecStart=/sbin/reboot
EOF

    # soga-autoreboot.timer
    cat > "/etc/systemd/system/soga-autoreboot.timer" << EOF
[Unit]
Description=SOGA Daily Auto-reboot Timer

[Timer]
OnCalendar=*-*-* ${REBOOT_TIME}:00
AccuracySec=1s
Persistent=true

[Install]
WantedBy=timers.target
EOF

    log "systemd服务已创建/更新"
}

##############################################################################
# 4. 配置自动重启
##############################################################################
setup_auto_reboot() {
    log "配置自动重启..."
    systemctl daemon-reload

    # 开机先恢复文件
    systemctl enable soga-recovery.service

    # 定时重启
    systemctl enable soga-autoreboot.timer
    systemctl start soga-autoreboot.timer

    log "自动重启已配置为每天 ${REBOOT_TIME}"
}

##############################################################################
# 5. 立即重启
##############################################################################
reboot_now() {
    log "准备立即重启系统..."
    log "执行最后备份..."
    "${RECOVERY_SCRIPT}" backup

    log "系统将在 10 秒后重启..."
    sleep 10
    reboot
}

##############################################################################
# 6. 主菜单
##############################################################################
show_menu() {
    echo -e "${MAGENTA}=================================================${NC}"
    echo -e "${CYAN}           SOGA 服务管理工具 (美化版)${NC}"
    echo -e "${MAGENTA}=================================================${NC}"

    # **检测 SOGA 是否安装**
    if systemctl list-units --type=service --all | grep -q "soga_"; then
        echo -e "${GREEN}✅ 已检测到 SOGA 运行中${NC}"
        installed=true
    else
        echo -e "${YELLOW}⚠️  未检测到 SOGA 运行，将自动执行 1${NC}"
        installed=false
    fi

    echo -e "${GREEN}1.${NC} 安装/更新恢复服务 (含原子替换, 防止文本忙)"
    echo -e "${GREEN}2.${NC} 配置/修改自动重启时间"
    echo -e "${GREEN}3.${NC} 立即备份"
    echo -e "${GREEN}4.${NC} 立即恢复"
    echo -e "${GREEN}5.${NC} 查看状态"
    echo -e "${GREEN}6.${NC} 立即重启"
    echo -e "${GREEN}0.${NC} 退出"
    echo -e "${MAGENTA}=================================================${NC}"

    # **如果是交互模式，等待用户输入**
    if [[ -t 0 ]]; then
        read -p "请选择操作 [0-6]: " choice
    else
        if [ "$installed" = false ]; then
            echo -e "${YELLOW}⚠️  SOGA 未安装，自动执行 1 (安装/更新恢复服务)${NC}"
            choice=1
        else
            echo -e "${GREEN}✅ SOGA 已安装，不执行任何操作${NC}"
            exit 0
        fi
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
        2)
            read -p "请输入每日自动重启时间 (格式 HH:MM，默认 ${REBOOT_TIME}): " new_time
            if [[ $new_time =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                REBOOT_TIME="$new_time"
                create_systemd_services
                setup_auto_reboot
                log "自动重启时间已修改为 $REBOOT_TIME"
            else
                log "错误: 时间格式不正确"
            fi
            ;;
        3)
            log "开始备份数据..."
            "$RECOVERY_SCRIPT" backup
            log "备份完成"
            ;;
        4)
            log "开始恢复数据..."
            "$RECOVERY_SCRIPT" restore
            log "恢复完成"
            ;;
        5)
            log "查看服务状态..."
            "$RECOVERY_SCRIPT" status
            systemctl status soga-autoreboot.timer --no-pager
            ;;
        6)
            log "立即重启系统..."
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
    exit 0
}

main
