#!/bin/bash

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
  echo "请切换到 root 用户后再运行脚本"
  exit 1
fi

# 检查必要工具是否安装
for cmd in wget unzip curl; do
  if ! command -v $cmd &> /dev/null; then
    echo "$cmd 未安装，请安装后再运行脚本"
    exit 1
  fi
done

# 从官方网站获取最新版本号
latest_version=$(curl -s https://manual.nssurge.com/others/snell.html | grep -oP 'snell-server-\K[^\-]+' | head -1)
current_version=$(snell-server -v 2>&1 | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+')

snell_version=${latest_version:-$current_version}

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

# 卸载 Snell 函数
uninstall_snell() {
  systemctl stop snell.service || { echo "无法停止 Snell 服务"; exit 1; }
  systemctl disable snell.service || { echo "无法取消开机自启"; exit 1; }
  rm -f /lib/systemd/system/snell.service
  rm -f /etc/snell/snell-server.conf
  rm -f /usr/local/bin/snell-server
  echo "Snell 已卸载"
  before_show_menu
}

# 更新 Snell 函数
update_snell() {
  systemctl stop snell.service || { echo "无法停止 Snell 服务"; exit 1; }
  wget -N --no-check-certificate https://dl.nssurge.com/snell/snell-server-${snell_version}-linux-${snell_type}.zip
  unzip snell-server-${snell_version}-linux-${snell_type}.zip || { echo "解压失败"; exit 1; }
  mv snell-server /usr/local/bin/snell-server || { echo "移动文件失败"; exit 1; }
  chmod +x /usr/local/bin/snell-server
  rm snell-server-${snell_version}-linux-${snell_type}.zip
  systemctl restart snell.service || { echo "无法重启 Snell 服务"; exit 1; }
  echo "Snell 已更新到版本 ${snell_version}"
  before_show_menu
}

# 检查是否需要更新
check_update() {
  if [[ "$current_version" != "$snell_version" ]]; then
    update_snell
  else
    echo "当前已是最新版本 (${current_version})，无需更新"
    before_show_menu
  fi
}

# 安装 Snell 函数
install_snell() {
  # 获取用户输入的配置信息
  read -r -p "请输入 Snell 监听端口 (留空默认随机端口号): " snell_port
  snell_port=${snell_port:-$(shuf -i 10000-30000 -n 1)}

  read -r -p "请输入 Snell 密码 (留空随机生成): " snell_password
  if [[ -z "$snell_password" ]]; then
    snell_password=$(openssl rand -base64 24)
  fi

  read -r -p "是否开启 HTTP 混淆 (Y/N 默认不开启): " enable_http_obfs
  if [[ ${enable_http_obfs,,} == "y" ]]; then
    snell_obfs="http"
  else
    snell_obfs="off"
  fi

  read -r -p "是否开启 ipv6 (Y/N 默认不开启): " snell_ipv6
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

  read -r -p "确认无误？(Y/N) " confirm
  case "$confirm" in
    [yY]) ;;
    *)
      echo "已取消安装"
      before_show_menu
      return
      ;;
  esac

  # 下载并安装 Snell
  wget -N --no-check-certificate https://dl.nssurge.com/snell/snell-server-${snell_version}-linux-${snell_type}.zip
    # 检查 unzip 是否安装
  if ! command -v unzip &> /dev/null; then
      echo "unzip 未安装。"
      read -p "是否要安装 unzip？(y/n): " choice
      case "$choice" in
          y|Y)
              # 尝试安装 unzip
              if [[ "$OSTYPE" == "linux-gnu"* ]]; then
                  # 针对 Debian/Ubuntu 系统
                  sudo apt update && sudo apt install -y unzip
              elif [[ "$OSTYPE" == "darwin"* ]]; then
                  # 针对 macOS 系统
                  brew install unzip
              else
                  echo "不支持的操作系统，无法自动安装 unzip。"
                  exit 1
              fi
              ;;
          n|N)
              echo "用户选择不安装 unzip，退出。"
              exit 1
              ;;
          *)
              echo "无效的输入。退出。"
              exit 1
              ;;
      esac
  fi
  # 解压安装
  unzip snell-server-${snell_version}-linux-${snell_type}.zip || { echo "解压失败"; exit 1; }
  mv snell-server /usr/local/bin/snell-server || { echo "移动文件失败"; exit 1; }
  chmod +x /usr/local/bin/snell-server
  rm snell-server-${snell_version}-linux-${snell_type}.zip

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
      mkdir -p /etc/snell
  fi

  # 创建 Snell 配置文件
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

  echo "Snell 安装成功，版本: ${snell_version}"
  echo "客户端连接信息: "
  echo "端口: ${snell_port}"
  echo "密码: ${snell_password}"
  echo "混淆: ${snell_obfs}"
  echo "ipv6：${snell_ipv6}"
  before_show_menu
}

# 显示菜单前的等待函数
before_show_menu() {
    echo && printf "* 按回车返回主菜单 *" && read temp
    show_menu
}

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
            ;;
        2)
            check_update
            ;;
        3)
            uninstall_snell
            ;;
        *)
            echo "请输入正确的数字 [0-3]"
            show_menu
            ;;
    esac
}

# 启动菜单
show_menu
