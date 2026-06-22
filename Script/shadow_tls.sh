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
    ufw status | grep -q "^Status: active" || { log_info "✓ UFW 未启用，无需清理规则"; return 0; }
    ufw status | grep -qw "${comment}" || { log_info "✓ 未找到相关防火墙规则"; return 0; }

    local rules count=0
    rules=$(ufw status numbered | grep -w "${comment}" | tac)

    while IFS= read -r line; do
        local num=$(echo "$line" | grep -oP '^\[\K[0-9]+')
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
    local server_ip=$(curl -m 5 -s https://api.ipify.org || echo "YOUR_SERVER_IP")
    if [[ -z "$server_ip" || "$server_ip" == "YOUR_SERVER_IP" ]]; then
        log_warn "无法自动获取公网 IP 地址"
        echo "提示: 配置中将使用占位符，请手动替换为您的服务器 IP"
        server_ip="YOUR_SERVER_IP"
    else
        log_info "检测到公网 IP: ${server_ip}"
    fi

    local ss_mode ss_password encryption_method snell_psk snell_obfs

    # 检查 Shadowsocks-Rust
    if [[ "$protocol_type" == "ss-rust" ]]; then
        log_info "读取 Shadowsocks-Rust 配置..."
        if ! ssserver -V &> /dev/null || [[ ! -e /etc/ss-rust/config.json ]]; then
            log_error "无法生成配置：未检测到 Shadowsocks-Rust 或配置文件"
            return 1
        fi
        ss_mode=$(grep '"mode"' /etc/ss-rust/config.json | sed 's/.*"mode": "\(.*\)",/\1/')
        ss_password=$(grep '"password"' /etc/ss-rust/config.json | sed 's/.*"password": "\(.*\)",/\1/')
        encryption_method=$(grep '"method"' /etc/ss-rust/config.json | sed 's/.*"method": "\(.*\)",/\1/')
        log_info "✓ 已读取后端配置"
    fi

    # 检查 Snell
    if [[ "$protocol_type" == "snell" ]]; then
        log_info "读取 Snell 配置..."
        if ! snell-server -v &> /dev/null || [[ ! -e /etc/snell/snell-server.conf ]]; then
            log_error "无法生成配置：未检测到 Snell 或配置文件"
            return 1
        fi
        snell_psk=$(grep 'psk' /etc/snell/snell-server.conf | sed 's/psk = "\(.*\)"/\1/' || grep 'psk' /etc/snell/snell-server.conf | sed 's/psk = \(.*\)/\1/')
        snell_obfs=$(grep 'obfs' /etc/snell/snell-server.conf | sed 's/obfs = \(.*\)/\1/')
        log_info "✓ 已读取后端配置"
    fi

    # UDP 选项
    echo
    echo "【UDP 配置】"
    local surge_udp_relay=", udp-relay=true" mihomo_udp="true" surge_udp_port=", udp_port=${protocol_port}"
    read -r -p "是否在客户端配置中启用 UDP? (Y/n): " udp_choice
    if [[ ${udp_choice,,} == "n" ]]; then
        surge_udp_relay=""
        mihomo_udp="false"
        surge_udp_port=""
        log_info "客户端将不使用 UDP"
    elif [[ "$protocol_type" == "ss-rust" && ! ${ss_mode} =~ udp ]]; then
        log_warn "后端 Shadowsocks-Rust 未开启 UDP"
        log_warn "客户端 UDP 参数将被禁用"
        surge_udp_relay=""
        mihomo_udp="false"
        surge_udp_port=""
    else
        log_info "客户端将启用 UDP"
    fi

    if [[ "$protocol_type" == "ss-rust" ]]; then
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
                echo "name = ss, ${server_ip}, ${shadow_tls_port}, encrypt-method=${encryption_method}, password=${ss_password}${surge_udp_relay}, shadow-tls-password=${shadow_tls_password}, shadow-tls-sni=gateway.icloud.com, shadow-tls-version=3${surge_udp_port}"
                ;;
            2)
                echo
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                log_info "Mihomo Party 客户端配置"
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "复制以下配置到 Mihomo Party 的 proxies 区块:"
                echo
                cat << EOF
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
            *)
                echo
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                log_info "Surge 客户端配置"
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "复制以下配置到 Surge 的 [Proxy] 区块:"
                echo
                echo "name = ss, ${server_ip}, ${shadow_tls_port}, encrypt-method=${encryption_method}, password=${ss_password}${surge_udp_relay}, shadow-tls-password=${shadow_tls_password}, shadow-tls-sni=gateway.icloud.com, shadow-tls-version=3${surge_udp_port}"
                echo
                echo
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                log_info "Mihomo Party 客户端配置"
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "复制以下配置到 Mihomo Party 的 proxies 区块:"
                echo
                cat << EOF
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

        echo
        echo "【连接复用配置】"
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
        echo "name = snell, ${server_ip}, ${shadow_tls_port}, psk=${snell_psk}, version=4${obfs_param}${reuse_param}, shadow-tls-password=${shadow_tls_password}, shadow-tls-sni=gateway.icloud.com, shadow-tls-version=3"
    fi

    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "提示:"
    echo "  • 请将 'name' 替换为您想要的节点名称"
    echo "  • Shadow-TLS 使用 gateway.icloud.com 作为 SNI"
    if [[ "$server_ip" == "YOUR_SERVER_IP" ]]; then
        echo "  • 请将 YOUR_SERVER_IP 替换为您的服务器实际 IP"
    fi
}

