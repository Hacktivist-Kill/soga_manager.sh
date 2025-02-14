#!/bin/bash
set -euo pipefail

##############################################################################
# 捕捉信号，确保中断时正常退出
##############################################################################
trap 'echo -e "\n${YELLOW}程序中断，正在退出...${NC}"; exit 1' SIGINT SIGTERM

##############################################################################
# 检查是否以 root 用户运行
##############################################################################
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请以 root 用户运行该脚本${NC}"
    exit 1
fi

##############################################################################
#                             彩色输出配置
##############################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'  # No Color

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
    # 同时将日志输出到屏幕和日志文件
    echo -e "[${BLUE}$(date '+%Y-%m-%d %H:%M:%S')${NC}] $1" | tee -a "$LOG_FILE"
}

pause() {
    echo -e "${YELLOW}按回车键继续...${NC}"
    read -r
}

##############################################################################
# 自动检测必需文件，若缺失则自动安装/更新
##############################################################################
auto_install_if_missing() {
    local missing=0

    if [ ! -f "$RECOVERY_SCRIPT" ]; then
        log "恢复脚本不存在，准备自动安装更新..."
        missing=1
    fi
    if [ ! -f "$CHECK_SCRIPT" ]; then
        log "检查脚本不存在，准备自动安装更新..."
        missing=1
    fi
    if [ ! -f "$RECOVERY_SERVICE" ]; then
        log "systemd 单元文件 soga-recovery.service 不存在，准备自动安装更新..."
        missing=1
    fi
    if [ ! -f "$REBOOT_SERVICE" ]; then
        log "systemd 单元文件 soga-autoreboot.service 不存在，准备自动安装更新..."
        missing=1
    fi
    if [ ! -f "$REBOOT_TIMER" ]; then
        log "systemd 单元文件 soga-autoreboot.timer 不存在，准备自动安装更新..."
        missing=1
    fi

    if [ "$missing" -eq 1 ]; then
        log "缺失部分文件，自动执行安装/更新流程..."
        create_recovery_script
        create_check_script
        create_systemd_services
        setup_auto_reboot
        log "安装/更新完成"
    else
        log "所有必需文件已存在。"
    fi
}

##############################################################################
# 显示必需文件状态（美化显示）
##############################################################################
display_required_files_status() {
    echo -e "${MAGENTA}================= 必需文件状态 =================${NC}"
    for file in "$RECOVERY_SCRIPT" "$CHECK_SCRIPT" "$RECOVERY_SERVICE" "$REBOOT_SERVICE" "$REBOOT_TIMER"; do
        if [ -f "$file" ]; then
            echo -e "${GREEN}存在:${NC} $file"
        else
            echo -e "${RED}缺失:${NC} $file"
        fi
    done
    echo -e "${MAGENTA}==================================================${NC}"
}

##############################################################################
# 1. 创建恢复脚本 (soga_recovery.sh)
##############################################################################
create_recovery_script() {
    cat > "$RECOVERY_SCRIPT" << 'EOF'
#!/bin/bash
set -euo pipefail

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
        local service_type=$(echo "$service_name" | cut -d'_' -f2)
        local service_mode=$(echo "$service_name" | cut -d'_' -f3)
        local service_id=$(echo "$service_name" | cut -d'_' -f4)
        echo "${service_type}|${service_mode}|${service_id}" >> "$BACKUP_DIR/service_info.txt"
        log "发现服务: ${service_type} - ${service_mode} - ${service_id}"
    done
}

backup_files() {
    log "开始备份文件..."
    rm -rf "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    get_running_services
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
        local configs=$(grep "^$type|" "$BACKUP_DIR/service_info.txt")
        while IFS='|' read -r t mode id; do
            local backup_file="$BACKUP_DIR/soga_${type}_${mode}_${id}"
            local target_file="$SOGA_DIR/soga_${type}_${mode}_${id}"
            if [ -f "$backup_file" ]; then
                cp -p "$backup_file" "${target_file}.tmp"
                mv -f "${target_file}.tmp" "$target_file"
                chmod 755 "$target_file"
                chown root:root "$target_file"
                log "已恢复: $target_file"
            else
                local source_file=$(ls "$BACKUP_DIR"/soga_${type}_* 2>/dev/null | head -n 1)
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
    log "重启所有 soga_*.service ..."
    systemctl daemon-reload
    for svc in $(systemctl list-units --type=service --all | grep "soga_" | awk '{print $1}'); do
        systemctl restart "$svc" || true
    done
}

