#!/bin/bash
# last updated:2024/11/14

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
  echo "请切换到 root 用户后再运行脚本"
  exit 1
fi

# 检查并自动安装必要工具
for cmd in wget tar curl xz; do
  if ! command -v $cmd &> /dev/null; then
    echo "$cmd 未安装，正在安装..."
    
    # 使用 apt 安装缺少的工具
    apt update

    # 对于 xz，确保安装 xz-utils
    if [ "$cmd" == "xz" ]; then
      cmd="xz-utils"
    fi
    
    if ! apt install -y $cmd; then
      echo "$cmd 安装失败，请检查系统或网络连接。"
      exit 1
    fi
  fi
done


# 获取最新版本号
latest_version=$(curl -m 10 -sL "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | awk -F'"' '/tag_name/{print $4}')
current_version="v$(ssserver -V 2>&1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+')"

# 检查系统架构
case "$(uname -m)" in
  x86_64)
    ss_type="x86_64-unknown-linux-gnu"
    ;;
  aarch64)
    ss_type="aarch64-unknown-linux-gnu"
    ;;
  *)
    echo "$(uname -m) 架构不支持"
    exit 1
    ;;
esac

# 生成客户端配置
generate_client_config() {
  local server_ip=$(hostname -I | awk '{print $1}')  # 获取私有 IP 地址

  # 选择是否开启 udp
  local surge_udp_relay_param=", udp-relay=true"
  local mihomo_udp_param="true"
  read -r -p "是否开启 udp? (Y/n)" udp_choice
  if [[ ${udp_choice} == "n" ]]; then
    surge_udp_relay_param=""
    mihomo_udp_param="false"
  elif [[ ! ${ss_mode} =~ .*udp.* ]]; then
    echo "开启 udp 失败！"
    echo "Surge udp-relay 参数和 Mihomo Party udp 参数添加失败！"
    echo "该配置未开启 udp，请更改 mode 为 tcp_and_udp 或 udp_only！"
    surge_udp_relay_param=""
    mihomo_udp_param="false"
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
      echo "name = ss, ${server_ip}, ${ss_port}, encrypt-method=${encryption_method}, password=${ss_password}${surge_udp_relay_param}"
    ;;
    2)
      # 输出 Mihomo Party 配置
      echo
      cat << EOF
Mihomo Party 客户端配置如下: 
- name: "name"
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
      echo "无效选择，默认自动输出所有客户端配置！"
      echo "Surge 客户端配置如下: "
      echo "name = ss, ${server_ip}, ${ss_port}, encrypt-method=${encryption_method}, password=${ss_password}${surge_udp_relay_param}"
      echo
      cat << EOF
Mihomo Party 客户端配置如下: 
- name: "name"
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

# 更新 Shadowsocks-Rust 函数
update_ss() {
  if [[ "$current_version" == "$latest_version" ]]; then
    echo "当前已是最新版本 (${current_version})，无需更新"
    return
  fi

  systemctl stop ss-rust.service || { echo "无法停止 Shadowsocks-Rust 服务"; exit 1; }
  wget -N "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${latest_version}/shadowsocks-${latest_version}.${ss_type}.tar.xz"
  tar -xvf "shadowsocks-${latest_version}.${ss_type}.tar.xz"
  mv -f ssserver /usr/local/bin/
  rm -f sslocal ssmanager ssservice ssurl
  chmod +x /usr/local/bin/ssserver
  rm shadowsocks-${latest_version}.${ss_type}.tar.xz
  systemctl start ss-rust.service || { echo "无法重启 Shadowsocks-Rust 服务"; exit 1; }
  echo "Shadowsocks-Rust 已更新到版本 ${latest_version}"
}

# 检查是否需要更新
# check_update() {
#   if [[ "$current_version" != "$latest_version" ]]; then
#     update_ss
#   else
#     echo "当前已是最新版本 (${current_version})，无需更新"
#     before_show_menu
#   fi
# }

