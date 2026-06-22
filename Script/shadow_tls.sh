#!/bin/bash
# last updated:2026/06/22

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# 检查 root 用户
if [[ $EUID -ne 0 ]]; then
    log_error "请切换到 root 用户后再运行脚本"
    exit 1
fi

# 检查并安装依赖
check_and_install_deps() {
    local deps=("wget" "curl")
    local to_install=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log_warn "$dep 未安装，将进行安装..."
            to_install+=("$dep")
        fi
    done

    if [[ ${#to_install[@]} -gt 0 ]]; then
        log_info "更新包管理器..."
        apt update || { log_error "apt update 失败"; exit 1; }
        apt install -y "${to_install[@]}" || { log_error "依赖安装失败"; exit 1; }
    fi
}

check_and_install_deps

# 获取最新版本
get_latest_version() {
    local version
    version=$(curl -m 10 -sL "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" | grep -oP '"tag_name":\s*"\K[^"]+' || echo "")
    [[ -z "$version" ]] && { log_error "无法获取最新版本号"; return 1; }
    echo "$version"
}

latest_version=$(get_latest_version)
current_version=""

if command -v shadow-tls &> /dev/null; then
    current_version="v$(shadow-tls -V 2>&1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' || echo "")"
fi

# 检查系统架构
case "$(uname -m)" in
    x86_64) shadow_tls_type="x86_64-unknown-linux-musl" ;;
    aarch64) shadow_tls_type="aarch64-unknown-linux-musl" ;;
    *) log_error "不支持的架构: $(uname -m)"; exit 1 ;;
esac

# UFW 端口管理
ufw_allow_port() {
    local port=$1 comment=$2
    command -v ufw &> /dev/null || { log_warn "UFW 未安装"; return 0; }
    ufw status | grep -q "^Status: active" || { log_warn "UFW 未启用"; return 0; }
    ufw status | grep -Eq "^${port}(/tcp|/udp)?[[:space:]]" && { log_info "端口 ${port} 已存在"; return 0; }
    ufw allow "${port}" comment "${comment}" &> /dev/null && log_info "UFW 已放行端口: ${port} (${comment})" || log_warn "放行失败"
}

ufw_delete_by_comment() {
    local comment=$1
    command -v ufw &> /dev/null || return 0
    ufw status | grep -q "^Status: active" || { log_info "UFW 未启用"; return 0; }
    ufw status | grep -qw "${comment}" || { log_info "未找到备注 ${comment} 的规则"; return 0; }
    ufw status numbered | grep -w "${comment}" | tac | while IFS= read -r line; do
        local num=$(echo "$line" | grep -oP '^\[\K[0-9]+')
        [[ -n "$num" ]] && ufw --force delete "$num" &> /dev/null
    done
    log_info "已删除备注为 ${comment} 的 UFW 规则"
}

