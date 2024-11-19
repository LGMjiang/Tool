#!/bin/bash
# last updated:2024/11/19

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

# 生成客户端配置
generate_client_config() {
  local server_ip
  # server_ip=$(hostname -I | awk '{print $1}')  # 获取私有 IP 地址
  server_ip=$(curl -s https://api.ipify.org)
  # local ss_port=""
  local ss_transmission_mode=""
  local ss_password=""
  local encryption_method=""
  # local snell_port=""
  local snell_psk=""
  local snell_obfs=""

  # 检查 Shadowsocks-Rust 的服务和配置文件
  if ! ssserver -V > /dev/null 2>&1; then
    echo "无法生成 ss-rust + shadow-tls 的配置文件！"
    echo "未检测到 Shadowsocks-Rust 服务！"
    return
  elif [[ ! -e /etc/ss-rust/config.json ]]; then
    echo "无法生成 ss-rust + shadow-tls 的配置文件！"
    echo "未检测到 Shadowsocks-Rust 的配置文件！请检查其配置文件是否在/etc/ss-rust/目录下！"
    return
  else
    # ss_port=$(grep '"server_port"' /etc/ss-rust/config.json | sed 's/[^0-9]*\([0-9]*\).*/\1/') # 获取 ss-rust 服务的端口号
    ss_transmission_mode=$(grep '"mode"' /etc/ss-rust/config.json | sed 's/.*"mode": "\(.*\)",/\1/') # 获取 ss-rust 服务的传输模式
    ss_password=$(grep '"password"' /etc/ss-rust/config.json | sed 's/.*"password": "\(.*\)",/\1/') # 获取 ss-rust 服务的密码
    encryption_method=$(grep '"method"' /etc/ss-rust/config.json | sed 's/.*"method": "\(.*\)",/\1/') # 获取 ss-rust 服务的加密方式
  fi

  # 检查 Snell 的配置
  if ! snell-server -v > /dev/null 2>&1; then
    echo "无法生成 snell + shadow-tls 的配置文件！"
    echo "未检测到 Snell 服务！"
    return
  elif [[ ! -e /etc/snell/snell-server.conf ]]; then
    echo "无法生成 snell + shadow-tls 的配置文件！"
    echo "未检测到 Snell 的配置文件！请检查其配置文件是否在 /etc/snell/ 目录下！"
    return
  else
    # snell_port=$(grep 'listen' /etc/snell/snell-server.conf | sed 's/.*://')  # 获取 Snell 服务的端口号
    snell_psk=$(grep 'psk' /etc/snell/snell-server.conf | sed 's/psk = "\(.*\)"/\1/')  # 获取 Snell 的 PSK
    snell_obfs=$(grep 'obfs' /etc/snell/snell-server.conf | sed 's/obfs = \(.*\)/\1/') # 获取 Snell 的 OBFS
  fi

  # 选择是否开启 udp
  local surge_udp_relay_param=", udp-relay=true"
  local mihomo_udp_param="true"
  local surge_udp_port_param=", udp_port=${protocol_port}"
  read -r -p "是否开启 udp? (Y/n)" udp_choice
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

  if [[ $protocol_type == "ss-rust" ]]; then
    # 根据协议选择客户端
    echo
    echo "选择要生成的客户端配置 (默认都生成): "
    echo "1. Surge"
    echo "2. Mihomo Party"
    read -r -p "请选择要生成的客户端配置 [1-2]: " client_choice

    # ss-rust + shadow-tls 配置
    case $client_choice in
      1)
        echo
        echo "Surge 客户端配置如下 (ss-rust + shadow-tls): "
        echo "name = ss, ${server_ip}, ${shadow_tls_port}, encrypt-method=${encryption_method}, password=${ss_password}${surge_udp_relay_param}, shadow-tls-password=${shadow_tls_password}, shadow-tls-sni=gateway.icloud.com, shadow-tls-version=3${surge_udp_port_param}"
      ;;
      2)
        echo
        cat << EOF
Mihomo Party 客户端配置如下 (ss-rust + shadow-tls): 
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
        echo "无效选择，默认自动输出所有客户端配置 (ss-rust + shadow-tls)！"
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
  elif [[ $protocol_type == "snell" ]]; then
      # snell + shadow-tls 配置

      # 根据 snell_obfs 的值设置 obfs_param
      if [[ "${snell_obfs}" == "http" ]]; then
        obfs_param=", obfs=http"
      fi

      # 选择是否开启 reuse
      local reuse_param=""
      read -r -p "是否开启 reuse? (y/N)" reuse_choice
      if [[ ${reuse_choice} == "y" ]]; then
        reuse_param=", reuse=true"
      fi

      echo
      echo "Surge 客户端配置如下 (snell + shadow-tls): "
      echo "name = snell, ${server_ip}, ${shadow_tls_port}, psk=${snell_psk}, version=4${obfs_param}${reuse_param}, shadow-tls-password=${shadow_tls_password}, shadow-tls-sni=gateway.icloud.com, shadow-tls-version=3"
  fi
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

  while true; do
    read -r -p "请选择 Shadow-TLS 服务类型: [1] ss-rust [2] snell: " protocol_type

    case "$protocol_type" in
    1)
      # 检查 Shadowsocks-Rust 的服务和配置文件
      if ! ssserver -V > /dev/null 2>&1; then
        echo "无法继续安装 Shadow-TLS 服务！"
        echo "未检测到 Shadowsocks-Rust 服务！"
        exit 1
      elif [[ ! -e /etc/ss-rust/config.json ]]; then
        echo "无法继续安装 Shadow-TLS 服务！"
        echo "未检测到 Shadowsocks-Rust 的配置文件！请检查其配置文件是否在/etc/ss-rust/目录下！"
        exit 1
      else
        protocol_type="ss-rust"
        protocol_port=$(grep '"server_port"' /etc/ss-rust/config.json | sed 's/[^0-9]*\([0-9]*\).*/\1/') # 获取 ss-rust 服务的端口号
      fi
      break
      ;;
    2)
      # 检查 Snell 的配置
      if ! snell-server -v > /dev/null 2>&1; then
        echo "无法生成 snell + shadow-tls 的配置文件！"
        echo "未检测到 Snell 服务！"
        return
      elif [[ ! -e /etc/snell/snell-server.conf ]]; then
        echo "无法生成 snell + shadow-tls 的配置文件！"
        echo "未检测到 Snell 的配置文件！请检查其配置文件是否在 /etc/snell/ 目录下！"
        return
      else
        protocol_type="snell"
        protocol_port=$(grep 'listen' /etc/snell/snell-server.conf | sed 's/.*://')  # 获取 Snell 服务的端口号
      fi
      break
      ;;
    *)
      echo "无效选择，请重新选择！"
      ;;
    esac
  done

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

  read -r -p "是否确认无误? (y/n)" confirm
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
  cat > /lib/systemd/system/shadow-tls-${protocol_type}.service <<EOF
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
ExecStart=/usr/local/bin/shadow-tls --v3 --strict server --listen 0.0.0.0:${shadow_tls_port} --server 127.0.0.1:${protocol_port} --tls gateway.icloud.com --password ${shadow_tls_password}
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=shadow-tls-${protocol_type}

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
            echo && printf "* 按回车返回主菜单 *" && read
            show_menu
            ;;
        2)
            update_shadow_tls
            echo && printf "* 按回车返回主菜单 *" && read
            show_menu
            ;;
        3)
            uninstall_shadow_tls
            echo && printf "* 按回车返回主菜单 *" && read
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
