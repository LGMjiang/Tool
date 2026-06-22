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

    # 选择是否开启 udp
    local surge_udp_relay_param=", udp-relay=true"
    local mihomo_udp_param="true"

    read -r -p "是否开启 UDP? (Y/n): " udp_choice
    if [[ ${udp_choice,,} == "n" ]]; then
        surge_udp_relay_param=""
        mihomo_udp_param="false"
    elif [[ ! ${ss_mode} =~ udp ]]; then
        log_warn "当前配置未开启 UDP (mode: ${ss_mode})"
        log_warn "Surge udp-relay 和 Mihomo Party udp 参数将被禁用"
        surge_udp_relay_param=""
        mihomo_udp_param="false"
    fi

    # 选择客户端
    echo
    echo "选择要生成的客户端配置 (默认都生成): "
    echo "1. Surge"
    echo "2. Mihomo Party"
    read -r -p "请选择 [1-2]: " client_choice

    case $client_choice in
        1)
            echo
            log_info "Surge 客户端配置:"
            echo "name = ss, ${server_ip}, ${ss_port}, encrypt-method=${encryption_method}, password=${ss_password}${surge_udp_relay_param}"
            ;;
        2)
            echo
            log_info "Mihomo Party 客户端配置:"
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
            log_info "输出所有客户端配置"
            echo
            echo "=== Surge 配置 ==="
            echo "name = ss, ${server_ip}, ${ss_port}, encrypt-method=${encryption_method}, password=${ss_password}${surge_udp_relay_param}"
            echo
            echo "=== Mihomo Party 配置 ==="
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
}

# 更新 Shadowsocks-Rust
update_ss() {
    if [[ -z "$current_version" ]]; then
        log_error "未检测到 Shadowsocks-Rust，请先安装"
        return 1
    fi

    if [[ "$current_version" == "$latest_version" ]]; then
        log_info "当前已是最新版本 (${current_version})，无需更新"
        return 0
    fi

    log_info "开始更新 Shadowsocks-Rust: ${current_version} -> ${latest_version}"

    # 停止服务
    if systemctl is-active --quiet ss-rust.service; then
        systemctl stop ss-rust.service || {
            log_error "无法停止 Shadowsocks-Rust 服务"
            return 1
        }
    fi

    # 下载新版本
    local download_url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${latest_version}/shadowsocks-${latest_version}.${ss_type}.tar.xz"
    local temp_file="/tmp/shadowsocks-${latest_version}.${ss_type}.tar.xz"

    log_info "下载中: ${download_url}"
    if ! wget -O "$temp_file" "$download_url"; then
        log_error "下载失败"
        systemctl start ss-rust.service 2>/dev/null
        return 1
    fi

    # 解压
    if ! tar -xf "$temp_file" -C /tmp/; then
        log_error "解压失败"
        rm -f "$temp_file"
        systemctl start ss-rust.service 2>/dev/null
        return 1
    fi

    # 备份旧版本
    if [[ -f /usr/local/bin/ssserver ]]; then
        cp /usr/local/bin/ssserver /usr/local/bin/ssserver.backup
    fi

    # 安装新版本
    mv -f /tmp/ssserver /usr/local/bin/ || {
        log_error "移动文件失败"
        [[ -f /usr/local/bin/ssserver.backup ]] && mv /usr/local/bin/ssserver.backup /usr/local/bin/ssserver
        rm -f "$temp_file"
        systemctl start ss-rust.service 2>/dev/null
        return 1
    }

    chmod +x /usr/local/bin/ssserver

    # 清理
    rm -f /tmp/sslocal /tmp/ssmanager /tmp/ssservice /tmp/ssurl "$temp_file"
    rm -f /usr/local/bin/ssserver.backup

    # 重启服务
    if ! systemctl start ss-rust.service; then
        log_error "无法重启 Shadowsocks-Rust 服务"
        return 1
    fi

    log_info "Shadowsocks-Rust 已更新到版本 ${latest_version}"
}

# 安装 Shadowsocks-Rust
install_ss() {
    if [[ -f /usr/local/bin/ssserver ]]; then
        log_warn "检测到已安装 Shadowsocks-Rust"
        read -r -p "是否覆盖安装? (y/N): " overwrite
        if [[ ${overwrite,,} != "y" ]]; then
            log_info "已取消安装"
            return 0
        fi
    fi

    # 获取用户输入的配置信息
    read -r -p "请输入 Shadowsocks-Rust 监听端口 (默认随机): " ss_port
    ss_port=${ss_port:-$(shuf -i 10000-30000 -n 1)}

    # 选择加密方法
    echo "选择加密方法:"
    echo "1. 2022-blake3-aes-256-gcm (推荐)"
    echo "2. 2022-blake3-aes-128-gcm"
    echo "3. aes-256-gcm"
    echo "4. chacha20-ietf-poly1305"
    echo "5. aes-128-gcm"
    read -r -p "请选择 [1-5] (默认 1): " method_choice

    case ${method_choice:-1} in
        1) encryption_method="2022-blake3-aes-256-gcm" ;;
        2) encryption_method="2022-blake3-aes-128-gcm" ;;
        3) encryption_method="aes-256-gcm" ;;
        4) encryption_method="chacha20-ietf-poly1305" ;;
        5) encryption_method="aes-128-gcm" ;;
        *) encryption_method="2022-blake3-aes-256-gcm" ;;
    esac

    # 生成或输入密码
    read -r -p "请输入 Shadowsocks 密码 (留空自动生成): " ss_password
    if [[ -z "$ss_password" ]]; then
        if [[ "$encryption_method" == "2022-blake3-aes-256-gcm" ]]; then
            ss_password=$(openssl rand -base64 32)
        elif [[ "$encryption_method" == "2022-blake3-aes-128-gcm" ]]; then
            ss_password=$(openssl rand -base64 16)
        else
            ss_password=$(openssl rand -base64 24)
        fi
    fi

    # 选择传输模式
    echo "选择传输模式: "
    echo "1. tcp_and_udp (推荐)"
    echo "2. tcp_only"
    echo "3. udp_only"
    read -r -p "请选择 [1-3] (默认 1): " mode_choice

    case ${mode_choice:-1} in
        1) ss_mode="tcp_and_udp" ;;
        2) ss_mode="tcp_only" ;;
        3) ss_mode="udp_only" ;;
        *) ss_mode="tcp_and_udp" ;;
    esac

    # TCP Fast Open
    read -r -p "是否开启 TCP Fast Open? (y/N): " enable_tfo
    if [[ ${enable_tfo,,} == "y" ]]; then
        ss_tfo=true
    else
        ss_tfo=false
    fi

    # 确认配置
    cat << EOF