# 生成客户端配置
generate_client_config() {
    local server_ip=$(curl -m 5 -s https://api.ipify.org || echo "YOUR_SERVER_IP")
    [[ -z "$server_ip" ]] && server_ip="YOUR_SERVER_IP" && log_warn "无法获取公网 IP"

    local ss_mode ss_password encryption_method snell_psk snell_obfs

    # 检查 Shadowsocks-Rust
    if [[ "$protocol_type" == "ss-rust" ]]; then
        if ! ssserver -V &> /dev/null || [[ ! -e /etc/ss-rust/config.json ]]; then
            log_error "无法生成配置：未检测到 Shadowsocks-Rust 或配置文件"
            return 1
        fi
        ss_mode=$(grep '"mode"' /etc/ss-rust/config.json | sed 's/.*"mode": "\(.*\)",/\1/')
        ss_password=$(grep '"password"' /etc/ss-rust/config.json | sed 's/.*"password": "\(.*\)",/\1/')
        encryption_method=$(grep '"method"' /etc/ss-rust/config.json | sed 's/.*"method": "\(.*\)",/\1/')
    fi

    # 检查 Snell
    if [[ "$protocol_type" == "snell" ]]; then
        if ! snell-server -v &> /dev/null || [[ ! -e /etc/snell/snell-server.conf ]]; then
            log_error "无法生成配置：未检测到 Snell 或配置文件"
            return 1
        fi
        snell_psk=$(grep 'psk' /etc/snell/snell-server.conf | sed 's/psk = "\(.*\)"/\1/' || grep 'psk' /etc/snell/snell-server.conf | sed 's/psk = \(.*\)/\1/')
        snell_obfs=$(grep 'obfs' /etc/snell/snell-server.conf | sed 's/obfs = \(.*\)/\1/')
    fi

    # UDP 选项
    local surge_udp_relay=", udp-relay=true" mihomo_udp="true" surge_udp_port=", udp_port=${protocol_port}"
    read -r -p "是否开启 UDP? (Y/n): " udp_choice
    if [[ ${udp_choice,,} == "n" ]]; then
        surge_udp_relay="" mihomo_udp="false" surge_udp_port=""
    elif [[ "$protocol_type" == "ss-rust" && ! ${ss_mode} =~ udp ]]; then
        log_warn "Shadowsocks-Rust 未开启 UDP，参数将被禁用"
        surge_udp_relay="" mihomo_udp="false" surge_udp_port=""
    fi

    if [[ "$protocol_type" == "ss-rust" ]]; then
        echo
        echo "选择客户端: 1) Surge  2) Mihomo Party  (默认: 全部)"
        read -r -p "请选择 [1-2]: " client_choice
        case ${client_choice:-0} in
            1) echo; log_info "Surge 配置:"; echo "name = ss, ${server_ip}, ${shadow_tls_port}, encrypt-method=${encryption_method}, password=${ss_password}${surge_udp_relay}, shadow-tls-password=${shadow_tls_password}, shadow-tls-sni=gateway.icloud.com, shadow-tls-version=3${surge_udp_port}" ;;
            2) echo; log_info "Mihomo Party 配置:"; cat << EOF
- name: "shadowsocks-shadow-tls"
  type: ss
  server: ${server_ip}
  port: ${shadow_tls_port}
  cipher: ${encryption_method}
  password: "${ss_password}"
  udp: ${mihomo_udp}
  plugin: shadow-tls
  client-fingerprint: chrome
  plugin-opts:
    host: "gateway.icloud.com"
    password: "${shadow_tls_password}"
    version: 3
EOF
                ;;
            *) echo; log_info "Surge 配置:"; echo "name = ss, ${server_ip}, ${shadow_tls_port}, encrypt-method=${encryption_method}, password=${ss_password}${surge_udp_relay}, shadow-tls-password=${shadow_tls_password}, shadow-tls-sni=gateway.icloud.com, shadow-tls-version=3${surge_udp_port}"
               echo; log_info "Mihomo Party 配置:"; cat << EOF
- name: "shadowsocks-shadow-tls"
  type: ss
  server: ${server_ip}
  port: ${shadow_tls_port}
  cipher: ${encryption_method}
  password: "${ss_password}"
  udp: ${mihomo_udp}
  plugin: shadow-tls
  client-fingerprint: chrome
  plugin-opts:
    host: "gateway.icloud.com"
    password: "${shadow_tls_password}"
    version: 3
EOF
                ;;
        esac
    elif [[ "$protocol_type" == "snell" ]]; then
        local obfs_param="" reuse_param=""
        [[ "${snell_obfs}" == "http" ]] && obfs_param=", obfs=http"
        read -r -p "是否开启 reuse? (y/N): " reuse_choice
        [[ ${reuse_choice,,} == "y" ]] && reuse_param=", reuse=true"
        echo; log_info "Surge 配置:"; echo "name = snell, ${server_ip}, ${shadow_tls_port}, psk=${snell_psk}, version=4${obfs_param}${reuse_param}, shadow-tls-password=${shadow_tls_password}, shadow-tls-sni=gateway.icloud.com, shadow-tls-version=3"
    fi
}

