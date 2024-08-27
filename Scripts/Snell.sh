#!/bin/bash

# last updated: 2024/8/27 18:12

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
current_version="v4.1.0b1"

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
}

# 判断输入的参数
if [[ $1 == "uninstall" ]]; then
  uninstall_snell
  exit 0
fi

if [[ $1 == "update" ]]; then
  if [[ "$current_version" != "$snell_version" ]]; then
    update_snell
  else
    echo "当前已是最新版本 (${current_version})，无需更新"
  fi
  exit 0
fi

# 获取用户输入的配置信息
read -r -p "请输入 Snell 监听端口 (留空默认随机端口号): " snell_port
snell_port=${snell_port:-$(shuf -i 1024-65535 -n 1)}

read -r -p "请输入 Snell 密码 (留空随机生成): " snell_password
if [[ -z "$snell_password" ]]; then
  snell_password=$(openssl rand -base64 32)
fi

read -r -p "是否开启 HTTP 混淆 (Y/N 默认不开启): " enable_http_obfs
if [[ ${enable_http_obfs,,} == "y" ]]; then
  snell_obfs="http"
else
  snell_obfs="off"
fi

read -r -p "是否开启 ipv6 混淆 (Y/N 默认不开启): " snell_ipv6
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
  [yY])
    echo "开始安装进行安装"
  ;;
  *)
    echo "已取消安装"
    exit 0
    ;;
esac

# 下载 Snell
wget -N --no-check-certificate https://dl.nssurge.com/snell/snell-server-${snell_version}-linux-${snell_type}.zip
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
User=nobody
Group=nogroup
LimitNOFILE=32768
ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell-server.conf
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF

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
