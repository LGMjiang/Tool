#!/bin/bash
# last updated:2026/06/22

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "错误：请以 root 权限运行此脚本。"
  exit 1
fi

# 更新软件和源
echo "更新软件源和软件..."
if ! apt update -y || ! apt upgrade -y; then
  echo "错误：系统更新失败，请检查网络连接或软件源配置。"
  exit 1
fi

# 检查并自动安装必要工具
for cmd in wget tar curl xz unzip jq ufw iperf3 vnstat; do
  if ! command -v $cmd &> /dev/null; then
    echo "$cmd 未安装，正在安装..."

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

# 启动并启用 vnstat 服务
if command -v vnstat &> /dev/null; then
  echo "配置 vnstat 服务..."
  if systemctl enable vnstat && systemctl start vnstat; then
    echo "vnstat 服务已启动并设置为开机自启。"
  else
    echo "警告：vnstat 服务启动失败，请手动检查。"
  fi
fi

# 是否为NAT机器的选择
read -r -p "是否是NAT机器? (y/N): " is_nat_machine
if [[ "${is_nat_machine,,}" == "y" ]]; then
  echo "这是 NAT 机器，将使用适配配置。"
  is_nat_machine=true
else
  echo "这是非 NAT 机器，将使用标准配置。"
  is_nat_machine=false
fi

# SSH 设置
SSH_CONF_DIR="/etc/ssh/sshd_config.d"
SSH_CONF_FILE="${SSH_CONF_DIR}/sshd.conf"

# 定义 authorized_keys 文件路径
AUTHORIZED_KEYS_FILE="$HOME/.ssh/authorized_keys"

# 端口验证函数
validate_port() {
  local port=$1
  local min_port=$2
  local max_port=65535

  if [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge "$min_port" ] && [ "$port" -le "$max_port" ]; then
    return 0
  else
    return 1
  fi
}

# 循环直到用户输入有效的 SSH 端口号
while true; do
  read -r -p "请输入新的 SSH 端口号 (建议1024-65535之间): " SSH_PORT

  if [ "$is_nat_machine" = true ]; then
    # NAT 机器允许 1-65535
    if validate_port "$SSH_PORT" 1; then
      echo "有效的端口号: $SSH_PORT"
      break
    else
      echo "无效的端口号，请输入1-65535之间的数字。"
    fi
  else
    # 非 NAT 机器限制 1024-65535
    if validate_port "$SSH_PORT" 1024; then
      echo "有效的端口号: $SSH_PORT"
      break
    else
      echo "无效的端口号，请输入1024-65535之间的数字。"
    fi
  fi
done

# 确保 SSH 配置目录存在
if [ ! -d "$SSH_CONF_DIR" ]; then
  mkdir -p "$SSH_CONF_DIR"