# 卸载 Shadow-TLS
uninstall_shadow_tls() {
    echo
    log_warn "═══════════════════════════════════════"
    log_warn "  即将卸载 Shadow-TLS 服务"
    log_warn "═══════════════════════════════════════"

    local services=()
    case "$service_type" in
        ss-rust)
            services=("shadow-tls-ss-rust.service")
            echo "  卸载类型: Shadowsocks-Rust 包装"
            ;;
        snell)
            services=("shadow-tls-snell.service")
            echo "  卸载类型: Snell 包装"
            ;;
        all)
            services=("shadow-tls-ss-rust.service" "shadow-tls-snell.service")
            echo "  卸载类型: 全部 Shadow-TLS 服务"
            ;;
    esac

    echo
    echo "以下内容将被删除:"
    for svc in "${services[@]}"; do
        echo "  • Shadow-TLS 服务 (${svc})"
    done
    echo "  • 程序文件 (/usr/local/bin/shadow-tls)"
    echo "  • 防火墙规则 (UFW)"
    echo
    log_warn "注意: 底层的 Shadowsocks-Rust 或 Snell 服务不会被删除"
    echo
    read -r -p "确认卸载? (y/N): " confirm
    [[ ${confirm,,} != "y" ]] && { log_info "已取消卸载操作"; return 0; }

    echo
    log_info "开始卸载 Shadow-TLS..."
    local uninstall_failed=false
    local step=1
    local total_steps=4

    for svc in "${services[@]}"; do
        log_info "[${step}/${total_steps}] 处理服务: ${svc}..."

        if systemctl list-unit-files | grep -q "^${svc}"; then
            if systemctl is-active --quiet "$svc"; then
                if systemctl stop "$svc"; then
                    log_info "  ✓ 服务已停止"
                else
                    log_warn "  ✗ 停止服务失败"
                    uninstall_failed=true
                fi
            else
                log_info "  ✓ 服务未运行"
            fi

            if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
                systemctl disable "$svc" 2>/dev/null && log_info "  ✓ 已禁用开机自启" || log_warn "  ✗ 禁用失败"
            fi

            [[ -f /lib/systemd/system/$svc ]] && rm -f /lib/systemd/system/$svc
            [[ -f /etc/systemd/system/$svc ]] && rm -f /etc/systemd/system/$svc
            log_info "  ✓ 服务文件已删除"
        else
            log_info "  ✓ 服务不存在，跳过"
        fi

        ((step++))
    done

    log_info "[${step}/${total_steps}] 重载 systemd..."
    systemctl daemon-reload 2>/dev/null
    log_info "✓ 系统服务已重载"
    ((step++))

    log_info "[${step}/${total_steps}] 删除程序文件..."
    if [[ -f /usr/local/bin/shadow-tls ]]; then
        rm -f /usr/local/bin/shadow-tls
        log_info "✓ 程序文件已删除 (/usr/local/bin/shadow-tls)"
    else
        log_info "✓ 程序文件不存在，跳过"
    fi
    ((step++))

    # 删除防火墙规则
    log_info "[${step}/${total_steps}] 清理防火墙规则..."
    ufw_delete_by_comment "stls"

    # 清理临时文件
    rm -f /tmp/shadow-tls-* 2>/dev/null

    echo
    if [[ "$uninstall_failed" == "true" ]]; then
        log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_warn "卸载完成，但部分操作失败"
        log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "建议手动检查以下内容:"
        echo "  • 服务状态: systemctl status shadow-tls-*"
        echo "  • 残留文件: ls -la /usr/local/bin/shadow-tls"
        return 1
    else
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "Shadow-TLS 已完全卸载"
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "底层服务 (Shadowsocks-Rust/Snell) 仍在运行"
    fi
}