# 卸载 Shadow-TLS
uninstall_shadow_tls() {
    log_warn "即将卸载 Shadow-TLS (${service_type})，所有配置将被删除"
    read -r -p "确认卸载? (y/N): " confirm
    [[ ${confirm,,} != "y" ]] && { log_info "已取消卸载"; return 0; }

    local uninstall_failed=false
    local services=()

    case "$service_type" in
        ss-rust) services=("shadow-tls-ss-rust.service") ;;
        snell) services=("shadow-tls-snell.service") ;;
        all) services=("shadow-tls-ss-rust.service" "shadow-tls-snell.service") ;;
    esac

    for svc in "${services[@]}"; do
        systemctl is-active --quiet "$svc" && { systemctl stop "$svc" || { log_warn "停止 $svc 失败"; uninstall_failed=true; }; }
        systemctl is-enabled --quiet "$svc" 2>/dev/null && { systemctl disable "$svc" || log_warn "禁用 $svc 失败"; }
        [[ -f /lib/systemd/system/$svc ]] && rm -f /lib/systemd/system/$svc
        [[ -f /etc/systemd/system/$svc ]] && rm -f /etc/systemd/system/$svc
        log_info "已卸载 $svc"
    done

    systemctl daemon-reload 2>/dev/null
    [[ -f /usr/local/bin/shadow-tls ]] && rm -f /usr/local/bin/shadow-tls
    rm -f /tmp/shadow-tls-*

    # 删除防火墙规则
    ufw_delete_by_comment "stls"

    [[ "$uninstall_failed" == "true" ]] && { log_warn "卸载完成，但部分操作失败"; return 1; }
    log_info "Shadow-TLS 已完全卸载"
}

# 更新 Shadow-TLS
update_shadow_tls() {
    [[ -z "$current_version" ]] && { log_error "未检测到 Shadow-TLS"; return 1; }
    [[ "$current_version" == "$latest_version" ]] && { log_info "当前已是最新版本 (${current_version})"; return 0; }

    log_info "开始更新: ${current_version} -> ${latest_version}"

    local services=()
    case "$service_type" in
        ss-rust) services=("shadow-tls-ss-rust.service") ;;
        snell) services=("shadow-tls-snell.service") ;;
        all) services=("shadow-tls-ss-rust.service" "shadow-tls-snell.service") ;;
    esac

    for svc in "${services[@]}"; do
        systemctl is-active --quiet "$svc" && systemctl stop "$svc"
    done

    local url="https://github.com/ihciah/shadow-tls/releases/download/${latest_version}/shadow-tls-${shadow_tls_type}"
    log_info "下载中: ${url}"
    wget -O /usr/local/bin/shadow-tls "$url" || { log_error "下载失败"; return 1; }
    chmod +x /usr/local/bin/shadow-tls

    for svc in "${services[@]}"; do
        systemctl start "$svc" || log_warn "启动 $svc 失败"
    done

    log_info "Shadow-TLS 已更新到 ${latest_version}"
}

# 安装 Shadow-TLS
install_shadow_tls() {
    # 选择协议类型
    while true; do
        read -r -p "请选择 Shadow-TLS 服务类型: [1] ss-rust [2] snell: " choice
        case "$choice" in
            1)
                if ! ssserver -V &> /dev/null; then
                    log_error "未检测到 Shadowsocks-Rust，请先安装"
                    return 1
                elif [[ ! -e /etc/ss-rust/config.json ]]; then
                    log_error "未检测到 Shadowsocks-Rust 配置文件"
                    return 1
                fi
                protocol_type="ss-rust"
                protocol_port=$(grep '"server_port"' /etc/ss-rust/config.json | sed 's/[^0-9]*\([0-9]*\).*/\1/')
                break
                ;;
            2)
                if ! snell-server -v &> /dev/null; then
                    log_error "未检测到 Snell，请先安装"
                    return 1
                elif [[ ! -e /etc/snell/snell-server.conf ]]; then
                    log_error "未检测到 Snell 配置文件"
                    return 1
                fi
                protocol_type="snell"
                protocol_port=$(grep 'listen' /etc/snell/snell-server.conf | sed 's/.*://')
                break
                ;;
            *)
                log_error "无效选择，请重新选择"
                ;;
        esac
    done

    # 检查是否已安装
    if [[ -f /lib/systemd/system/shadow-tls-${protocol_type}.service ]]; then
        log_warn "检测到已安装 Shadow-TLS (${protocol_type})"
        read -r -p "是否覆盖安装? (y/N): " overwrite
        [[ ${overwrite,,} != "y" ]] && { log_info "已取消安装"; return 0; }
    fi

    # 获取配置
    read -r -p "请输入 Shadow-TLS 监听端口 (留空随机): " shadow_tls_port
    shadow_tls_port=${shadow_tls_port:-$(shuf -i 10000-30000 -n 1)}

    read -r -p "请输入 Shadow-TLS 密码 (留空随机生成): " shadow_tls_password
    [[ -z "$shadow_tls_password" ]] && shadow_tls_password=$(openssl rand -base64 16)

    cat << EOF

