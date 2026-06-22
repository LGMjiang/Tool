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
        log_info "✓ UFW 未启用，无需清理规则"
        return 0
    fi

    if ! ufw status | grep -qw "${comment}"; then
        log_info "✓ 未找到相关防火墙规则"
        return 0
    fi

    # 从后往前删除，避免序号变化
    local rules
    rules=$(ufw status numbered | grep -w "${comment}" | tac)
    local count=0

    while IFS= read -r line; do
        local num
        num=$(echo "$line" | grep -oP '^\[\K[0-9]+')
        if [[ -n "$num" ]]; then
            ufw --force delete "$num" &> /dev/null
            ((count++))
        fi
    done <<< "$rules"

    if [[ $count -gt 0 ]]; then
        log_info "✓ 已删除 ${count} 条防火墙规则 (备注: ${comment})"
    else
        log_info "✓ 未找到需要删除的规则"
    fi
}

# 生成客户端配置
generate_client_config() {
    echo
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "生成客户端配置"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    log_info "正在获取服务器公网 IP..."
    local server_ip
    server_ip=$(curl -m 5 -s https://api.ipify.org || echo "")

    if [[ -z "$server_ip" ]]; then
        log_warn "无法自动获取公网 IP 地址"
        echo "提示: 配置中将使用占位符，请手动替换为您的服务器 IP"
        server_ip="YOUR_SERVER_IP"
    else
        log_info "检测到公网 IP: ${server_ip}"
    fi

    local obfs_param=""
    if [[ "${snell_obfs}" == "http" ]]; then
        obfs_param=", obfs=http"
    fi

    # 选择是否开启 reuse
    echo
    echo "【连接复用配置】"
    echo "reuse 参数可以复用 TCP 连接，提升性能"
    local reuse_param=""
    read -r -p "是否开启 reuse? (y/N): " reuse_choice
    if [[ ${reuse_choice,,} == "y" ]]; then
        reuse_param=", reuse=true"
        log_info "已启用连接复用"
    else
        log_info "未启用连接复用"
    fi

    echo
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Surge 客户端配置"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "复制以下配置到 Surge 的 [Proxy] 区块:"
    echo
    echo "name = snell, ${server_ip}, ${snell_port}, psk=${snell_password}, version=4${obfs_param}${reuse_param}"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "提示:"
    echo "  • 请将 'name' 替换为您想要的节点名称"
    echo "  • version=4 表示使用 Snell v4 协议"
    if [[ "$server_ip" == "YOUR_SERVER_IP" ]]; then
        echo "  • 请将 YOUR_SERVER_IP 替换为您的服务器实际 IP"
    fi
}

# 卸载 Snell
uninstall_snell() {
    echo
    log_warn "═══════════════════════════════════════"
    log_warn "  即将卸载 Snell 服务"
    log_warn "═══════════════════════════════════════"
    echo
    echo "以下内容将被删除:"
    echo "  • Snell 服务 (snell.service)"
    echo "  • 配置文件 (/etc/snell/)"
    echo "  • 程序文件 (/usr/local/bin/snell-server)"
    echo "  • 防火墙规则 (UFW)"
    echo
    log_warn "警告: 此操作不可恢复，请确保已备份重要配置！"
    echo
    read -r -p "确认卸载? (y/N): " confirm
    if [[ ${confirm,,} != "y" ]]; then
        log_info "已取消卸载操作"
        return 0
    fi

    echo
    log_info "开始卸载 Snell..."
    local uninstall_failed=false

    # 停止并禁用服务
    log_info "[1/6] 停止 Snell 服务..."
    if systemctl is-active --quiet snell.service; then
        if systemctl stop snell.service; then
            log_info "✓ 服务已停止"
        else
            log_warn "✗ 停止服务失败 (可能影响后续操作)"
            uninstall_failed=true
        fi
    else
        log_info "✓ 服务未运行，跳过"
    fi

    log_info "[2/6] 禁用开机自启..."
    if systemctl is-enabled --quiet snell.service 2>/dev/null; then
        if systemctl disable snell.service 2>/dev/null; then
            log_info "✓ 已禁用开机自启"
        else
            log_warn "✗ 禁用失败"
        fi
    else
        log_info "✓ 服务未启用，跳过"
    fi

    # 删除服务文件
    log_info "[3/6] 删除服务文件..."
    local service_removed=false
    if [[ -f /lib/systemd/system/snell.service ]]; then
        rm -f /lib/systemd/system/snell.service
        service_removed=true
    fi
    if [[ -f /etc/systemd/system/snell.service ]]; then
        rm -f /etc/systemd/system/snell.service
        service_removed=true
    fi
    if [[ "$service_removed" == "true" ]]; then
        systemctl daemon-reload 2>/dev/null
        log_info "✓ 服务文件已删除"
    else
        log_info "✓ 未找到服务文件，跳过"
    fi

    # 删除配置文件
    log_info "[4/6] 删除配置文件..."
    if [[ -d /etc/snell ]]; then
        rm -rf /etc/snell
        log_info "✓ 配置目录已删除 (/etc/snell/)"
    else
        log_info "✓ 配置目录不存在，跳过"
    fi

    # 删除二进制文件
    log_info "[5/6] 删除程序文件..."
    if [[ -f /usr/local/bin/snell-server ]]; then
        rm -f /usr/local/bin/snell-server
        log_info "✓ 程序文件已删除 (/usr/local/bin/snell-server)"
    else
        log_info "✓ 程序文件不存在，跳过"
    fi

    # 删除防火墙规则
    log_info "[6/6] 清理防火墙规则..."
    ufw_delete_by_comment "snell"

    # 清理临时文件
    rm -f /tmp/snell-server-*.zip /tmp/snell-server 2>/dev/null

    echo
    if [[ "$uninstall_failed" == "true" ]]; then
        log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_warn "卸载完成，但部分操作失败"
        log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "建议手动检查以下内容:"
        echo "  • 服务状态: systemctl status snell"
        echo "  • 残留文件: ls -la /usr/local/bin/snell-server"
        echo "  • 防火墙规则: ufw status"
        return 1
    else
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "Snell 已完全卸载"
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "系统已恢复到安装前的状态"
    fi
}

# 更新 Snell
update_snell() {
    if [[ -z "$current_version" ]]; then
        log_error "未检测到 Snell 服务"
        echo "请先运行安装功能，或使用以下命令检查:"
        echo "  snell-server -v"
        return 1
    fi

    if [[ "$current_version" == "v$latest_version" ]]; then
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "当前已是最新版本 (${current_version})"
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "无需更新，配置信息:"
        if [[ -f /etc/snell/snell-server.conf ]]; then
            echo "  配置文件: /etc/snell/snell-server.conf"
            echo "  服务状态: $(systemctl is-active snell.service)"
        fi
        return 0
    fi

    echo
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "发现新版本可用"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  当前版本: ${current_version}"
    echo "  最新版本: v${latest_version}"
    echo
    read -r -p "是否立即更新? (Y/n): " update_confirm
    if [[ ${update_confirm,,} == "n" ]]; then
        log_info "已取消更新操作"
        return 0
    fi

    echo
    log_info "开始更新 Snell: ${current_version} -> v${latest_version}"

    # 停止服务
    log_info "[1/5] 停止 Snell 服务..."
    if systemctl is-active --quiet snell.service; then
        if systemctl stop snell.service; then
            log_info "✓ 服务已停止"
        else
            log_error "✗ 无法停止服务"
            echo "提示: 可以尝试手动停止: systemctl stop snell.service"
            return 1
        fi
    else
        log_info "✓ 服务未运行"
    fi

    # 下载新版本
    local download_url="https://dl.nssurge.com/snell/snell-server-${latest_version}-linux-${snell_type}.zip"
    local temp_file="/tmp/snell-server-${latest_version}-linux-${snell_type}.zip"

    log_info "[2/5] 下载新版本..."
    echo "  下载地址: ${download_url}"
    if wget -q --show-progress -O "$temp_file" "$download_url" 2>&1; then
        log_info "✓ 下载完成"
    else
        log_error "✗ 下载失败"
        echo "可能原因:"
        echo "  • 网络连接问题"
        echo "  • 下载地址失效"
        echo "  • 防火墙拦截"
        systemctl start snell.service 2>/dev/null
        return 1
    fi

    # 解压
    log_info "[3/5] 解压安装包..."
    if unzip -o "$temp_file" -d /tmp/ >/dev/null 2>&1; then
        log_info "✓ 解压成功"
    else
        log_error "✗ 解压失败"
        rm -f "$temp_file"
        systemctl start snell.service 2>/dev/null
        return 1
    fi

    # 备份旧版本
    log_info "[4/5] 更新程序文件..."
    if [[ -f /usr/local/bin/snell-server ]]; then
        cp /usr/local/bin/snell-server /usr/local/bin/snell-server.backup
        log_info "✓ 已备份旧版本"
    fi

    # 安装新版本
    if mv -f /tmp/snell-server /usr/local/bin/snell-server; then
        chmod +x /usr/local/bin/snell-server
        log_info "✓ 新版本已安装"
    else
        log_error "✗ 文件安装失败"
        if [[ -f /usr/local/bin/snell-server.backup ]]; then
            mv /usr/local/bin/snell-server.backup /usr/local/bin/snell-server
            log_info "已回滚到旧版本"
        fi
        rm -f "$temp_file"
        systemctl start snell.service 2>/dev/null
        return 1
    fi

    # 清理
    rm -f "$temp_file" /usr/local/bin/snell-server.backup

    # 重启服务
    log_info "[5/5] 重启 Snell 服务..."
    if systemctl start snell.service; then
        log_info "✓ 服务启动成功"
        sleep 2
        if systemctl is-active --quiet snell.service; then
            echo
            log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_info "Snell 更新完成"
            log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  新版本: v${latest_version}"
            echo "  服务状态: 运行中"
            echo
            echo "提示: 原有配置已保留，无需重新配置客户端"
        else
            log_warn "服务启动后异常退出"
            echo "请检查日志: journalctl -u snell -n 30"
        fi
    else
        log_error "✗ 服务启动失败"
        echo "请检查日志排查问题: journalctl -u snell -n 50"
        return 1
    fi
}

# 安装 Snell
install_snell() {
    echo
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "开始安装 Snell v${latest_version}"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ -f /usr/local/bin/snell-server ]]; then
        echo
        log_warn "检测到系统中已安装 Snell"
        if [[ -n "$current_version" ]]; then
            echo "  当前版本: ${current_version}"
        fi
        echo "  程序位置: /usr/local/bin/snell-server"
        echo
        log_warn "覆盖安装将替换现有程序，但保留配置文件"
        read -r -p "是否继续覆盖安装? (y/N): " overwrite
        if [[ ${overwrite,,} != "y" ]]; then
            log_info "已取消安装操作"
            return 0
        fi
    fi

    echo
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "配置向导"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # 获取用户输入的配置信息
    echo
    echo "【端口配置】"
    read -r -p "请输入 Snell 监听端口 (留空随机生成 10000-30000): " snell_port
    snell_port=${snell_port:-$(shuf -i 10000-30000 -n 1)}
    log_info "使用端口: ${snell_port}"

    echo
    echo "【密码配置】"
    read -r -p "请输入 Snell 密码 (留空自动生成 32 位随机密码): " snell_password
    if [[ -z "$snell_password" ]]; then
        snell_password=$(openssl rand -base64 24)
        log_info "已生成随机密码"
    else
        log_info "使用自定义密码"
    fi

    echo
    echo "【混淆配置】"
    echo "HTTP 混淆可以增强流量伪装效果"
    read -r -p "是否开启 HTTP 混淆? (y/N): " enable_http_obfs
    if [[ ${enable_http_obfs,,} == "y" ]]; then
        snell_obfs="http"
        log_info "已启用 HTTP 混淆"
    else
        snell_obfs="off"
        log_info "未启用混淆"
    fi

    echo
    echo "【IPv6 配置】"
    read -r -p "是否开启 IPv6 支持? (y/N): " snell_ipv6
    if [[ ${snell_ipv6,,} == "y" ]]; then
        snell_ipv6="true"
        log_info "已启用 IPv6"
    else
        snell_ipv6="false"
        log_info "仅使用 IPv4"
    fi

    # 确认配置
    echo
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "配置信息确认"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cat << EOF
  监听端口:   ${snell_port}
  密码:       ${snell_password}
  混淆模式:   ${snell_obfs}
  IPv6:       ${snell_ipv6}
  版本:       v${latest_version}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

    echo
    read -r -p "确认配置无误，开始安装? (Y/n): " confirm
    if [[ ${confirm,,} == "n" ]]; then
        log_info "已取消安装操作"
        return 0
    fi

    # 下载并安装
    echo
    log_info "开始安装..."
    local download_url="https://dl.nssurge.com/snell/snell-server-${latest_version}-linux-${snell_type}.zip"
    local temp_file="/tmp/snell-server-${latest_version}-linux-${snell_type}.zip"

    log_info "[1/6] 下载 Snell 安装包..."
    echo "  下载地址: ${download_url}"
    if wget -q --show-progress -O "$temp_file" "$download_url" 2>&1; then
        log_info "✓ 下载完成"
    else
        log_error "✗ 下载失败"
        echo "可能原因:"
        echo "  • 网络连接问题"
        echo "  • 下载地址失效"
        echo "建议: 检查网络连接或稍后重试"
        return 1
    fi

    log_info "[2/6] 解压安装包..."
    if unzip -o "$temp_file" -d /tmp/ >/dev/null 2>&1; then
        log_info "✓ 解压成功"
    else
        log_error "✗ 解压失败"
        rm -f "$temp_file"
        return 1
    fi

    log_info "[3/6] 安装程序文件..."
    if mv -f /tmp/snell-server /usr/local/bin/snell-server; then
        chmod +x /usr/local/bin/snell-server
        log_info "✓ 程序已安装到 /usr/local/bin/snell-server"
    else
        log_error "✗ 文件安装失败"
        rm -f "$temp_file"
        return 1
    fi

    rm -f "$temp_file"

    # 创建配置目录
    log_info "[4/6] 生成配置文件..."
    mkdir -p /etc/snell

    # 创建配置文件
    cat > /etc/snell/snell-server.conf << EOF