# 更新 Shadow-TLS
update_shadow_tls() {
    if [[ -z "$current_version" ]]; then
        log_error "未检测到 Shadow-TLS 服务"
        echo "请先运行安装功能，或使用以下命令检查:"
        echo "  shadow-tls -V"
        return 1
    fi

    if [[ "$current_version" == "$latest_version" ]]; then
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "当前已是最新版本 (${current_version})"
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "无需更新，当前服务:"
        case "$service_type" in
            ss-rust) echo "  • shadow-tls-ss-rust.service: $(systemctl is-active shadow-tls-ss-rust.service 2>/dev/null || echo '未安装')" ;;
            snell) echo "  • shadow-tls-snell.service: $(systemctl is-active shadow-tls-snell.service 2>/dev/null || echo '未安装')" ;;
            all)
                echo "  • shadow-tls-ss-rust.service: $(systemctl is-active shadow-tls-ss-rust.service 2>/dev/null || echo '未安装')"
                echo "  • shadow-tls-snell.service: $(systemctl is-active shadow-tls-snell.service 2>/dev/null || echo '未安装')"
                ;;
        esac
        return 0
    fi

    echo
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "发现新版本可用"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  当前版本: ${current_version}"
    echo "  最新版本: ${latest_version}"
    echo "  更新范围: ${service_type}"
    echo
    read -r -p "是否立即更新? (Y/n): " update_confirm
    if [[ ${update_confirm,,} == "n" ]]; then
        log_info "已取消更新操作"
        return 0
    fi

    echo
    log_info "开始更新 Shadow-TLS: ${current_version} -> ${latest_version}"

    local services=()
    case "$service_type" in
        ss-rust) services=("shadow-tls-ss-rust.service") ;;
        snell) services=("shadow-tls-snell.service") ;;
        all) services=("shadow-tls-ss-rust.service" "shadow-tls-snell.service") ;;
    esac

    log_info "[1/4] 停止 Shadow-TLS 服务..."
    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc"; then
            if systemctl stop "$svc"; then
                log_info "  ✓ ${svc} 已停止"
            else
                log_warn "  ✗ ${svc} 停止失败"
            fi
        else
            log_info "  ✓ ${svc} 未运行"
        fi
    done

    local url="https://github.com/ihciah/shadow-tls/releases/download/${latest_version}/shadow-tls-${shadow_tls_type}"

    log_info "[2/4] 下载新版本..."
    echo "  下载地址: ${url}"
    if wget -q --show-progress -O /usr/local/bin/shadow-tls "$url" 2>&1; then
        chmod +x /usr/local/bin/shadow-tls
        log_info "✓ 下载并安装完成"
    else
        log_error "✗ 下载失败"
        echo "可能原因:"
        echo "  • 网络连接问题"
        echo "  • GitHub 访问受限"
        echo "  • 下载地址失效"
        log_info "尝试重启服务..."
        for svc in "${services[@]}"; do
            systemctl start "$svc" 2>/dev/null
        done
        return 1
    fi

    log_info "[3/4] 重启 Shadow-TLS 服务..."
    local restart_failed=false
    for svc in "${services[@]}"; do
        if systemctl list-unit-files | grep -q "^${svc}"; then
            if systemctl start "$svc"; then
                log_info "  ✓ ${svc} 已启动"
            else
                log_warn "  ✗ ${svc} 启动失败"
                restart_failed=true
            fi
        else
            log_info "  ✓ ${svc} 未安装，跳过"
        fi
    done

    log_info "[4/4] 验证服务状态..."
    sleep 2
    for svc in "${services[@]}"; do
        if systemctl list-unit-files | grep -q "^${svc}"; then
            local status=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
            if [[ "$status" == "active" ]]; then
                log_info "  ✓ ${svc}: 运行中"
            else
                log_warn "  ✗ ${svc}: ${status}"
                restart_failed=true
            fi
        fi
    done

    echo
    if [[ "$restart_failed" == "true" ]]; then
        log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_warn "Shadow-TLS 更新完成，但部分服务异常"
        log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "请检查以下日志排查问题:"
        for svc in "${services[@]}"; do
            echo "  journalctl -u ${svc} -n 30"
        done
        return 1
    else
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "Shadow-TLS 更新完成"
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  新版本: ${latest_version}"
        echo "  所有服务: 运行正常"
        echo
        echo "提示: 原有配置已保留，无需重新配置客户端"
    fi
}

