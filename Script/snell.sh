#!/bin/bash
# last updated:2024/11/14

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
  echo "请切换到 root 用户后再运行脚本"
  exit 1
fi

# 检查并自动安装必要工具
for cmd in wget unzip curl; do
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

# 从官方网站获取最新版本号
latest_version=$(curl -s https://manual.nssurge.com/others/snell.html | grep -oP 'snell-server-\K[^\-]+' | head -1)
current_version=$(snell-server -v 2>&1 | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+')

#snell_version=${latest_version:-$current_version}

# 检查系统架构
case "$(uname -m)" in
  x86_64)
    snell_type="amd64"
    ;;
  aarch64)
    snell_type="aarch64"
    ;;
  *)
    echo "$(uname -m) 架构不支持"
    exit 1
    ;;
esac

# 生成客户端配置
generate_client_config() {
  local server_ip=$(hostname -I | awk '{print $1}')  # 获取私有 IP 地址
  local obfs_param=""

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

  # 输出配置
  echo "name = snell, ${server_ip}, ${snell_port}, psk=${snell_password}, version=4${obfs_param}${reuse_param}"
}

# 卸载 Snell 函数
uninstall_snell() {
  systemctl stop snell.service || { echo "无法停止 Snell 服务"; exit 1; }
  systemctl disable snell.service || { echo "无法取消开机自启"; exit 1; }
  rm -f /lib/systemd/system/snell.service
  rm -rf /etc/snell
  rm -f /usr/local/bin/snell-server
  echo "Snell 已卸载"
}

# 更新 Snell 函数
update_snell() {
  if [[ "$current_version" == "$latest_version" ]]; then
    echo "当前已是最新版本 (${current_version})，无需更新"
    return
  fi

  systemctl stop snell.service || { echo "无法停止 Snell 服务"; exit 1; }
  wget -N --no-check-certificate https://dl.nssurge.com/snell/snell-server-${latest_version}-linux-${snell_type}.zip
  unzip snell-server-${latest_version}-linux-${snell_type}.zip || { echo "解压失败"; exit 1; }
  mv snell-server /usr/local/bin/snell-server || { echo "移动文件失败"; exit 1; }
  chmod +x /usr/local/bin/snell-server
  rm snell-server-${latest_version}-linux-${snell_type}.zip
  systemctl restart snell.service || { echo "无法重启 Snell 服务"; exit 1; }
  echo "Snell 已更新到版本 ${latest_version}"
}

# 检查是否需要更新
# check_update() {
#   if [[ "$current_version" != "$snell_version" ]]; then
#     update_snell
#   else
#     echo "当前已是最新版本 (${current_version})，无需更新"
#     before_show_menu
#   fi
# }

# 安装 Snell 函数
install_snell() {
  # 获取用户输入的配置信息
  read -r -p "请输入 Snell 监听端口 (默认随机): " snell_port
  snell_port=${snell_port:-$(shuf -i 10000-30000 -n 1)}

  read -r -p "请输入 Snell 密码 (默认随机): " snell_password
  if [[ -z "$snell_password" ]]; then
    snell_password=$(openssl rand -base64 24)
  fi

  read -r -p "是否开启 HTTP 混淆? (y/N)" enable_http_obfs
  if [[ ${enable_http_obfs,,} == "y" ]]; then
    snell_obfs="http"
  else
    snell_obfs="off"
  fi

  read -r -p "是否开启 ipv6? (y/N)" snell_ipv6
  if [[ ${snell_ipv6,,} == "y" ]]; then
    snell_ipv6="true"
  else
    snell_ipv6="false"
  fi

  # 显示配置信息
  cat <<EOF
请确认以下配置信息：
端口：${snell_port}
密码：${snell_password}
混淆：${snell_obfs}
ipv6：${snell_ipv6}
EOF

  read -r -p "是否确认无误? (y/n)" confirm
  case "$confirm" in
    [yY]) ;;
    *)
      echo "已取消安装"
      return
      ;;
  esac

  # 下载并安装 Snell
  wget -N --no-check-certificate https://dl.nssurge.com/snell/snell-server-${latest_version}-linux-${snell_type}.zip
  unzip snell-server-${latest_version}-linux-${snell_type}.zip || { echo "解压失败"; exit 1; }
  mv snell-server /usr/local/bin/snell-server || { echo "移动文件失败"; exit 1; }
  chmod +x /usr/local/bin/snell-server
  rm snell-server-${latest_version}-linux-${snell_type}.zip

  # 创建 Systemd 服务文件
  cat > /lib/systemd/system/snell.service <<EOF
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
Type=simple
User=root
Group=nogroup
LimitNOFILE=32768
ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell-server.conf
StandardOutput=null
StandardError=null
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF

  # 创建 Snell 配置文件
  if [ ! -d "/etc/snell" ]; then
    # 如果 /etc/snell 文件夹不存在，创建该文件夹
      mkdir /etc/snell
  fi

  cat > /etc/snell/snell-server.conf <<EOF
[snell-server]
listen = 0.0.0.0:${snell_port}
psk = ${snell_password}
ipv6 = ${snell_ipv6}
obfs = ${snell_obfs}
EOF

  # 启动并启用 Snell 服务
  systemctl daemon-reload || { echo "无法重载 daemon"; exit 1; }
  systemctl start snell.service || { echo "无法启动 Snell 服务"; exit 1; }
  systemctl enable snell.service || { echo "无法设置开机自启"; exit 1; }

  echo "Snell 安装成功，版本: ${latest_version}"
  echo "客户端连接信息: "
  echo "端口: ${snell_port}"
  echo "密码: ${snell_password}"
  echo "混淆: ${snell_obfs}"
  echo "ipv6：${snell_ipv6}"

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
    Snell 管理脚本
    --------------------------
    1. 安装 Snell
    2. 更新 Snell
    3. 卸载 Snell
    0. 退出脚本
    "
    echo && printf "请输入选择 [0-3]: " && read -r num
    case "${num}" in
        0)
            exit 0
            ;;
        1)
            install_snell
            echo && printf "* 按回车返回主菜单 *" && read temp
            show_menu
            ;;
        2)
            update_snell
            echo && printf "* 按回车返回主菜单 *" && read temp
            show_menu
            ;;
        3)
            uninstall_snell
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
  uninstall_snell
  exit 0
fi
if [[ $1 == "update" ]]; then
  update_snell
  exit 0
fi

# 启动菜单
show_menu
