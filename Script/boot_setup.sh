#!/bin/bash
# last updated:2024/11/7

# 更新软件和源
echo "更新软件源和软件..."
apt update -y && apt upgrade -y

# 检查并自动安装必要工具
for cmd in wget tar curl xz unzip jq ufw; do
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

# SSH 设置
SSH_CONF_DIR="/etc/ssh/sshd_config.d"
SSH_CONF_FILE="${SSH_CONF_DIR}/sshd.conf"

# 定义 authorized_keys 文件路径
AUTHORIZED_KEYS_FILE="$HOME/.ssh/authorized_keys"

# 询问用户输入 SSH 端口号
read -p "请输入新的 SSH 端口号 (建议1024-65535之间): " SSH_PORT

# 检查输入的端口号是否有效
if [[ ! $SSH_PORT =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1024 ] || [ "$SSH_PORT" -gt 65535 ]; then
    echo "无效的端口号，请输入1024-65535之间的数字。"
    exit 1
fi

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
        tar -czf "$BACKUP_FILE" "$SSH_CONF_DIR"/*.conf && echo "备份完成: $BACKUP_FILE"
        
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
systemctl restart sshd

# 设置复杂的密码
echo "请手动设置复杂密码："
passwd

# 设置密钥登录
echo "请在终端自行生成密钥对，然后手动将公钥拷贝至 ~/.ssh/authorized_keys。"
echo "确保授权文件权限为 600。"
echo
echo "请将公钥拷贝至 authorized_keys 文件..."
sleep 1
vim ~/.ssh/authorized_keys
echo "authorized_keys 已编辑完毕！"

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
vim "$AUTHORIZED_KEYS_FILE"

# 编辑完成，继续执行脚本后续操作
echo "$AUTHORIZED_KEYS_FILE 文件编辑完成，继续执行脚本..."

# 更改时区
echo "设置时区为 Asia/Shanghai..."
timedatectl set-timezone Asia/Shanghai

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
    ufw allow $SSH_PORT comment "SSH"

    # 允许 HTTP 和 HTTPS 端口
    ufw allow 80
    ufw allow 443

    # 启动 UFW 防火墙，避免提示 y/n
    echo "启用 UFW 防火墙..."
    #ufw --force enable > /dev/null 2>&1
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
echo "安装 docker..."
read -r -p "是否选择安装 docker: (y/n)" docker_choice
if [[ ${docker_choice,,} == "y" ]]; then
    echo "正在安装 docker..."
    curl -fsSL https://get.docker.com | sh
    echo "docker 安装完毕"
    sleep 1
else
    echo "选择不安装 docker"
    sleep 1
fi

# 提示完成
echo "所有设置已完成。请确保新的 SSH 配置已在新终端测试后再关闭该终端。"