show_status() {
    log "详细的 SOGA 服务状态："
    for svc in $(systemctl list-units --type=service --all | grep "soga_" | awk '{print $1}'); do
        log "状态：$svc"
        systemctl status "$svc" --no-pager
        echo "----------------------------------------------------"
    done
    log "当前 SOGA 文件列表："
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
set -euo pipefail

LOG_FILE="/var/log/soga_check.log"
SOGA_DIR="/usr/local/soga"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

check_services() {
    local failed=0
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
    log "开始检查 SOGA 服务..."
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
# 3. 创建 systemd 单元文件
##############################################################################
create_systemd_services() {
    # soga-recovery.service
    cat > "$RECOVERY_SERVICE" << EOF
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
    cat > "$REBOOT_SERVICE" << EOF
[Unit]
Description=SOGA Auto-reboot Service
Before=reboot.target

[Service]
Type=oneshot
ExecStart=${CHECK_SCRIPT}
ExecStart=/sbin/reboot
EOF

    # soga-autoreboot.timer
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

    log "systemd 单元文件已创建/更新"
}

##############################################################################
# 4. 配置自动重启
##############################################################################
setup_auto_reboot() {
    log "配置自动重启..."
    systemctl daemon-reload
    systemctl enable soga-recovery.service
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
# 6. 卸载 SOGA 管理服务
##############################################################################
uninstall_soga_manager() {
    read -p "确定要卸载 SOGA 管理服务吗？这将移除所有管理文件及备份数据。请输入 yes 确认: " confirm
    if [[ "$confirm" != "yes" ]]; then
        log "取消卸载操作。"
        pause
        return
    fi

    log "正在卸载 SOGA 管理服务..."

    # 停止并禁用 systemd 服务
    systemctl stop soga-recovery.service 2>/dev/null || true
    systemctl disable soga-recovery.service 2>/dev/null || true
    systemctl stop soga-autoreboot.timer 2>/dev/null || true
    systemctl disable soga-autoreboot.timer 2>/dev/null || true
    systemctl stop soga-autoreboot.service 2>/dev/null || true
    systemctl disable soga-autoreboot.service 2>/dev/null || true

    # 删除管理文件
    for file in "$RECOVERY_SCRIPT" "$CHECK_SCRIPT" "$RECOVERY_SERVICE" "$REBOOT_SERVICE" "$REBOOT_TIMER"; do
        if [ -f "$file" ]; then
            log "正在删除文件: $file"
            rm -f "$file"
        else
            log "文件不存在: $file"
        fi
    done

    # 删除备份目录（如果存在）
    if [ -d "$BACKUP_DIR" ]; then
        log "正在删除备份目录: $BACKUP_DIR"
        rm -rf "$BACKUP_DIR"
    else
        log "备份目录不存在: $BACKUP_DIR"
    fi

    systemctl daemon-reload
    log "SOGA 管理服务及备份已卸载。"
    
    # 模拟 Ctrl+C 退出（发送 SIGINT 信号）
    kill -SIGINT $$
}

##############################################################################
# 7. 主菜单（支持循环操作）
##############################################################################
show_menu() {
    while true; do
        clear
        print_banner
        echo -e "${MAGENTA}=================================================${NC}"
        echo -e "${CYAN}           SOGA 服务管理工具 (Beautified)${NC}"
        echo -e "${MAGENTA}=================================================${NC}"

        # 修改检测逻辑：如果所有必需文件存在，则视为已安装
        if [ -f "$RECOVERY_SCRIPT" ] && [ -f "$CHECK_SCRIPT" ] && [ -f "$RECOVERY_SERVICE" ] && [ -f "$REBOOT_SERVICE" ] && [ -f "$REBOOT_TIMER" ]; then
            echo -e "${GREEN}✅ 已检测到 SOGA 已安装${NC}"
        else
            echo -e "${YELLOW}⚠️  未检测到 SOGA 已安装，自动执行安装/更新操作...${NC}"
            auto_install_if_missing
            display_required_files_status
        fi

        echo -e "${GREEN}1.${NC} 安装/更新恢复服务 (含原子替换)"
        echo -e "${GREEN}2.${NC} 配置/修改自动重启时间"
        echo -e "${GREEN}3.${NC} 立即备份"
        echo -e "${GREEN}4.${NC} 立即恢复"
        echo -e "${GREEN}5.${NC} 查看详细状态 (包含各 SOGA 服务状态)"
        echo -e "${GREEN}6.${NC} 立即重启"
        echo -e "${GREEN}7.${NC} 卸载 SOGA 管理服务"
        echo -e "${GREEN}0.${NC} 退出"
        echo -e "${MAGENTA}=================================================${NC}"

        if [[ -t 0 ]]; then
            read -p "请选择操作 [0-7] (默认为0): " choice
            choice=${choice:-0}
        else
            exit 0
        fi

        case "$choice" in
            1)
                log "开始安装/更新恢复服务..."
                create_recovery_script
                create_check_script
                create_systemd_services
                setup_auto_reboot
                log "安装/更新完成"
                pause
                ;;
            2)
                read -p "请输入每日自动重启时间 (格式 HH:MM，默认为 ${REBOOT_TIME}): " new_time
                if [[ $new_time =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                    REBOOT_TIME="$new_time"
                    create_systemd_services
                    setup_auto_reboot
                    log "自动重启时间已修改为 $REBOOT_TIME"
                else
                    log "错误: 时间格式不正确"
                fi
                pause
                ;;
            3)
                log "开始备份数据..."
                "$RECOVERY_SCRIPT" backup
                log "备份完成"
                pause
                ;;
            4)
                log "开始恢复数据..."
                "$RECOVERY_SCRIPT" restore
                log "恢复完成"
                pause
                ;;
5)
    log "查看详细服务状态..."
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] 当前服务状态:${NC}"
    # 列出所有包含 soga_ 的服务，并对状态进行颜色标记
    systemctl list-units --type=service --all | grep "soga_" | while read -r line; do
        # 如果该行包含 " active " 则标记为绿色；如果包含 " failed " 则标记为红色
        if echo "$line" | grep -q " active "; then
            echo -e "  $(echo "$line" | sed "s/ active / ${GREEN}active${NC} /g")"
        elif echo "$line" | grep -q " failed "; then
            echo -e "  $(echo "$line" | sed "s/ failed / ${RED}failed${NC} /g")"
        else
            echo "  $line"
        fi
    done

    echo ""
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] 当前 SOGA 文件列表:${NC}"
    ls -l "${SOGA_DIR}/soga_"* 2>/dev/null
    pause
    ;;

            6)
                log "立即重启系统..."
                reboot_now
                ;;
            7)
                uninstall_soga_manager
                ;;
            0)
                log "退出程序"
                exit 0
                ;;
            *)
                log "无效选择，请重新输入"
                pause
                ;;
        esac
    done
}

##############################################################################
# 8. 主要逻辑
##############################################################################
main() {
    auto_install_if_missing
    show_menu
}

main