请确认以下配置信息：
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
协议类型:   ${protocol_type}
端口:       ${shadow_tls_port}
密码:       ${shadow_tls_password}
后端端口:   ${protocol_port}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

    read -r -p "是否确认无误? (y/N): " confirm
    [[ ${confirm,,} != "y" ]] && { log_info "已取消安装"; return 0; }

    # 下载安装
    local url="https://github.com/ihciah/shadow-tls/releases/download/${latest_version}/shadow-tls-${shadow_tls_type}"
    log_info "下载中: ${url}"
    wget -O /usr/local/bin/shadow-tls "$url" || { log_error "下载失败"; return 1; }
    chmod +x /usr/local/bin/shadow-tls

    # 创建 systemd 服务
    cat > /lib/systemd/system/shadow-tls-${protocol_type}.service << EOF
[Unit]
Description=Shadow-TLS Server Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
LimitNOFILE=32767
Restart=on-failure
RestartSec=5s
Environment=MONOIO_FORCE_LEGACY_DRIVER=1
ExecStartPre=/bin/sh -c 'ulimit -n 51200'
ExecStart=/usr/local/bin/shadow-tls --v3 --strict server --listen 0.0.0.0:${shadow_tls_port} --server 127.0.0.1:${protocol_port} --tls gateway.icloud.com --password ${shadow_tls_password}
StandardOutput=journal
StandardError=journal
SyslogIdentifier=shadow-tls-${protocol_type}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload || { log_error "重载 systemd 失败"; return 1; }
    systemctl start shadow-tls-${protocol_type}.service || { log_error "启动失败，检查日志: journalctl -u shadow-tls-${protocol_type} -n 50"; return 1; }
    systemctl enable shadow-tls-${protocol_type}.service || log_warn "设置开机自启失败"

    ufw_allow_port "${shadow_tls_port}" "stls"

    log_info "Shadow-TLS 安装成功 (版本: ${latest_version})"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "端口: ${shadow_tls_port}"
    echo "密码: ${shadow_tls_password}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    generate_client_config
}

# 显示菜单
show_menu() {
    clear
    cat << EOF

    ╔═══════════════════════════════════════╗
    ║   Shadow-TLS 管理脚本                ║
    ╚═══════════════════════════════════════╝

EOF

    if [[ -n "$current_version" ]]; then
        echo "    当前版本: ${current_version}"
    else
        echo "    当前版本: 未安装"
    fi
    echo "    最新版本: ${latest_version}"
    echo
    echo "    1. 安装 Shadow-TLS"
    echo "    2. 更新 Shadow-TLS"
    echo "    3. 卸载 Shadow-TLS"
    echo "    0. 退出脚本"
    echo

    read -r -p "    请输入选择 [0-3]: " num

    case "${num}" in
        0) exit 0 ;;
        1)
            install_shadow_tls
            echo; read -r -p "按回车返回主菜单..."
            show_menu
            ;;
        2)
            read -r -p "请选择要更新的服务: [1] ss-rust (默认) [2] snell [3] all: " choice
            case ${choice:-1} in
                1) service_type=ss-rust ;;
                2) service_type=snell ;;
                3) service_type=all ;;
                *) service_type=ss-rust ;;
            esac
            update_shadow_tls
            echo; read -r -p "按回车返回主菜单..."
            show_menu
            ;;
        3)
            read -r -p "请选择要卸载的服务: [1] ss-rust (默认) [2] snell [3] all: " choice
            case ${choice:-1} in
                1) service_type=ss-rust ;;
                2) service_type=snell ;;
                3) service_type=all ;;
                *) service_type=ss-rust ;;
            esac
            uninstall_shadow_tls
            echo; read -r -p "按回车返回主菜单..."
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
        service_type="${2:-ss-rust}"
        [[ "$service_type" != "ss-rust" && "$service_type" != "snell" && "$service_type" != "all" ]] && service_type="ss-rust"
        uninstall_shadow_tls
        exit $?
        ;;
    update)
        service_type="${2:-ss-rust}"
        [[ "$service_type" != "ss-rust" && "$service_type" != "snell" && "$service_type" != "all" ]] && service_type="ss-rust"
        update_shadow_tls
        exit $?
        ;;
    install)
        install_shadow_tls
        exit $?
        ;;
    "")
        show_menu
        ;;
    *)
        echo "用法: $0 [install|update|uninstall] [ss-rust|snell|all]"
        exit 1
        ;;
esac

