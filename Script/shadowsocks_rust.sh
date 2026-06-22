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
    local deps=("wget" "tar" "curl" "xz-utils")
    local to_install=()

    for dep in "${deps[@]}"; do
        local cmd="$dep"
        [[ "$dep" == "xz-utils" ]] && cmd="xz"

        if ! command -v "$cmd" &> /dev/null; then
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

# 获取最新版本号
get_latest_version() {
    local version
    version=$(curl -m 10 -sL "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | grep -oP '"tag_name":\s*"\K[^"]+' || echo "")

    if [[ -z "$version" ]]; then
        log_error "无法获取最新版本号，请检查网络连接"
        return 1
    fi
    echo "$version"
}

latest_version=$(get_latest_version)
current_version=""

if command -v ssserver &> /dev/null; then
    current_version="v$(ssserver -V 2>&1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' || echo "")"
fi

# 检查系统架构
case "$(uname -m)" in
    x86_64)
        ss_type="x86_64-unknown-linux-gnu"
        ;;
    aarch64)
        ss_type="aarch64-unknown-linux-gnu"
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

    # 选择是否开启 udp
    echo
    echo "【UDP 配置】"
    local surge_udp_relay_param=", udp-relay=true"
    local mihomo_udp_param="true"

    read -r -p "是否在客户端配置中启用 UDP? (Y/n): " udp_choice
    if [[ ${udp_choice,,} == "n" ]]; then
        surge_udp_relay_param=""
        mihomo_udp_param="false"
        log_info "客户端将不使用 UDP"
    elif [[ ! ${ss_mode} =~ udp ]]; then
        log_warn "服务端未开启 UDP (mode: ${ss_mode})"
        log_warn "客户端 UDP 参数将被禁用"
        surge_udp_relay_param=""
        mihomo_udp_param="false"
    else
        log_info "客户端将启用 UDP"
    fi

    # 选择客户端
    echo
    echo "【选择客户端】"
    echo "1. Surge (iOS/macOS)"
    echo "2. Mihomo Party (跨平台)"
    echo "3. 全部生成"
    read -r -p "请选择 [1-3] (默认 3): " client_choice

    case ${client_choice:-3} in
        1)
            echo
            log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_info "Surge 客户端配置"
            log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "复制以下配置到 Surge 的 [Proxy] 区块:"
            echo
            echo "name = ss, ${server_ip}, ${ss_port}, encrypt-method=${encryption_method}, password=${ss_password}${surge_udp_relay_param}"
            ;;
        2)
            echo
            log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_info "Mihomo Party 客户端配置"
            log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "复制以下配置到 Mihomo Party 的 proxies 区块:"
            echo
            cat << EOF
- name: "shadowsocks-rust"
  type: ss
  server: ${server_ip}
  port: ${ss_port}
  cipher: ${encryption_method}
  password: "${ss_password}"
  udp: ${mihomo_udp_param}
EOF
            ;;
        *)
            echo
            log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_info "Surge 客户端配置"
            log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "复制以下配置到 Surge 的 [Proxy] 区块:"
            echo
            echo "name = ss, ${server_ip}, ${ss_port}, encrypt-method=${encryption_method}, password=${ss_password}${surge_udp_relay_param}"
            echo
            echo
            log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_info "Mihomo Party 客户端配置"
            log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "复制以下配置到 Mihomo Party 的 proxies 区块:"
            echo
            cat << EOF
- name: "shadowsocks-rust"
  type: ss
  server: ${server_ip}
  port: ${ss_port}
  cipher: ${encryption_method}
  password: "${ss_password}"
  udp: ${mihomo_udp_param}
EOF
            ;;
    esac

    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "提示:"
    echo "  • 请将 'name' 替换为您想要的节点名称"
    if [[ "$server_ip" == "YOUR_SERVER_IP" ]]; then
        echo "  • 请将 YOUR_SERVER_IP 替换为您的服务器实际 IP"
    fi
}

