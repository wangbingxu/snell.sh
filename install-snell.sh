#!/bin/bash

# Color definitions for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "$1"
}

log_success() {
    echo -e "${GREEN}$1${NC}"
}

log_error() {
    echo -e "${RED}$1${NC}"
}

log_step() {
    echo -e "${YELLOW}$1${NC}"
}

# Global variables
INSTALL_DIR="/etc/snell"
CONF_PATH="/etc/snell/snell-server.conf"
BINARY_PATH="/usr/local/bin/snell-server"
SERVICE_NAME="snell"
DEFAULT_PORT="14433"
OFFICIAL_KB_URL="https://kb.nssurge.com/surge-knowledge-base/release-notes/snell"
TUI_TOOL=""

# ==========================================================
# TUI / 交互层
# ==========================================================

# 检测可用的 TUI 工具
detect_tui() {
    if command -v whiptail >/dev/null 2>&1; then
        TUI_TOOL="whiptail"
    elif command -v dialog >/dev/null 2>&1; then
        TUI_TOOL="dialog"
    else
        TUI_TOOL=""
    fi
}

tui_enabled() {
    [ -n "$TUI_TOOL" ]
}

ui_menu() {
    local title="$1"; shift
    local prompt="$1"; shift

    if tui_enabled; then
        $TUI_TOOL --title "$title" --menu "$prompt" 20 75 10 "$@" 3>&1 1>&2 2>&3
        return $?
    fi

    {
        echo
        echo "=============================================================="
        echo "  $title"
        echo "=============================================================="
        echo "$prompt"
        echo
        local tag item
        local args=("$@")
        local i=0
        while [ $i -lt ${#args[@]} ]; do
            tag="${args[$i]}"
            item="${args[$((i + 1))]}"
            echo "  $tag) $item"
            i=$((i + 2))
        done
        echo
    } >&2
    local choice
    read -r -p "输入选项: " choice >&2
    echo "$choice"
}

ui_input() {
    local title="$1"
    local prompt="$2"
    local default="$3"

    if tui_enabled; then
        $TUI_TOOL --title "$title" --inputbox "$prompt" 12 75 "$default" 3>&1 1>&2 2>&3
        return $?
    fi

    local input
    read -r -p "$prompt [默认: $default]: " input >&2
    if [ -z "$input" ]; then
        echo "$default"
    else
        echo "$input"
    fi
}

ui_yesno() {
    local title="$1"
    local prompt="$2"

    if tui_enabled; then
        $TUI_TOOL --title "$title" --yesno "$prompt" 12 75
        return $?
    fi

    local confirm
    read -r -p "$prompt (Y/n): " confirm >&2
    if [[ $confirm =~ ^[Nn]$ ]]; then
        return 1
    fi
    return 0
}

ui_msgbox() {
    local title="$1"
    local content="$2"

    if tui_enabled; then
        $TUI_TOOL --title "$title" --msgbox "$content" 20 75
        return
    fi

    echo
    echo "=============================================================="
    echo "  $title"
    echo "=============================================================="
    echo -e "$content"
    echo "=============================================================="
    read -r -p "按回车键继续..." _
}

show_banner() {
    if tui_enabled; then
        return
    fi
    clear
    echo "=============================================================="
    echo "              Snell Server Installer & Manager"
    echo "=============================================================="
    echo
}

# ==========================================================
# 基础检查与网络提取
# ==========================================================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 权限运行此脚本"
        exit 1
    fi
}

check_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        return 1
    else
        return 0
    fi
}

detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        i386|i686)
            echo "i386"
            ;;
        armv7l)
            echo "armv7l"
            ;;
        *)
            log_error "不支持的架构: $arch"
            exit 1
            ;;
    esac
}

is_installed() {
    if [ -f "$BINARY_PATH" ]; then
        return 0
    else
        return 1
    fi
}

install_dependencies() {
    log_step "检查并安装基础依赖 (curl, unzip)..."
    local pkgs=""
    command -v curl >/dev/null 2>&1 || pkgs="$pkgs curl"
    command -v unzip >/dev/null 2>&1 || pkgs="$pkgs unzip"

    if [ -n "$pkgs" ]; then
        if command -v apt >/dev/null 2>&1; then
            apt update && apt install -y $pkgs
        elif command -v yum >/dev/null 2>&1; then
            yum install -y $pkgs
        elif command -v apk >/dev/null 2>&1; then
            apk add $pkgs
        else
            log_error "未找到支持的包管理器 (apt/yum/apk)"
            exit 1
        fi
    fi
}

