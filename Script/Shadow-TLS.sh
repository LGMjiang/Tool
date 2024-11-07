#!/bin/bash
# last updated:2024/11/7

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
  echo "请切换到 root 用户后再运行脚本"
  exit 1
fi

# 检查并自动安装必要工具
for cmd in wget curl; do
  if ! command -v $cmd &> /dev/null; then
    echo "$cmd 未安装，正在安装..."
    
    # 使用 apt 安装缺少的工具
    apt update
    if ! apt install -y $cmd; then
      echo "$cmd 安装失败，请检查系统或网络连接。"
      exit 1
    fi
  fi
done

# 获取最新版本号
latest_version=$(curl -m 10 -sL "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" | awk -F'"' '/tag_name/{print $4}')

# 获取当前版本号
current_version="v$(shadow-tls -V 2>&1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+')"


# 检查系统架构
case "$(uname -m)" in
  x86_64)
    shadow_tls_type="x86_64-unknown-linux-musl"
    ;;
  aarch64)
    shadow_tls_type="aarch64-unknown-linux-musl"
    ;;
  *)
    echo "$(uname -m) 架构不支持"
    exit 1
    ;;
esac

# 生成客户端配置 (目前只支持生成 ss-rust + stls)
generate_client_config() {
  local server_ip=$(hostname -I | awk '{print $1}')  # 获取私有 IP 地址
  local ss_port=""
  local ss_transmission_mode=""
  local ss_password=""
  local encryption_method=""


  # 检查 Shadowsocks-Rust 的服务和配置文件
  if ! ssserver -V > /dev/null 2>&1; then
    echo "无法生成 ss-rust + stls 的配置文件！"
    echo "未检测到 Shadowsocks-Rust 服务！"
    return
  elif [[ ! -e /etc/ss-rust/config.json ]]; then
    echo "无法生成 ss-rust + stls 的配置文件！"
    echo "未检测到 Shadowsocks-Rust 的配置文件！请检查其配置文件是否在/etc/ss-rust/目录下！"
    return
  else
    ss_port=$(grep '"server_port"' /etc/ss-rust/config.json | sed 's/[^0-9]*\([0-9]*\).*/\1/') # 获取 ss-rust 服务的端口号
    ss_transmission_mode=$(grep '"mode"' /etc/ss-rust/config.json | sed 's/.*"mode": "\(.*\)",/\1/') # 获取 ss-rust 的传输模式
    ss_password=$(grep '"password"' /etc/ss-rust/config.json | sed 's/.*"password": "\(.*\)",/\1/')
    encryption_method=$(grep '"method"' /etc/ss-rust/config.json | sed 's/.*"method": "\(.*\)",/\1/')
  fi

  # 选择是否开启 udp
  local surge_udp_relay_param=", udp-relay=true"
  local mihomo_udp_param="true"
  local surge_udp_port_param=", udp_port=${ss_port}"
  read -r -p "是否开启 udp (Y/N 默认开启): " udp_choice
  if [[ ${udp_choice} == "n" ]]; then
    surge_udp_relay_param=""
    mihomo_udp_param="false"
    surge_udp_port_param=""
  elif [[ ! ${ss_transmission_mode} =~ .*udp.* ]]; then
    echo "开启 udp 失败！"
    echo "Surge udp-relay、udp-port 参数和 Mihomo Party udp 参数添加失败！"
    echo "其 ss-rust 服务未开启 udp，请更改 mode 为 tcp_and_udp 或 udp_only！"
    surge_udp_relay_param=""
    mihomo_udp_param="false"
    surge_udp_port_param=""
  fi

  # 选择客户端
  echo
  echo "选择要生成的客户端配置 (默认都生成): "
  echo "1. Surge"
  echo "2. Mihomo Party"
  read -r -p "请选择要生成的客户端配置 [1-2]: " client_choice

  case $client_choice in
    1)
      # 输出 Surge 配置
      echo
      echo "Surge 客户端配置如下: "
      echo "name = ss, ${server_ip}, ${shadow_tls_port}, encrypt-method=${encryption_method}, password=${ss_password}${surge_udp_relay_param}, shadow-tls-password=${shadow_tls_password}, shadow-tls-sni=gateway.icloud.com, shadow-tls-version=3${surge_udp_port_param}"
    ;;
    2)
      # 输出 Mihomo Party 配置
      echo
      cat << EOF
Mihomo Party 客户端配置如下: 
- name: "name"
  type: ss
  server: ${server_ip}
  port: ${shadow_tls_port}
  cipher: ${encryption_method}
  password: "${ss_password}"
  udp: ${mihomo_udp_param}
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
      echo "无效选择，默认自动输出所有客户端配置！"
      echo "Surge 客户端配置如下: "
      echo "name = ss, ${server_ip}, ${shadow_tls_port}, encrypt-method=${encryption_method}, password=${ss_password}${surge_udp_relay_param}, shadow-tls-password=${shadow_tls_password}, shadow-tls-sni=gateway.icloud.com, shadow-tls-version=3${surge_udp_port_param}"
      echo
      cat << EOF