# 更新 Shadowsocks-Rust
update_ss() {
    if [[ -z "$current_version" ]]; then
        log_error "未检测到 Shadowsocks-Rust 服务"
        echo "请先运行安装功能，或使用以下命令检查:"
        echo "  ssserver -V"
        return 1
    fi

    if [[ "$current_version" == "$latest_version" ]]; then
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "当前已是最新版本 (${current_version})"
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "无需更新，配置信息:"
        if [[ -f /etc/ss-rust/config.json ]]; then
            echo "  配置文件: /etc/ss-rust/config.json"
            echo "  服务状态: $(systemctl is-active ss-rust.service)"
        fi
        return 0
    fi

    echo
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "发现新版本可用"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  当前版本: ${current_version}"
    echo "  最新版本: ${latest_version}"
    echo
    read -r -p "是否立即更新? (Y/n): " update_confirm
    if [[ ${update_confirm,,} == "n" ]]; then
        log_info "已取消更新操作"
        return 0
    fi

    echo
    log_info "开始更新 Shadowsocks-Rust: ${current_version} -> ${latest_version}"

    # 停止服务
    log_info "[1/5] 停止 Shadowsocks-Rust 服务..."
    if systemctl is-active --quiet ss-rust.service; then
        if systemctl stop ss-rust.service; then
            log_info "✓ 服务已停止"
        else
            log_error "✗ 无法停止服务"
            echo "提示: 可以尝试手动停止: systemctl stop ss-rust.service"
            return 1
        fi
    else
        log_info "✓ 服务未运行"
    fi

    # 下载新版本
    local download_url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${latest_version}/shadowsocks-${latest_version}.${ss_type}.tar.xz"
    local temp_file="/tmp/shadowsocks-${latest_version}.${ss_type}.tar.xz"

    log_info "[2/5] 下载新版本..."
    echo "  下载地址: ${download_url}"
    if wget -q --show-progress -O "$temp_file" "$download_url" 2>&1; then
        log_info "✓ 下载完成"
    else
        log_error "✗ 下载失败"
        echo "可能原因:"
        echo "  • 网络连接问题"
        echo "  • GitHub 访问受限"
        echo "  • 下载地址失效"
        systemctl start ss-rust.service 2>/dev/null
        return 1
    fi

    # 解压
    log_info "[3/5] 解压安装包..."
    if tar -xf "$temp_file" -C /tmp/ 2>/dev/null; then
        log_info "✓ 解压成功"
    else
        log_error "✗ 解压失败"
        rm -f "$temp_file"
        systemctl start ss-rust.service 2>/dev/null
        return 1
    fi

    # 备份旧版本
    log_info "[4/5] 更新程序文件..."
    if [[ -f /usr/local/bin/ssserver ]]; then
        cp /usr/local/bin/ssserver /usr/local/bin/ssserver.backup
        log_info "✓ 已备份旧版本"
    fi

    # 安装新版本
    if mv -f /tmp/ssserver /usr/local/bin/; then
        chmod +x /usr/local/bin/ssserver
        log_info "✓ 新版本已安装"
    else
        log_error "✗ 文件安装失败"
        if [[ -f /usr/local/bin/ssserver.backup ]]; then
            mv /usr/local/bin/ssserver.backup /usr/local/bin/ssserver
            log_info "已回滚到旧版本"
        fi
        rm -f "$temp_file"
        systemctl start ss-rust.service 2>/dev/null
        return 1
    fi

    # 清理
    rm -f /tmp/sslocal /tmp/ssmanager /tmp/ssservice /tmp/ssurl "$temp_file"
    rm -f /usr/local/bin/ssserver.backup

    # 重启服务
    log_info "[5/5] 重启 Shadowsocks-Rust 服务..."
    if systemctl start ss-rust.service; then
        log_info "✓ 服务启动成功"
        sleep 2
        if systemctl is-active --quiet ss-rust.service; then
            echo
            log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_info "Shadowsocks-Rust 更新完成"
            log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  新版本: ${latest_version}"
            echo "  服务状态: 运行中"
            echo
            echo "提示: 原有配置已保留，无需重新配置客户端"
        else
            log_warn "服务启动后异常退出"
            echo "请检查日志: journalctl -u ss-rust -n 30"
        fi
    else
        log_error "✗ 服务启动失败"
        echo "请检查日志排查问题: journalctl -u ss-rust -n 50"
        return 1
    fi
}