# 安装 Shadow-TLS
install_shadow_tls() {
    echo
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "开始安装 Shadow-TLS ${latest_version}"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # 选择协议类型
    echo
    echo "【选择后端协议】"
    echo "Shadow-TLS 是一个 TLS 混淆工具，需要基于现有的代理协议运行"
    echo
    echo "1. Shadowsocks-Rust (推荐)"
    echo "2. Snell"
    echo

    while true; do
        read -r -p "请选择后端协议 [1-2]: " choice
        case "$choice" in
            1)
                log_info "检查 Shadowsocks-Rust 服务..."
                if ! ssserver -V &> /dev/null; then
                    log_error "✗ 未检测到 Shadowsocks-Rust"
                    echo "请先安装 Shadowsocks-Rust:"
                    echo "  bash shadowsocks_rust.sh"
                    return 1
                elif [[ ! -e /etc/ss-rust/config.json ]]; then
                    log_error "✗ 未找到配置文件 /etc/ss-rust/config.json"
                    echo "请确保 Shadowsocks-Rust 已正确配置"
                    return 1
                fi
                protocol_type="ss-rust"
                protocol_port=$(grep '"server_port"' /etc/ss-rust/config.json | sed 's/[^0-9]*\([0-9]*\).*/\1/')
                log_info "✓ 检测到 Shadowsocks-Rust (端口: ${protocol_port})"
                break
                ;;
            2)
                log_info "检查 Snell 服务..."
                if ! snell-server -v &> /dev/null; then
                    log_error "✗ 未检测到 Snell"
                    echo "请先安装 Snell:"
                    echo "  bash snell.sh"
                    return 1
                elif [[ ! -e /etc/snell/snell-server.conf ]]; then
                    log_error "✗ 未找到配置文件 /etc/snell/snell-server.conf"
                    echo "请确保 Snell 已正确配置"
                    return 1
                fi
                protocol_type="snell"
                protocol_port=$(grep 'listen' /etc/snell/snell-server.conf | sed 's/.*://')
                log_info "✓ 检测到 Snell (端口: ${protocol_port})"
                break
                ;;
            *)
                log_error "无效选择，请重新选择"
                ;;
        esac
    done

    # 检查是否已安装
    if [[ -f /lib/systemd/system/shadow-tls-${protocol_type}.service ]]; then
        echo
        log_warn "检测到已安装 Shadow-TLS (${protocol_type})"
        echo "  服务文件: /lib/systemd/system/shadow-tls-${protocol_type}.service"
        echo
        log_warn "覆盖安装将重新配置服务"
        read -r -p "是否继续覆盖安装? (y/N): " overwrite
        [[ ${overwrite,,} != "y" ]] && { log_info "已取消安装操作"; return 0; }
    fi

    echo
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "配置向导"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # 获取配置
    echo
    echo "【端口配置】"
    echo "Shadow-TLS 将监听此端口，客户端连接到此端口"
    read -r -p "请输入 Shadow-TLS 监听端口 (留空随机生成 10000-30000): " shadow_tls_port
    shadow_tls_port=${shadow_tls_port:-$(shuf -i 10000-30000 -n 1)}
    log_info "使用端口: ${shadow_tls_port}"

    echo
    echo "【密码配置】"
    read -r -p "请输入 Shadow-TLS 密码 (留空随机生成): " shadow_tls_password
    if [[ -z "$shadow_tls_password" ]]; then
        shadow_tls_password=$(openssl rand -base64 16)
        log_info "已生成随机密码"
    else
        log_info "使用自定义密码"
    fi

    # 确认配置
    echo
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "配置信息确认"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cat << EOF
  后端协议:   ${protocol_type}
  后端端口:   ${protocol_port} (本地)
  监听端口:   ${shadow_tls_port} (对外)
  TLS 密码:   ${shadow_tls_password}
  SNI 域名:   gateway.icloud.com
  版本:       ${latest_version}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

    echo
    echo "提示: Shadow-TLS 将转发流量到本地 ${protocol_type} 服务 (127.0.0.1:${protocol_port})"
    echo
    read -r -p "确认配置无误，开始安装? (Y/n): " confirm
    [[ ${confirm,,} == "n" ]] && { log_info "已取消安装操作"; return 0; }

    # 下载安装
    echo
    log_info "开始安装..."
    local url="https://github.com/ihciah/shadow-tls/releases/download/${latest_version}/shadow-tls-${shadow_tls_type}"

    log_info "[1/4] 下载 Shadow-TLS 安装包..."
    echo "  下载地址: ${url}"
    if wget -q --show-progress -O /usr/local/bin/shadow-tls "$url" 2>&1; then
        chmod +x /usr/local/bin/shadow-tls
        log_info "✓ 下载并安装完成"
    else
        log_error "✗ 下载失败"
        echo "可能原因:"
        echo "  • 网络连接问题"
        echo "  • GitHub 访问受限"
        echo "  • 下载地址失效"
        return 1
    fi

    # 创建 systemd 服务
    log_info "[2/4] 配置系统服务..."
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
    log_info "✓ 服务文件已创建"

    if systemctl daemon-reload; then
        log_info "✓ 服务配置已加载"
    else
        log_error "✗ 重载 systemd 失败"
        return 1
    fi

    log_info "[3/4] 启动 Shadow-TLS 服务..."
    if systemctl start shadow-tls-${protocol_type}.service; then
        log_info "✓ Shadow-TLS 服务已启动"
    else
        log_error "✗ 服务启动失败"
        echo "请检查日志排查问题: journalctl -u shadow-tls-${protocol_type} -n 50"
        return 1
    fi

    if systemctl enable shadow-tls-${protocol_type}.service >/dev/null 2>&1; then
        log_info "✓ 已设置开机自启"
    else
        log_warn "✗ 设置开机自启失败 (不影响当前使用)"
    fi

    log_info "[4/4] 配置防火墙..."
    ufw_allow_port "${shadow_tls_port}" "stls"

    sleep 1
    echo
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Shadow-TLS 安装完成！"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "安装信息:"
    echo "  版本:       ${latest_version}"
    echo "  后端协议:   ${protocol_type}"
    echo "  服务状态:   $(systemctl is-active shadow-tls-${protocol_type}.service)"
    echo
    echo "连接信息:"
    echo "  监听端口:   ${shadow_tls_port}"
    echo "  TLS 密码:   ${shadow_tls_password}"
    echo "  后端端口:   ${protocol_port}"
    echo "  SNI 域名:   gateway.icloud.com"
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