# 从官方发布页面抓取下载链接
get_official_download_url() {
    local arch=$1
    local html
    html=$(curl -sL --connect-timeout 10 "$OFFICIAL_KB_URL")
    if [ -z "$html" ]; then
        echo ""
        return
    fi

    # 优先匹配全架构规则 URL
    local target_url
    target_url=$(echo "$html" | grep -oE "https://dl\.nssurge\.com/snell/snell-server-[^\"]*-linux-${arch}\.zip" | head -n 1)

    if [ -z "$target_url" ]; then
        # 兼容备用架构命名规则
        target_url=$(echo "$html" | grep -oE "https://dl\.nssurge\.com/snell/snell-server-[^\"]*\.zip" | grep -i "$arch" | head -n 1)
    fi

    echo "$target_url"
}

# 交互获取完整的下载链接
resolve_snell_url() {
    local arch=$(detect_arch)
    log_step "正在从官方页面获取 Snell ($arch) 最新下载地址..." >&2

    local fetched_url
    fetched_url=$(get_official_download_url "$arch")

    local final_url
    final_url=$(ui_input "Snell 下载地址确认" \
        "已尝试获取下载链接，请检查或手动贴入完整地址：" \
        "$fetched_url")

    if [ $? -ne 0 ] || [ -z "$final_url" ]; then
        log_error "未提供有效的下载链接" >&2
        return 1
    fi

    echo "$final_url"
}

generate_psk() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 24 | tr -d '/+' | cut -c1-32
    else
        tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
    fi
}

# ==========================================================
# 业务逻辑
# ==========================================================

install_snell() {
    log_step "开始安装 Snell Server..."

    if is_installed; then
        ui_msgbox "提示" "Snell 已安装。\n如需更新版本，请使用主菜单中的升级选项。"
        return
    fi

    install_dependencies

    local download_url
    download_url=$(resolve_snell_url)
    if [ $? -ne 0 ]; then
        ui_msgbox "错误" "未指定有效的下载 URL，安装已取消。"
        return 1
    fi

    while true; do
        local input_port
        input_port=$(ui_input "监听端口" "请输入 Snell 监听端口 (1-65535)：" "$DEFAULT_PORT")
        if [ $? -ne 0 ]; then
            log_info "安装已取消"
            return
        fi
        if [[ "$input_port" =~ ^[0-9]+$ ]] && (( input_port >= 1 && input_port <= 65535 )); then
            DEFAULT_PORT="$input_port"
            break
        else
            ui_msgbox "错误" "端口号无效，请输入 1-65535 之间的数字。"
        fi
    done

    # 准备临时目录并下载
    local tmp_dir
    tmp_dir=$(mktemp -d)
    log_step "正在下载 Snell 服务端文件..."
    log_info "URL: $download_url"

    if ! curl -L -o "$tmp_dir/snell.zip" "$download_url"; then
        rm -rf "$tmp_dir"
        ui_msgbox "错误" "下载失败，请检查网络连接或 URL 正确性。"
        return 1
    fi

    log_step "解压二进制文件..."
    unzip -o "$tmp_dir/snell.zip" -d "$tmp_dir" >/dev/null 2>&1
    if [ ! -f "$tmp_dir/snell-server" ]; then
        rm -rf "$tmp_dir"
        ui_msgbox "错误" "压缩包内未找到 snell-server 二进制文件。"
        return 1
    fi

    mv "$tmp_dir/snell-server" "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
    rm -rf "$tmp_dir"

    # 生成配置
    mkdir -p "$INSTALL_DIR"
    if [ ! -f "$CONF_PATH" ]; then
        local psk
        psk=$(generate_psk)
        cat > "$CONF_PATH" << EOF
[snell-server]
listen = 0.0.0.0:${DEFAULT_PORT}
psk = ${psk}
ipv6 = true
EOF
        log_success "默认配置文件已生成: $CONF_PATH"
    fi

    if ! check_systemd; then
        ui_msgbox "安装完成" "警告：未检测到 systemd。\n二进制文件置于: $BINARY_PATH\n配置文件置于: $CONF_PATH"
        return
    fi

    create_systemd_service

    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME}.service
    systemctl start ${SERVICE_NAME}.service

    if systemctl is-active --quiet ${SERVICE_NAME}.service; then
        show_access_info
    else
        ui_msgbox "错误" "Snell 服务启动失败，请检查配置文件或系统日志。"
        return 1
    fi
}