# 安装 Shadowsocks-Rust
install_ss() {
    echo
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "开始安装 Shadowsocks-Rust ${latest_version}"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ -f /usr/local/bin/ssserver ]]; then
        echo
        log_warn "检测到系统中已安装 Shadowsocks-Rust"
        if [[ -n "$current_version" ]]; then
            echo "  当前版本: ${current_version}"
        fi
        echo "  程序位置: /usr/local/bin/ssserver"
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
    read -r -p "请输入 Shadowsocks-Rust 监听端口 (留空随机生成 10000-30000): " ss_port
    ss_port=${ss_port:-$(shuf -i 10000-30000 -n 1)}
    log_info "使用端口: ${ss_port}"

    # 选择加密方法
    echo
    echo "【加密方法】"
    echo "1. 2022-blake3-aes-256-gcm (推荐，最安全)"
    echo "2. 2022-blake3-aes-128-gcm (平衡性能与安全)"
    echo "3. aes-256-gcm (传统加密)"
    echo "4. chacha20-ietf-poly1305 (ARM 设备友好)"
    echo "5. aes-128-gcm (高性能)"
    read -r -p "请选择 [1-5] (默认 1): " method_choice

    case ${method_choice:-1} in
        1) encryption_method="2022-blake3-aes-256-gcm" ;;
        2) encryption_method="2022-blake3-aes-128-gcm" ;;
        3) encryption_method="aes-256-gcm" ;;
        4) encryption_method="chacha20-ietf-poly1305" ;;
        5) encryption_method="aes-128-gcm" ;;
        *) encryption_method="2022-blake3-aes-256-gcm" ;;
    esac
    log_info "加密方法: ${encryption_method}"

    # 生成或输入密码
    echo
    echo "【密码配置】"
    read -r -p "请输入 Shadowsocks 密码 (留空自动生成): " ss_password
    if [[ -z "$ss_password" ]]; then
        if [[ "$encryption_method" == "2022-blake3-aes-256-gcm" ]]; then
            ss_password=$(openssl rand -base64 32)
        elif [[ "$encryption_method" == "2022-blake3-aes-128-gcm" ]]; then
            ss_password=$(openssl rand -base64 16)
        else
            ss_password=$(openssl rand -base64 24)
        fi
        log_info "已生成随机密码"
    else
        log_info "使用自定义密码"
    fi

    # 选择传输模式
    echo
    echo "【传输模式】"
    echo "1. tcp_and_udp (推荐，支持 UDP 游戏和语音)"
    echo "2. tcp_only (仅 TCP)"
    echo "3. udp_only (仅 UDP)"
    read -r -p "请选择 [1-3] (默认 1): " mode_choice

    case ${mode_choice:-1} in
        1) ss_mode="tcp_and_udp" ;;
        2) ss_mode="tcp_only" ;;
        3) ss_mode="udp_only" ;;
        *) ss_mode="tcp_and_udp" ;;
    esac
    log_info "传输模式: ${ss_mode}"

    # TCP Fast Open
    echo
    echo "【TCP Fast Open】"
    echo "TFO 可以减少连接延迟，但需要内核支持"
    read -r -p "是否开启 TCP Fast Open? (y/N): " enable_tfo
    if [[ ${enable_tfo,,} == "y" ]]; then
        ss_tfo=true
        log_info "已启用 TCP Fast Open"
    else
        ss_tfo=false
        log_info "未启用 TCP Fast Open"
    fi

    # 确认配置
    echo
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "配置信息确认"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cat << EOF
  监听端口:      ${ss_port}
  密码:          ${ss_password}
  加密方法:      ${encryption_method}
  传输模式:      ${ss_mode}
  TCP Fast Open: ${ss_tfo}
  版本:          ${latest_version}
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
    local download_url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${latest_version}/shadowsocks-${latest_version}.${ss_type}.tar.xz"
    local temp_file="/tmp/shadowsocks-${latest_version}.${ss_type}.tar.xz"

    log_info "[1/6] 下载 Shadowsocks-Rust 安装包..."
    echo "  下载地址: ${download_url}"
    if wget -q --show-progress -O "$temp_file" "$download_url" 2>&1; then
        log_info "✓ 下载完成"
    else
        log_error "✗ 下载失败"
        echo "可能原因:"
        echo "  • 网络连接问题"
        echo "  • GitHub 访问受限"
        echo "  • 下载地址失效"
        echo "建议: 检查网络连接或使用代理"
        return 1
    fi

    log_info "[2/6] 解压安装包..."
    if tar -xf "$temp_file" -C /tmp/ 2>/dev/null; then
        log_info "✓ 解压成功"
    else
        log_error "✗ 解压失败"
        rm -f "$temp_file"
        return 1
    fi

    log_info "[3/6] 安装程序文件..."
    if mv -f /tmp/ssserver /usr/local/bin/; then
        chmod +x /usr/local/bin/ssserver
        log_info "✓ 程序已安装到 /usr/local/bin/ssserver"
    else
        log_error "✗ 文件安装失败"
        rm -f "$temp_file"
        return 1
    fi

    rm -f /tmp/sslocal /tmp/ssmanager /tmp/ssservice /tmp/ssurl "$temp_file"

    # 创建配置目录
    log_info "[4/6] 生成配置文件..."
    mkdir -p /etc/ss-rust

    # 创建配置文件
    cat > /etc/ss-rust/config.json << EOF
{
    "server": "0.0.0.0",
    "server_port": ${ss_port},
    "password": "${ss_password}",
    "method": "${encryption_method}",
    "mode": "${ss_mode}",
    "timeout": 300,
    "nameserver": "8.8.8.8",
    "fast_open": ${ss_tfo}
}
EOF
    log_info "✓ 配置文件已生成 (/etc/ss-rust/config.json)"

    # 创建 systemd 服务
    log_info "[5/6] 配置系统服务..."
    cat > /lib/systemd/system/ss-rust.service << EOF