# 安装 Shadowsocks-Rust 函数
install_ss() {
  # 获取用户输入的配置信息
  read -r -p "请输入 Shadowsocks-Rust 监听端口 (默认随机): " ss_port
  ss_port=${ss_port:-$(shuf -i 10000-30000 -n 1)}

  # 获取用户输入的配置信息
  read -r -p "请输入 Shadowsocks 密码 (默认随机): " ss_password
  if [[ -z "$ss_password" ]]; then
    # 选择加密方法
    echo "选择加密方法:"
    echo "1. aes-256-gcm"
    echo "2. chacha20-ietf-poly1305"
    echo "3. aes-128-gcm"
    echo "4. 2022-blake3-aes-256-gcm (默认)"
    echo "5. 2022-blake3-aes-128-gcm"
    read -r -p "请选择加密方法 [1-5]: " method_choice

    case $method_choice in
      1) encryption_method="aes-256-gcm" ;;
      2) encryption_method="chacha20-ietf-poly1305" ;;
      3) encryption_method="aes-128-gcm" ;;
      4) encryption_method="2022-blake3-aes-256-gcm" ;;
      5) encryption_method="2022-blake3-aes-128-gcm" ;;
      *) echo "无效选择，使用默认 2022-blake3-aes-256-gcm" ; encryption_method="2022-blake3-aes-256-gcm" ;;
    esac

    # 根据选择的加密方法生成密码
    if [[ "$encryption_method" == "2022-blake3-aes-256-gcm" ]]; then
      ss_password=$(openssl rand -base64 32)
    elif [[ "$encryption_method" == "2022-blake3-aes-128-gcm" ]]; then
      ss_password=$(openssl rand -base64 16)
    else
      ss_password=$(openssl rand -base64 32)  # 默认情况
    fi
  fi

  # 选择传输模式
  echo "选择传输模式: "
  echo "1. tcp_and_udp (默认)"
  echo "2. tcp_only"
  echo "3. udp_only"
  read -r -p "请选择传输模式 [1-3]: " mode_choice

  case $mode_choice in
    1) ss_mode="tcp_and_udp" ;;
    2) ss_mode="tcp_only" ;;
    3) ss_mode="udp_only" ;;
    *) echo "无效选择，使用默认 tcp_and_udp" ; ss_mode="tcp_and_udp" ;;
  esac

  read -r -p "是否开启 TFO? (y/N)" enable_tfo
  if [[ ${enable_tfo,,} == "y" ]]; then
    ss_tfo=true
  else
    ss_tfo=false
  fi

  # 显示配置信息
  cat << EOF
请确认以下配置信息：
端口：${ss_port}
密码：${ss_password}
TFO：${ss_tfo}
加密方法：${encryption_method}
传输模式：${ss_mode}
EOF

  read -r -p "是否确认无误? (y/n)" confirm
  case "$confirm" in
    [yY]) ;;
    *)
      echo "已取消安装"
      return
      ;;
  esac

  # 下载并安装 Shadowsocks-Rust
  wget -N "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${latest_version}/shadowsocks-${latest_version}.${ss_type}.tar.xz"
  tar -xvf "shadowsocks-${latest_version}.${ss_type}.tar.xz"
  mv -f ssserver /usr/local/bin/
  rm -f sslocal ssmanager ssservice ssurl
  chmod +x /usr/local/bin/ssserver
  rm shadowsocks-${latest_version}.${ss_type}.tar.xz

  # 创建 Systemd 服务文件
  cat > /lib/systemd/system/ss-rust.service << EOF
[Unit]
Description=Shadowsocks Rust Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
LimitNOFILE=32767 
Type=simple
User=root
Restart=on-failure
RestartSec=5s
DynamicUser=true
ExecStartPre=/bin/sh -c 'ulimit -n 51200'
ExecStart=/usr/local/bin/ssserver -c /etc/ss-rust/config.json

[Install]
WantedBy=multi-user.target
EOF

  # 创建 Shadowsocks 配置文件
  mkdir /etc/ss-rust
  cat > /etc/ss-rust/config.json << EOF
{
    "server": "0.0.0.0",
    "server_port": ${ss_port},
    "password": "${ss_password}",
    "method": "${encryption_method}",
    "mode": "${ss_mode}",  // 可选: tcp_only, udp_only
    "timeout": 300,
    "nameserver": "8.8.8.8",
    "fast_open": ${ss_tfo}, // 可选: true/false
}
EOF

  # 启动并启用 Shadowsocks-Rust 服务
  systemctl daemon-reload || { echo "无法重载 daemon"; exit 1; }
  systemctl start ss-rust.service || { echo "无法启动 Shadowsocks-Rust 服务"; exit 1; }
  systemctl enable ss-rust.service || { echo "无法设置开机自启"; exit 1; }

  echo "Shadowsocks-Rust 安装成功，版本: ${latest_version}"
  echo "客户端连接信息: "
  echo "端口: ${ss_port}"
  echo "密码: ${ss_password}"
  echo "TFO: ${ss_tfo}"
  echo "加密方法: ${encryption_method}"
  echo "传输模式: ${ss_mode}"

  generate_client_config
}

# 卸载 Shadowsocks-Rust 函数
uninstall_ss() {
  systemctl stop ss-rust.service || { echo "无法停止 Shadowsocks-Rust 服务"; exit 1; }
  systemctl disable ss-rust.service || { echo "无法取消开机自启"; exit 1; }
  rm -f /lib/systemd/system/ss-rust.service
  rm -rf /etc/ss-rust
  rm -f /usr/local/bin/ssserver
  echo "Shadowsocks-Rust 已卸载"
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
    Shadowsocks-Rust 管理脚本
    --------------------------
    1. 安装 Shadowsocks-Rust
    2. 更新 Shadowsocks-Rust
    3. 卸载 Shadowsocks-Rust
    0. 退出脚本
    "
    echo && printf "请输入选择 [0-3]: " && read -r num
    case "${num}" in
        0)
            exit 0
            ;;
        1)
            install_ss
            echo && printf "* 按回车返回主菜单 *" && read temp
            show_menu
            ;;
        2)
            update_ss
            echo && printf "* 按回车返回主菜单 *" && read temp
            show_menu
            ;;
        3)
            uninstall_ss
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
  uninstall_ss
  exit 0
fi
if [[ $1 == "update" ]]; then
  update_ss
  exit 0
fi

# 启动菜单
show_menu