upgrade_snell() {
    log_step "升级 Snell Server..."

    if ! is_installed; then
        ui_msgbox "错误" "Snell 未安装。请先执行安装。"
        return 1
    fi

    install_dependencies

    local download_url
    download_url=$(resolve_snell_url)
    if [ $? -ne 0 ]; then
        ui_msgbox "错误" "未指定有效的下载 URL，升级已取消。"
        return 1
    fi

    log_step "备份当前二进制文件..."
    cp "$BINARY_PATH" "${BINARY_PATH}.backup.$(date +%Y%m%d_%H%M%S)"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    log_step "下载更新文件..."

    if ! curl -L -o "$tmp_dir/snell.zip" "$download_url"; then
        rm -rf "$tmp_dir"
        ui_msgbox "错误" "下载更新文件失败。"
        return 1
    fi

    unzip -o "$tmp_dir/snell.zip" -d "$tmp_dir" >/dev/null 2>&1
    if [ ! -f "$tmp_dir/snell-server" ]; then
        rm -rf "$tmp_dir"
        ui_msgbox "错误" "更新压缩包损坏或格式不符。"
        return 1
    fi

    if check_systemd; then
        systemctl stop ${SERVICE_NAME}.service
    fi

    mv "$tmp_dir/snell-server" "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
    rm -rf "$tmp_dir"

    log_success "二进制文件替换成功 (原配置文件 $CONF_PATH 已完全保留)。"

    if check_systemd; then
        systemctl start ${SERVICE_NAME}.service
    fi

    if ui_yesno "升级完成" "Snell 核心升级成功！\n\n是否需要现在编辑配置文件 ($CONF_PATH)？"; then
        edit_config
    fi
}

create_systemd_service() {
    log_step "创建 systemd 服务文件..."
    local service_file="/etc/systemd/system/${SERVICE_NAME}.service"
    cat > "$service_file" << EOF
[Unit]
Description=Snell Server Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=${BINARY_PATH} -c ${CONF_PATH}
Restart=on-failure
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    log_success "systemd 服务配置创建完成"
}

edit_config() {
    if [ ! -f "$CONF_PATH" ]; then
        ui_msgbox "错误" "配置文件 $CONF_PATH 不存在。"
        return
    fi

    local editor="vim"
    if [ -n "$EDITOR" ]; then
        editor="$EDITOR"
    elif command -v vim >/dev/null 2>&1; then
        editor="vim"
    elif command -v vi >/dev/null 2>&1; then
        editor="vi"
    elif command -v nano >/dev/null 2>&1; then
        editor="nano"
    fi

    clear
    $editor "$CONF_PATH"

    if check_systemd && is_installed; then
        if ui_yesno "重启服务" "配置文件已修改，是否立即重启 Snell 服务以使其生效？"; then
            systemctl restart ${SERVICE_NAME}.service
            ui_msgbox "提示" "Snell 服务已重启。"
        fi
    fi
}

show_access_info() {
    local port
    local psk
    port=$(grep -E "^listen" "$CONF_PATH" | awk -F'=' '{print $2}' | tr -d ' ' | awk -F':' '{print $NF}')
    psk=$(grep -E "^psk" "$CONF_PATH" | awk -F'=' '{print $2}' | tr -d ' ')
    local ip
    ip=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')

    local content="Snell Server 运行状态及参数：\n\n"
    content+="  服务器 IP : ${ip}\n"
    content+="  端口 (Port): ${port}\n"
    content+="  密钥 (PSK) : ${psk}\n"
    content+="  配置文件  : ${CONF_PATH}\n\n"
    content+="服务管理指令：\n"
    content+="  状态: systemctl status $SERVICE_NAME\n"
    content+="  启动: systemctl start $SERVICE_NAME\n"
    content+="  停止: systemctl stop $SERVICE_NAME\n"
    content+="  重启: systemctl restart $SERVICE_NAME"

    ui_msgbox "配置与信息" "$content"
}