[Unit]
Description=Shadowsocks Rust Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
LimitNOFILE=32767
Restart=on-failure
RestartSec=5s
ExecStartPre=/bin/sh -c 'ulimit -n 51200'
ExecStart=/usr/local/bin/ssserver -c /etc/ss-rust/config.json
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ss-rust

[Install]
WantedBy=multi-user.target
EOF

    if systemctl daemon-reload; then
        log_info "✓ 服务配置已加载"
    else
        log_error "✗ 重载 systemd 失败"
        return 1
    fi

    if systemctl start ss-rust.service; then
        log_info "✓ Shadowsocks-Rust 服务已启动"
    else
        log_error "✗ 服务启动失败"
        echo "请检查日志排查问题: journalctl -u ss-rust -n 50"
        return 1
    fi

    if systemctl enable ss-rust.service >/dev/null 2>&1; then
        log_info "✓ 已设置开机自启"
    else
        log_warn "✗ 设置开机自启失败 (不影响当前使用)"
    fi

    # 配置防火墙
    log_info "[6/6] 配置防火墙..."
    ufw_allow_port "${ss_port}" "ss-rust"

    sleep 1
    echo
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Shadowsocks-Rust 安装完成！"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "安装信息:"
    echo "  版本:          ${latest_version}"
    echo "  配置文件:      /etc/ss-rust/config.json"
    echo "  服务状态:      $(systemctl is-active ss-rust.service)"
    echo
    echo "客户端连接信息:"
    echo "  监听端口:      ${ss_port}"
    echo "  密码:          ${ss_password}"
    echo "  加密方法:      ${encryption_method}"
    echo "  传输模式:      ${ss_mode}"
    echo "  TCP Fast Open: ${ss_tfo}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    generate_client_config
}