Mihomo Party 客户端配置如下: 
- name: "name"
  type: ss
  server: ${server_ip}
  port: ${shadow_tls_port}
  cipher: ${encryption_method}
  password: "${ss_password}"
  udp: ${mihomo_udp_param}
  plugin: shadow-tls
  client-fingerprint: chrome
  plugin-opts:
    host: "gateway.icloud.com"
    password: "${shadow_tls_password}"
    version: 3
EOF
    ;;
  esac
}

# 卸载 Shadow-TLS 函数
uninstall_shadow_tls() {
  systemctl stop shadow-tls.service || { echo "无法停止 Shadow-TLS 服务"; exit 1; }
  systemctl disable shadow-tls.service || { echo "无法取消开机自启"; exit 1; }
  rm -f /lib/systemd/system/shadow-tls.service
  rm -f /usr/local/bin/shadow-tls
  echo "Shadow-TLS 已卸载"
}

# 更新 Shadow-TLS 函数
update_shadow_tls() {
  if [[ "$current_version" == "$latest_version" ]]; then
    echo "当前已是最新版本 (${current_version})，无需更新"
    return
  fi
  
  systemctl stop shadow-tls.service || { echo "无法停止 Shadow-TLS 服务"; exit 1; }
  wget -N --no-check-certificate "https://github.com/ihciah/shadow-tls/releases/download/${latest_version}/shadow-tls-${shadow_tls_type}" -O /usr/local/bin/shadow-tls
  chmod +x /usr/local/bin/shadow-tls
  systemctl restart shadow-tls.service || { echo "无法重启 Shadow-TLS 服务"; exit 1; }
  echo "Shadow-TLS 已更新到版本 ${latest_version}"
}

# 安装 Shadow-TLS 函数
install_shadow_tls() {
  # 获取用户输入的配置信息
  read -r -p "请输入 Shadow-TLS 监听端口 (留空默认随机端口号): " shadow_tls_port
  shadow_tls_port=${shadow_tls_port:-$(shuf -i 10000-30000 -n 1)}

  read -r -p "请输入 Shadow-TLS 密码 (留空随机生成): " shadow_tls_password
  if [[ -z "$shadow_tls_password" ]]; then
    shadow_tls_password=$(openssl rand -base64 16)
  fi

  # 显示配置信息
  cat <<EOF
请确认以下配置信息：
端口：${shadow_tls_port}
密码：${shadow_tls_password}
EOF

  read -r -p "确认无误？(Y/N) " confirm
  case "$confirm" in
    [yY]) ;;
    *)
      echo "已取消安装"
      return
      ;;
  esac

  # 下载并安装 Shadow-TLS
  wget -N --no-check-certificate "https://github.com/ihciah/shadow-tls/releases/download/${latest_version}/shadow-tls-${shadow_tls_type}" -O /usr/local/bin/shadow-tls
  chmod +x /usr/local/bin/shadow-tls

  # 创建 Systemd 服务文件
  cat > /lib/systemd/system/shadow-tls.service <<EOF
[Unit]
Description=Shadow-TLS Server Service
After=network-online.target
Wants=network-online.target

[Service]
LimitNOFILE=32767
Type=simple
User=root
Restart=on-failure
RestartSec=5s
Environment=MONOIO_FORCE_LEGACY_DRIVER=1
ExecStartPre=/bin/sh -c ulimit -n 51200
ExecStart=/usr/local/bin/shadow-tls --v3 --strict server --listen 0.0.0.0:${shadow_tls_port} --password ${shadow_tls_password}
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=shadow-tls

[Install]
WantedBy=multi-user.target
EOF

  # 启动并启用 Shadow-TLS 服务
  systemctl daemon-reload || { echo "无法重载 daemon"; exit 1; }
  systemctl start shadow-tls.service || { echo "无法启动 Shadow-TLS 服务"; exit 1; }
  systemctl enable shadow-tls.service || { echo "无法设置开机自启"; exit 1; }

  echo "Shadow-TLS 安装成功，版本: ${latest_version}"
  echo "客户端连接信息: "
  echo "端口: ${shadow_tls_port}"
  echo "密码: ${shadow_tls_password}"

  generate_client_config
}

# 显示菜单前的等待函数
# before_show_menu() {
#     echo && printf "* 按回车返回主菜单 *" && read temp
#     show_menu
# }

# 显示菜单
show_menu() {
    clear
    printf "
    Shadow-TLS 管理脚本
    --------------------------
    1. 安装 Shadow-TLS
    2. 更新 Shadow-TLS
    3. 卸载 Shadow-TLS
    0. 退出脚本
    "
    echo && printf "请输入选择 [0-3]: " && read -r num
    case "${num}" in
        0)
            exit 0
            ;;
        1)
            install_shadow_tls
            echo && printf "* 按回车返回主菜单 *" && read temp
            show_menu
            ;;
        2)
            update_shadow_tls
            echo && printf "* 按回车返回主菜单 *" && read temp
            show_menu
            ;;
        3)
            uninstall_shadow_tls
            echo && printf "* 按回车返回主菜单 *" && read temp
            show_menu
            ;;
        *)
            echo "请输入正确的数字 [0-3]"
            show_menu
            ;;
    esac
}

# 处理传入参数
if [[ $1 == "uninstall" ]]; then
  uninstall_shadow_tls
  exit 0
fi
if [[ $1 == "update" ]]; then
  update_shadow_tls
  exit 0
fi

# 启动菜单
show_menu