请确认以下配置信息：
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
端口:       ${ss_port}
密码:       ${ss_password}
加密方法:   ${encryption_method}
传输模式:   ${ss_mode}
TCP Fast Open: ${ss_tfo}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

    read -r -p "是否确认无误? (y/N): " confirm
    if [[ ${confirm,,} != "y" ]]; then
        log_info "已取消安装"
        return 0
    fi

    # 下载并安装
    local download_url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${latest_version}/shadowsocks-${latest_version}.${ss_type}.tar.xz"
    local temp_file="/tmp/shadowsocks-${latest_version}.${ss_type}.tar.xz"

    log_info "下载中: ${download_url}"
    if ! wget -O "$temp_file" "$download_url"; then
        log_error "下载失败"
        return 1
    fi

    if ! tar -xf "$temp_file" -C /tmp/; then
        log_error "解压失败"
        rm -f "$temp_file"
        return 1
    fi

    mv -f /tmp/ssserver /usr/local/bin/ || {
        log_error "移动文件失败"
        rm -f "$temp_file"
        return 1
    }

    chmod +x /usr/local/bin/ssserver
    rm -f /tmp/sslocal /tmp/ssmanager /tmp/ssservice /tmp/ssurl "$temp_file"

    # 创建配置目录
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

    # 创建 systemd 服务
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

    # 启动服务
    systemctl daemon-reload || {
        log_error "无法重载 systemd"
        return 1
    }

    if ! systemctl start ss-rust.service; then
        log_error "无法启动 Shadowsocks-Rust 服务"
        log_error "请检查日志: journalctl -u ss-rust -n 50"
        return 1
    fi

    if ! systemctl enable ss-rust.service; then
        log_warn "无法设置开机自启"
    fi

    # 配置防火墙
    ufw_allow_port "${ss_port}" "ss-rust"

    log_info "Shadowsocks-Rust 安装成功 (版本: ${latest_version})"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "客户端连接信息:"
    echo "端口:       ${ss_port}"
    echo "密码:       ${ss_password}"
    echo "加密方法:   ${encryption_method}"
    echo "传输模式:   ${ss_mode}"
    echo "TCP Fast Open: ${ss_tfo}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    generate_client_config
}

# 卸载 Shadowsocks-Rust
uninstall_ss() {
    log_warn "即将卸载 Shadowsocks-Rust，所有配置和数据将被删除"
    read -r -p "确认卸载? (y/N): " confirm
    if [[ ${confirm,,} != "y" ]]; then
        log_info "已取消卸载"
        return 0
    fi

    local uninstall_failed=false

    # 停止并禁用服务
    if systemctl is-active --quiet ss-rust.service; then
        systemctl stop ss-rust.service || {
            log_warn "停止服务失败"
            uninstall_failed=true
        }
    fi

    if systemctl is-enabled --quiet ss-rust.service 2>/dev/null; then
        systemctl disable ss-rust.service || log_warn "禁用服务失败"
    fi

    # 删除服务文件
    [[ -f /lib/systemd/system/ss-rust.service ]] && rm -f /lib/systemd/system/ss-rust.service
    [[ -f /etc/systemd/system/ss-rust.service ]] && rm -f /etc/systemd/system/ss-rust.service
    systemctl daemon-reload 2>/dev/null

    # 删除配置文件
    [[ -d /etc/ss-rust ]] && rm -rf /etc/ss-rust

    # 删除二进制文件
    [[ -f /usr/local/bin/ssserver ]] && rm -f /usr/local/bin/ssserver

    # 删除备份文件
    [[ -f /usr/local/bin/ssserver.backup ]] && rm -f /usr/local/bin/ssserver.backup

    # 删除防火墙规则
    ufw_delete_by_comment "ss-rust"

    # 清理临时文件
    rm -f /tmp/shadowsocks-*.tar.xz /tmp/ssserver /tmp/sslocal /tmp/ssmanager /tmp/ssservice /tmp/ssurl

    if [[ "$uninstall_failed" == "true" ]]; then
        log_warn "Shadowsocks-Rust 卸载完成，但部分操作失败"
        return 1
    else
        log_info "Shadowsocks-Rust 已完全卸载"
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