# 卸载 Shadowsocks-Rust
uninstall_ss() {
    echo
    log_warn "═══════════════════════════════════════"
    log_warn "  即将卸载 Shadowsocks-Rust 服务"
    log_warn "═══════════════════════════════════════"
    echo
    echo "以下内容将被删除:"
    echo "  • Shadowsocks-Rust 服务 (ss-rust.service)"
    echo "  • 配置文件 (/etc/ss-rust/)"
    echo "  • 程序文件 (/usr/local/bin/ssserver)"
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
    log_info "开始卸载 Shadowsocks-Rust..."
    local uninstall_failed=false

    # 停止并禁用服务
    log_info "[1/6] 停止 Shadowsocks-Rust 服务..."
    if systemctl is-active --quiet ss-rust.service; then
        if systemctl stop ss-rust.service; then
            log_info "✓ 服务已停止"
        else
            log_warn "✗ 停止服务失败 (可能影响后续操作)"
            uninstall_failed=true
        fi
    else
        log_info "✓ 服务未运行，跳过"
    fi

    log_info "[2/6] 禁用开机自启..."
    if systemctl is-enabled --quiet ss-rust.service 2>/dev/null; then
        if systemctl disable ss-rust.service 2>/dev/null; then
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
    if [[ -f /lib/systemd/system/ss-rust.service ]]; then
        rm -f /lib/systemd/system/ss-rust.service
        service_removed=true
    fi
    if [[ -f /etc/systemd/system/ss-rust.service ]]; then
        rm -f /etc/systemd/system/ss-rust.service
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
    if [[ -d /etc/ss-rust ]]; then
        rm -rf /etc/ss-rust
        log_info "✓ 配置目录已删除 (/etc/ss-rust/)"
    else
        log_info "✓ 配置目录不存在，跳过"
    fi

    # 删除二进制文件
    log_info "[5/6] 删除程序文件..."
    if [[ -f /usr/local/bin/ssserver ]]; then
        rm -f /usr/local/bin/ssserver
        log_info "✓ 程序文件已删除 (/usr/local/bin/ssserver)"
    else
        log_info "✓ 程序文件不存在，跳过"
    fi

    # 删除备份文件
    [[ -f /usr/local/bin/ssserver.backup ]] && rm -f /usr/local/bin/ssserver.backup

    # 删除防火墙规则
    log_info "[6/6] 清理防火墙规则..."
    ufw_delete_by_comment "ss-rust"

    # 清理临时文件
    rm -f /tmp/shadowsocks-*.tar.xz /tmp/ssserver /tmp/sslocal /tmp/ssmanager /tmp/ssservice /tmp/ssurl 2>/dev/null

    echo
    if [[ "$uninstall_failed" == "true" ]]; then
        log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_warn "卸载完成，但部分操作失败"
        log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "建议手动检查以下内容:"
        echo "  • 服务状态: systemctl status ss-rust"
        echo "  • 残留文件: ls -la /usr/local/bin/ssserver"
        echo "  • 防火墙规则: ufw status"
        return 1
    else
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "Shadowsocks-Rust 已完全卸载"
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "系统已恢复到安装前的状态"
    fi
}

# 显示菜单
show_menu() {
    clear
    cat << EOF

    ╔═══════════════════════════════════════╗
    ║   Shadowsocks-Rust 管理脚本          ║
    ╚═══════════════════════════════════════╝

EOF

    if [[ -n "$current_version" ]]; then
        echo "    当前版本: ${current_version}"
    else
        echo "    当前版本: 未安装"
    fi
    echo "    最新版本: ${latest_version}"
    echo
    echo "    1. 安装 Shadowsocks-Rust"
    echo "    2. 更新 Shadowsocks-Rust"
    echo "    3. 卸载 Shadowsocks-Rust"
    echo "    0. 退出脚本"
    echo

    read -r -p "    请输入选择 [0-3]: " num

    case "${num}" in
        0)
            exit 0
            ;;
        1)
            install_ss
            echo
            read -r -p "按回车返回主菜单..."
            show_menu
            ;;
        2)
            update_ss
            echo
            read -r -p "按回车返回主菜单..."
            show_menu
            ;;
        3)
            uninstall_ss
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
        uninstall_ss
        exit $?
        ;;
    update)
        update_ss
        exit $?
        ;;
    install)
        install_ss
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