uninstall_snell() {
    log_step "卸载 Snell Server..."

    if ! is_installed && [ ! -f "$CONF_PATH" ]; then
        ui_msgbox "提示" "未检测到已安装的 Snell Server。"
        return 0
    fi

    if ! ui_yesno "确认卸载" "这将停止服务并删除 Snell 二进制程序。\n\n是否继续？"; then
        log_info "卸载已被取消"
        return 0
    fi

    if check_systemd; then
        log_step "停止并禁用服务..."
        systemctl stop ${SERVICE_NAME}.service >/dev/null 2>&1
        systemctl disable ${SERVICE_NAME}.service >/dev/null 2>&1
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
    fi

    log_step "清理二进制文件..."
    rm -f "$BINARY_PATH"

    if ui_yesno "清理配置" "是否一并删除配置文件目录 ($INSTALL_DIR)？"; then
        rm -rf "$INSTALL_DIR"
        log_success "配置文件及目录已删除"
    else
        log_info "配置文件已保留在 $CONF_PATH"
    fi

    ui_msgbox "卸载完成" "Snell Server 已成功卸载。"
}

show_status() {
    if ! is_installed; then
        ui_msgbox "错误" "Snell 未安装。"
        return
    fi
    if ! check_systemd; then
        ui_msgbox "错误" "未检测到 systemd 环境。"
        return
    fi
    if tui_enabled; then
        local status_output
        status_output=$(systemctl status ${SERVICE_NAME}.service --no-pager -l 2>&1)
        ui_msgbox "服务状态" "$status_output"
    else
        log_step "Snell 服务运行状态:"
        systemctl status ${SERVICE_NAME}.service --no-pager -l
        read -r -p "按回车键继续..." _
    fi
}

show_logs() {
    if ! is_installed; then
        ui_msgbox "错误" "Snell 未安装。"
        return
    fi
    if ! check_systemd; then
        ui_msgbox "错误" "未检测到 systemd 环境。"
        return
    fi
    if tui_enabled; then
        clear
    fi
    log_step "查看 Snell 服务日志 (按 Ctrl+C 退出查看)..."
    journalctl -u ${SERVICE_NAME} -f --no-pager
}

restart_service() {
    if ! is_installed; then
        ui_msgbox "错误" "Snell 未安装。"
        return
    fi
    if ! check_systemd; then
        ui_msgbox "错误" "未检测到 systemd 环境。"
        return
    fi
    log_step "重启 Snell 服务..."
    systemctl restart ${SERVICE_NAME}.service
    if systemctl is-active --quiet ${SERVICE_NAME}.service; then
        ui_msgbox "成功" "Snell 服务重启成功。"
    else
        ui_msgbox "错误" "服务重启失败，请检查配置或运行日志。"
    fi
}

stop_service() {
    if ! is_installed; then
        ui_msgbox "错误" "Snell 未安装。"
        return
    fi
    if ! check_systemd; then
        ui_msgbox "错误" "未检测到 systemd 环境。"
        return
    fi
    log_step "停止 Snell 服务..."
    systemctl stop ${SERVICE_NAME}.service
    ui_msgbox "成功" "Snell 服务已停止。"
}

# ==========================================================
# 主菜单
# ==========================================================

main_menu() {
    while true; do
        show_banner

        local choice
        choice=$(ui_menu "Snell Server 管理脚本" "请选择要执行的操作：" \
            "1" "安装 Snell Server" \
            "2" "升级 Snell Server (保留配置)" \
            "3" "编辑/查看 配置文件" \
            "4" "查看服务状态与连接参数" \
            "5" "查看运行日志" \
            "6" "重启 Snell 服务" \
            "7" "停止 Snell 服务" \
            "8" "卸载 Snell Server" \
            "9" "退出脚本")

        if [ $? -ne 0 ] && tui_enabled; then
            clear
            exit 0
        fi

        case $choice in
            1) install_snell ;;
            2) upgrade_snell ;;
            3) edit_config ;;
            4) 
                if is_installed; then
                    show_access_info
                else
                    ui_msgbox "错误" "Snell 未安装。"
                fi
                ;;
            5) show_logs ;;
            6) restart_service ;;
            7) stop_service ;;
            8) uninstall_snell ;;
            9) 
                tui_enabled && clear
                exit 0 
                ;;
            *) ui_msgbox "错误" "无效选项" ;;
        esac

        if ! tui_enabled; then
            break
        fi
    done
}

# 执行入口
check_root
detect_tui
main_menu