else
  # 检查目录下是否有 .conf 文件
  if ls "$SSH_CONF_DIR"/*.conf &> /dev/null; then
    # 备份已有配置文件
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="sshd_config_backup_$TIMESTAMP.tar.gz"
    echo "检测到已有配置文件，正在打包备份..."
    
    # 打包备份文件
    if tar -czf "$BACKUP_FILE" "$SSH_CONF_DIR"/*.conf; then
      echo "备份完成: $BACKUP_FILE"
      if ! mv "$BACKUP_FILE" "$SSH_CONF_DIR"; then
        echo "警告：移动备份文件失败，备份文件位于当前目录。"
      fi
    else
      echo "警告：备份失败，将继续执行。"
    fi
    
    # 删除已有配置文件
    rm -f "$SSH_CONF_DIR"/*.conf
  fi
fi

# 创建新的 SSH 配置文件
echo "创建新的 SSH 配置文件..."
cat > "$SSH_CONF_FILE" <<EOF
Port $SSH_PORT
PubkeyAuthentication yes
PasswordAuthentication no
EOF

# 备份原始 sshd 配置文件
if [ ! -f /etc/ssh/sshd_config.bak ]; then
  cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
fi

# 重启 SSH 服务
echo "重启 SSH 服务..."
systemctl daemon-reload

# 检测正确的 SSH 服务名称
SSH_SERVICE="sshd"
if ! systemctl is-enabled sshd &>/dev/null && ! systemctl is-active sshd &>/dev/null; then
  if systemctl is-enabled ssh &>/dev/null || systemctl is-active ssh &>/dev/null; then
    SSH_SERVICE="ssh"
  fi
fi

if systemctl restart "$SSH_SERVICE"; then
  echo "SSH 服务 ($SSH_SERVICE) 已成功重启。"
else
  echo "错误：重启 $SSH_SERVICE 失败，请检查配置文件。" >&2
  systemctl status "$SSH_SERVICE"
  exit 1
fi

# 设置复杂的密码
echo "请手动设置复杂密码："
passwd

# 设置密钥登录
echo "请在终端自行生成密钥对，然后手动将公钥拷贝至 ~/.ssh/authorized_keys。"

# 检查~/.ssh/authorized_keys文件是否存在
if [ -f "$AUTHORIZED_KEYS_FILE" ]; then
  echo "$AUTHORIZED_KEYS_FILE 文件已存在。"
  
  # 检查文件权限是否为 600
  if [ "$(stat -c '%a' "$AUTHORIZED_KEYS_FILE")" -ne 600 ]; then
    echo "权限不正确，正在修改权限为 600..."
    chmod 600 "$AUTHORIZED_KEYS_FILE"
  else
    echo "权限正确，为 600。"
  fi
else
  echo "$AUTHORIZED_KEYS_FILE 文件不存在，正在创建..."
  # 创建文件并设置权限为 600
  mkdir -p "$HOME/.ssh"
  touch "$AUTHORIZED_KEYS_FILE"
  chmod 600 "$AUTHORIZED_KEYS_FILE"
  echo "$AUTHORIZED_KEYS_FILE 文件已创建并设置权限为 600。"
fi

# 文件准备完成，打开文件供用户编辑
echo "请编辑 $AUTHORIZED_KEYS_FILE 文件（保存后继续执行脚本）"
sleep 1
# 使用系统默认编辑器
${VISUAL:-${EDITOR:-vi}} "$AUTHORIZED_KEYS_FILE"

# 编辑完成，继续执行脚本后续操作
echo "$AUTHORIZED_KEYS_FILE 文件编辑完成，继续执行脚本..."

# 更改时区
echo "设置时区为 Asia/Shanghai..."
if ! timedatectl set-timezone Asia/Shanghai; then
  echo "警告：时区设置失败，请手动检查。"
fi

# 配置 UFW 防火墙
echo "配置 UFW 防火墙..."

# 查看 UFW 状态
ufw_status=$(ufw status | head -n 1)

if [[ $ufw_status == *"Status: inactive"* ]]; then
  # 如果 UFW 状态为 inactive，设置默认策略并启用防火墙
  echo "UFW 状态为 inactive，正在进行配置并启用防火墙..."

  # 设置默认策略
  ufw default deny incoming
  ufw default allow outgoing

  # 允许 SSH 端口
  echo "开放 SSH 端口: $SSH_PORT"
  ufw allow "$SSH_PORT" comment "SSH"

  if [ "$is_nat_machine" = false ]; then
    # 允许 HTTP 和 HTTPS 端口
    ufw allow 80 comment "HTTP"
    ufw allow 443 comment "HTTPS"
    ufw allow 5201 comment "iperf3"
  elif [ "$is_nat_machine" = true ]; then
    while true; do
      read -r -p "请输入 iperf3 监听端口 (建议1024-65535之间): " IPERF3_PORT
      if validate_port "$IPERF3_PORT" 1024; then
        echo "有效的端口号: $IPERF3_PORT"
        break
      else
        echo "无效的端口号，请输入1024-65535之间的数字。"
      fi
    done
    ufw allow "$IPERF3_PORT" comment "iperf3"
  fi

  # 启动 UFW 防火墙，避免提示 y/n
  echo "启用 UFW 防火墙..."
  ufw --force enable

elif [[ $ufw_status == *"Status: active"* ]]; then
  # 如果 UFW 状态为 active，检查现有规则
  echo "UFW 状态为 active，正在审查现有规则..."

  # 打印现有规则
  ufw status verbose
  echo "请检查现有规则是否符合需求，如果需要修改，手动操作。"
  read -r -p "是否需要手动操作: (y/n)" manual_choice
  if [[ ${manual_choice,,} == "y" ]]; then
    echo "将要退出脚本进行手动操作..."
    sleep 1
    exit 1
  fi
else
  echo "无法确定 UFW 状态，请检查系统配置。"
  exit 1
fi

# 安装 docker
echo "安装 Docker..."
read -r -p "是否选择安装 Docker: (y/n)" docker_choice
if [[ "${docker_choice,,}" == "y" ]]; then
  echo "正在安装 Docker..."
  if curl -fsSL https://get.docker.com | sh; then
    echo "Docker 安装成功！"
  else
    echo "错误：Docker 安装失败，请检查网络连接或手动安装。"
    exit 1
  fi
  sleep 1
else
  echo "选择不安装 Docker"
  sleep 1
fi

# 提示完成
echo "所有设置已完成。请确保新的 SSH 配置已在新终端测试后再关闭该终端。"
