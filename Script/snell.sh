#!/bin/bash
# last updated:2026/06/22

set -euo pipefail  # 启用严格错误处理

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
    log_error "请切换到 root 用户后再运行脚本"
    exit 1
fi

# 检查并自动安装必要工具
check_and_install_deps() {
    local deps=("wget" "unzip" "curl")
    local to_install=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log_warn "$dep 未安装，将进行安装..."
            to_install+=("$dep")
        fi
    done

    if [[ ${#to_install[@]} -gt 0 ]]; then
        log_info "更新包管理器..."
        if ! apt update; then
            log_error "apt update 失败，请检查网络连接"
            exit 1
        fi

        log_info "安装依赖: ${to_install[*]}"
        if ! apt install -y "${to_install[@]}"; then
            log_error "依赖安装失败，请检查系统或网络连接"
            exit 1
        fi
    fi
}

check_and_install_deps

# 从官方网站获取最新版本号
get_latest_version() {
    local version
    version=$(curl -m 10 -s https://kb.nssurge.com/surge-knowledge-base/release-notes/snell | grep -oP 'snell-server-\K[^-]+' | head -1 || echo "")

    if [[ -z "$version" ]]; then
        log_error "无法获取最新版本号，请检查网络连接"
        return 1
    fi
    echo "$version"
}

latest_version=$(get_latest_version)
current_version=""

if command -v snell-server &> /dev/null; then
    current_version=$(snell-server -v 2>&1 | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "")
fi

# 检查系统架构
case "$(uname -m)" in
    x86_64)
        snell_type="amd64"
        ;;
    aarch64)
        snell_type="aarch64"
        ;;
    *)
        log_error "不支持的架构: $(uname -m)"
        exit 1
        ;;
esac

# UFW 端口管理函数
ufw_allow_port() {
    local port=$1
    local comment=$2

    if ! command -v ufw &> /dev/null; then
        log_warn "UFW 未安装，跳过防火墙配置"
        return 0
    fi

    if ! ufw status | grep -q "^Status: active"; then
        log_warn "UFW 未启用，跳过防火墙配置"
        return 0
    fi

    if ufw status | grep -Eq "^${port}(/tcp|/udp)?[[:space:]]"; then
        log_info "UFW 端口 ${port} 已存在"
        return 0
    fi

    if ufw allow "${port}" comment "${comment}" &> /dev/null; then
        log_info "UFW 已放行端口: ${port} (备注: ${comment})"
    else
        log_warn "UFW 放行端口失败: ${port}"
    fi
}

ufw_delete_by_comment() {
    local comment=$1

    if ! command -v ufw &> /dev/null; then
        return 0
    fi

    if ! ufw status | grep -q "^Status: active"; then
        log_info "UFW 未启用，跳过删除端口规则"
        return 0
    fi

    if ! ufw status | grep -qw "${comment}"; then
        log_info "UFW 未找到备注为 ${comment} 的规则"
        return 0
    fi

    # 从后往前删除，避免序号变化
    local rules
    rules=$(ufw status numbered | grep -w "${comment}" | tac)

    while IFS= read -r line; do
        local num
        num=$(echo "$line" | grep -oP '^\[\K[0-9]+')
        if [[ -n "$num" ]]; then
            ufw --force delete "$num" &> /dev/null
        fi
    done <<< "$rules"

    log_info "UFW 已删除备注为 ${comment} 的规则"
}

# 生成客户端配置
generate_client_config() {
    local server_ip
    server_ip=$(curl -m 5 -s https://api.ipify.org || echo "")

    if [[ -z "$server_ip" ]]; then
        log_warn "无法获取公网 IP，请手动替换配置中的服务器地址"
        server_ip="YOUR_SERVER_IP"
    fi

    local obfs_param=""
    if [[ "${snell_obfs}" == "http" ]]; then
        obfs_param=", obfs=http"
    fi

    # 选择是否开启 reuse
    local reuse_param=""
    read -r -p "是否开启 reuse? (y/N): " reuse_choice
    if [[ ${reuse_choice,,} == "y" ]]; then
        reuse_param=", reuse=true"
    fi

    echo
    log_info "Surge 客户端配置:"
    echo "name = snell, ${server_ip}, ${snell_port}, psk=${snell_password}, version=4${obfs_param}${reuse_param}"
}

# 卸载 Snell
uninstall_snell() {
    log_warn "即将卸载 Snell，所有配置和数据将被删除"
    read -r -p "确认卸载? (y/N): " confirm
    if [[ ${confirm,,} != "y" ]]; then
        log_info "已取消卸载"
        return 0
    fi

    local uninstall_failed=false

    # 停止并禁用服务
    if systemctl is-active --quiet snell.service; then
        systemctl stop snell.service || {
            log_warn "停止服务失败"
            uninstall_failed=true
        }
    fi

    if systemctl is-enabled --quiet snell.service 2>/dev/null; then
        systemctl disable snell.service || log_warn "禁用服务失败"
    fi

    # 删除服务文件
    [[ -f /lib/systemd/system/snell.service ]] && rm -f /lib/systemd/system/snell.service
    [[ -f /etc/systemd/system/snell.service ]] && rm -f /etc/systemd/system/snell.service
    systemctl daemon-reload 2>/dev/null

    # 删除配置文件
    [[ -d /etc/snell ]] && rm -rf /etc/snell

    # 删除二进制文件
    [[ -f /usr/local/bin/snell-server ]] && rm -f /usr/local/bin/snell-server

    # 删除防火墙规则
    ufw_delete_by_comment "snell"

    # 清理临时文件
    rm -f /tmp/snell-server-*.zip /tmp/snell-server

    if [[ "$uninstall_failed" == "true" ]]; then
        log_warn "Snell 卸载完成，但部分操作失败"
        return 1
    else
        log_info "Snell 已完全卸载"
    fi
}

# 更新 Snell
update_snell() {
    if [[ -z "$current_version" ]]; then
        log_error "未检测到 Snell，请先安装"
        return 1
    fi

    if [[ "$current_version" == "v$latest_version" ]]; then
        log_info "当前已是最新版本 (${current_version})，无需更新"
        return 0
    fi

    log_info "开始更新 Snell: ${current_version} -> v${latest_version}"

    # 停止服务
    if systemctl is-active --quiet snell.service; then
        systemctl stop snell.service || {
            log_error "无法停止 Snell 服务"
            return 1
        }
    fi

    # 下载新版本
    local download_url="https://dl.nssurge.com/snell/snell-server-${latest_version}-linux-${snell_type}.zip"
    local temp_file="/tmp/snell-server-${latest_version}-linux-${snell_type}.zip"

    log_info "下载中: ${download_url}"
    if ! wget -O "$temp_file" "$download_url"; then
        log_error "下载失败"
        systemctl start snell.service 2>/dev/null
        return 1
    fi

    # 解压
    if ! unzip -o "$temp_file" -d /tmp/; then
        log_error "解压失败"
        rm -f "$temp_file"
        systemctl start snell.service 2>/dev/null
        return 1
    fi

    # 备份旧版本
    if [[ -f /usr/local/bin/snell-server ]]; then
        cp /usr/local/bin/snell-server /usr/local/bin/snell-server.backup
    fi

    # 安装新版本
    mv -f /tmp/snell-server /usr/local/bin/snell-server || {
        log_error "移动文件失败"
        [[ -f /usr/local/bin/snell-server.backup ]] && mv /usr/local/bin/snell-server.backup /usr/local/bin/snell-server
        rm -f "$temp_file"
        systemctl start snell.service 2>/dev/null
        return 1
    }

    chmod +x /usr/local/bin/snell-server

    # 清理
    rm -f "$temp_file" /usr/local/bin/snell-server.backup

    # 重启服务
    if ! systemctl start snell.service; then
        log_error "无法重启 Snell 服务"
        return 1
    fi

    log_info "Snell 已更新到版本 v${latest_version}"
}

# 安装 Snell
install_snell() {
    if [[ -f /usr/local/bin/snell-server ]]; then
        log_warn "检测到已安装 Snell"
        read -r -p "是否覆盖安装? (y/N): " overwrite
        if [[ ${overwrite,,} != "y" ]]; then
            log_info "已取消安装"
            return 0
        fi
    fi

    # 获取用户输入的配置信息
    read -r -p "请输入 Snell 监听端口 (默认随机): " snell_port
    snell_port=${snell_port:-$(shuf -i 10000-30000 -n 1)}

    read -r -p "请输入 Snell 密码 (留空自动生成): " snell_password
    if [[ -z "$snell_password" ]]; then
        snell_password=$(openssl rand -base64 24)
    fi

    read -r -p "是否开启 HTTP 混淆? (y/N): " enable_http_obfs
    if [[ ${enable_http_obfs,,} == "y" ]]; then
        snell_obfs="http"
    else
        snell_obfs="off"
    fi

    read -r -p "是否开启 IPv6? (y/N): " snell_ipv6
    if [[ ${snell_ipv6,,} == "y" ]]; then
        snell_ipv6="true"
    else
        snell_ipv6="false"
    fi

    # 确认配置
    cat << EOF

请确认以下配置信息：
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
端口:       ${snell_port}
密码:       ${snell_password}
混淆:       ${snell_obfs}
IPv6:       ${snell_ipv6}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

    read -r -p "是否确认无误? (y/N): " confirm
    if [[ ${confirm,,} != "y" ]]; then
        log_info "已取消安装"
        return 0
    fi

    # 下载并安装
    local download_url="https://dl.nssurge.com/snell/snell-server-${latest_version}-linux-${snell_type}.zip"
    local temp_file="/tmp/snell-server-${latest_version}-linux-${snell_type}.zip"

    log_info "下载中: ${download_url}"
    if ! wget -O "$temp_file" "$download_url"; then
        log_error "下载失败"
        return 1
    fi

    if ! unzip -o "$temp_file" -d /tmp/; then
        log_error "解压失败"
        rm -f "$temp_file"
        return 1
    fi

    mv -f /tmp/snell-server /usr/local/bin/snell-server || {
        log_error "移动文件失败"
        rm -f "$temp_file"
        return 1
    }

    chmod +x /usr/local/bin/snell-server
    rm -f "$temp_file"

    # 创建配置目录
    mkdir -p /etc/snell

    # 创建配置文件
    cat > /etc/snell/snell-server.conf << EOF
[snell-server]
listen = 0.0.0.0:${snell_port}
psk = ${snell_password}
ipv6 = ${snell_ipv6}
obfs = ${snell_obfs}
EOF

    # 创建 systemd 服务
    cat > /lib/systemd/system/snell.service << EOF
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
Type=simple
User=root
Group=nogroup
LimitNOFILE=32768
ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell-server.conf
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=snell

[Install]
WantedBy=multi-user.target
EOF

    # 启动服务
    systemctl daemon-reload || {
        log_error "无法重载 systemd"
        return 1
    }

    if ! systemctl start snell.service; then
        log_error "无法启动 Snell 服务"
        log_error "请检查日志: journalctl -u snell -n 50"
        return 1
    fi

    if ! systemctl enable snell.service; then
        log_warn "无法设置开机自启"
    fi

    # 配置防火墙
    ufw_allow_port "${snell_port}" "snell"

    log_info "Snell 安装成功 (版本: v${latest_version})"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "客户端连接信息:"
    echo "端口:       ${snell_port}"
    echo "密码:       ${snell_password}"
    echo "混淆:       ${snell_obfs}"
    echo "IPv6:       ${snell_ipv6}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    generate_client_config
}

# 显示菜单
show_menu() {
    clear
    cat << EOF

    ╔═══════════════════════════════════════╗
    ║   Snell 管理脚本                     ║
    ╚═══════════════════════════════════════╝

EOF

    if [[ -n "$current_version" ]]; then
        echo "    当前版本: ${current_version}"
    else
        echo "    当前版本: 未安装"
    fi
    echo "    最新版本: v${latest_version}"
    echo
    echo "    1. 安装 Snell"
    echo "    2. 更新 Snell"
    echo "    3. 卸载 Snell"
    echo "    0. 退出脚本"
    echo

    read -r -p "    请输入选择 [0-3]: " num

    case "${num}" in
        0)
            exit 0
            ;;
        1)
            install_snell
            echo
            read -r -p "按回车返回主菜单..."
            show_menu
            ;;
        2)
            update_snell
            echo
            read -r -p "按回车返回主菜单..."
            show_menu
            ;;
        3)
            uninstall_snell
            echo
            read -r -p "按回车返回主菜单..."
            show_menu
            ;;
        *)
            log_error "请输入正确的数字 [0-3]"
            sleep 1
            show_menu
            ;;
    esac
}

# 处理命令行参数
case "${1:-}" in
    uninstall)
        uninstall_snell
        exit $?
        ;;
    update)
        update_snell
        exit $?
        ;;
    install)
        install_snell
        exit $?
        ;;
    "")
        show_menu
        ;;
    *)
        echo "用法: $0 [install|update|uninstall]"
        exit 1
        ;;
esac