[snell-server]
listen = 0.0.0.0:${snell_port}
psk = ${snell_password}
ipv6 = ${snell_ipv6}
obfs = ${snell_obfs}
EOF
    log_info "✓ 配置文件已生成 (/etc/snell/snell-server.conf)"

    # 创建 systemd 服务
    log_info "[5/6] 配置系统服务..."
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

    if systemctl daemon-reload; then
        log_info "✓ 服务配置已加载"
    else
        log_error "✗ 重载 systemd 失败"
        return 1
    fi

    if systemctl start snell.service; then
        log_info "✓ Snell 服务已启动"
    else
        log_error "✗ 服务启动失败"
        echo "请检查日志排查问题: journalctl -u snell -n 50"
        return 1
    fi

    if systemctl enable snell.service >/dev/null 2>&1; then
        log_info "✓ 已设置开机自启"
    else
        log_warn "✗ 设置开机自启失败 (不影响当前使用)"
    fi

    # 配置防火墙
    log_info "[6/6] 配置防火墙..."
    ufw_allow_port "${snell_port}" "snell"

    sleep 1
    echo
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Snell 安装完成！"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "安装信息:"
    echo "  版本:       v${latest_version}"
    echo "  配置文件:   /etc/snell/snell-server.conf"
    echo "  服务状态:   $(systemctl is-active snell.service)"
    echo
    echo "客户端连接信息:"
    echo "  监听端口:   ${snell_port}"
    echo "  密码:       ${snell_password}"
    echo "  混淆模式:   ${snell_obfs}"
    echo "  IPv6:       ${snell_ipv6}"
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
