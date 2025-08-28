#!/usr/bin/env bash

# docker-easy: Docker 容器管理工具

SCRIPT_PATH="/usr/local/bin/docker-easy"

# 检查 jq 依赖
check_jq() {
    if ! command -v jq &>/dev/null; then
        echo "⚠️ 缺少依赖: jq"
        echo "是否安装 jq？(y/n)"
        read -r choice
        if [[ "$choice" == "y" ]]; then
            if command -v apt &>/dev/null; then
                sudo apt update && sudo apt install -y jq
            elif command -v yum &>/dev/null; then
                sudo yum install -y jq
            else
                echo "❌ 未检测到 apt 或 yum，请手动安装 jq"
                exit 1
            fi
        else
            echo "❌ 缺少 jq，已退出"
            exit 1
        fi
    fi
}

# 安装或更新 Docker
install_docker() {
    echo "⚡ 将通过 Docker 官方脚本安装/更新 Docker"
    echo "是否继续？(y/n)"
    read -r choice
    if [[ "$choice" == "y" ]]; then
        curl -fsSL https://get.docker.com | sh
        echo "✅ Docker 已安装/更新完成"
        docker --version
    else
        echo "❌ 已取消安装"
    fi
}

# 检查镜像是否已是最新版本
check_image_up_to_date() {
    local image="$1"
    local pull_output="$2"
    
    # 检查Docker输出中是否包含"Image is up to date"或"Status: Image is up to date"
    if echo "$pull_output" | grep -q "Image is up to date\|Status: Image is up to date"; then
        return 0  # 已是最新
    else
        return 1  # 不是最新
    fi
}

# 更新容器
update_container() {
    if ! command -v docker &>/dev/null; then
        echo "❌ 未检测到 docker，请先安装"
        return 1
    fi

    echo "📋 当前正在运行的容器："
    docker ps --format "table {{.ID}}\t{{.Image}}\t{{.Names}}"

    read -p "请输入要更新的容器名称或 ID (支持模糊匹配): " CONTAINER_NAME
    if [ -z "$CONTAINER_NAME" ]; then
        echo "❌ 容器名称或 ID 不能为空"
        return 1
    fi

    # 清理输入
    CONTAINER_NAME=$(echo "$CONTAINER_NAME" | tr -d '\n\r' | xargs)

    # 改进的匹配逻辑：先尝试ID前缀匹配，再尝试名称匹配
    MATCHING_CONTAINERS=$(docker ps --format "{{.ID}}\t{{.Names}}" | grep -E "(^$CONTAINER_NAME|$CONTAINER_NAME)")

    if [ -z "$MATCHING_CONTAINERS" ]; then
        echo "❌ 未找到名称或 ID 包含 '$CONTAINER_NAME' 的容器"
        return 1
    fi

    COUNT=$(echo "$MATCHING_CONTAINERS" | wc -l | awk '{print $1}')
    if [ "$COUNT" -gt 1 ]; then
        echo "找到多个匹配的容器："
        echo "ID\t名称"
        echo "$MATCHING_CONTAINERS"
        read -p "请输入要更新的容器完整 ID: " USER_SELECTION
        USER_SELECTION=$(echo "$USER_SELECTION" | tr -d '\n\r' | xargs)
        
        # 验证用户选择的ID是否存在
        CID=$(echo "$MATCHING_CONTAINERS" | awk -v sel="$USER_SELECTION" '$1 == sel {print $1}')
        if [ -z "$CID" ]; then
            echo "❌ 无效的选择"
            return 1
        fi
    else
        CID=$(echo "$MATCHING_CONTAINERS" | awk '{print $1}')
    fi

    # 获取容器信息
    if ! CNAME=$(docker inspect --format='{{.Name}}' "$CID" 2>/dev/null | sed 's#^/##'); then
        echo "❌ 无法获取容器 $CID 的信息"
        return 1
    fi
    
    IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CID")
    echo "✅ 选中容器: $CNAME (当前镜像: $IMAGE)"

    # 提示用户输入版本号
    read -p "请输入目标镜像版本号（直接回车拉取最新版本）: " IMAGE_VERSION
    if [ -n "$IMAGE_VERSION" ] && ! echo "$IMAGE_VERSION" | grep -qE '^[a-zA-Z0-9._:-]+$'; then
        echo "❌ 无效的版本号格式"
        return 1
    fi
    
    # 构建目标镜像名称
    BASE_IMAGE=$(echo "$IMAGE" | cut -d: -f1)
    if [ -z "$IMAGE_VERSION" ]; then
        TARGET_IMAGE="$BASE_IMAGE:latest"
    else
        TARGET_IMAGE="$BASE_IMAGE:$IMAGE_VERSION"
    fi
    
    echo "🔄 目标镜像: $TARGET_IMAGE"

    # 检查当前镜像是否已是目标版本
    CURRENT_IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CID")
    if [ "$CURRENT_IMAGE" = "$TARGET_IMAGE" ]; then
        echo "✅ 容器 $CNAME 已是目标版本 ($TARGET_IMAGE)，无需更新"
        return 0
    fi

    # 拉取 Watchtower 镜像（如果不存在）
    if ! docker image inspect containrrr/watchtower >/dev/null 2>&1; then
        echo "🔄 拉取 Watchtower 镜像..."
        if ! docker pull containrrr/watchtower; then
            echo "❌ 无法拉取 Watchtower 镜像"
            return 1
        fi
    fi

    # 使用 Watchtower 更新
    echo "⚡ 使用 Watchtower 进行零停机更新..."
    WATCHTOWER_OUTPUT=$(docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        containrrr/watchtower \
        --cleanup \
        --run-once \
        "$CNAME" \
        --image "$TARGET_IMAGE" 2>&1)

    echo "$WATCHTOWER_OUTPUT"

    # 检查更新结果
    if echo "$WATCHTOWER_OUTPUT" | grep -q "Found new.*image for"; then
        echo "✅ 容器 $CNAME 更新成功到 $TARGET_IMAGE"
        return 0
    elif echo "$WATCHTOWER_OUTPUT" | grep -q "No updates found"; then
        echo "✅ 容器 $CNAME 已是最新版本 ($TARGET_IMAGE)"
        return 0
    else
        echo "⚠️ 更新状态不明，已记录到日志 /var/log/container_update.log"
        mkdir -p /var/log
        echo "[$(date)] 更新容器 $CNAME 到 $TARGET_IMAGE" >> /var/log/container_update.log
        echo "$WATCHTOWER_OUTPUT" >> /var/log/container_update.log
        return 1
    fi
}

# 停止容器
stop_container() {
    docker ps --format "table {{.ID}}\t{{.Names}}"
    read -p "请输入要停止的容器ID: " CID
    docker stop "$CID" && echo "✅ 容器已停止"
}

# 强制停止容器
force_stop_container() {
    docker ps --format "table {{.ID}}\t{{.Names}}"
    read -p "请输入要强制停止的容器ID: " CID
    docker kill "$CID" && echo "✅ 容器已强制停止"
}

# 启动容器
start_container() {
    docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
    read -p "请输入要启动的容器ID: " CID
    docker start "$CID" && echo "✅ 容器已启动"
}

# 重启容器
restart_container() {
    docker ps --format "table {{.ID}}\t{{.Names}}"
    read -p "请输入要重启的容器ID: " CID
    docker restart "$CID" && echo "✅ 容器已重启"
}

# 删除容器
remove_container() {
    docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
    read -p "请输入要删除的容器ID: " CID
    docker rm -f "$CID" && echo "✅ 容器已删除"
}

# 删除镜像
remove_image() {
    docker images --format "table {{.ID}}\t{{.Repository}}\t{{.Tag}}"
    read -p "请输入要删除的镜像ID: " IID
    docker rmi -f "$IID" && echo "✅ 镜像已删除"
}

# Docker 服务管理
docker_service() {
    echo ""
    echo "=== Docker 服务管理 ==="
    echo "1. 启动 Docker"
    echo "2. 停止 Docker"
    echo "3. 重启 Docker"
    echo "0. 返回"
    read -p "请选择操作: " opt
    case $opt in
        1) sudo systemctl start docker 2>/dev/null || sudo service docker start ;;
        2) sudo systemctl stop docker 2>/dev/null || sudo service docker stop ;;
        3) sudo systemctl restart docker 2>/dev/null || sudo service docker restart ;;
        0) return ;;
        *) echo "❌ 无效选择" ;;
    esac
    echo "✅ 操作完成"
}

# 容器操作子菜单
container_operations() {
    while true; do
        echo ""
        echo "=== 容器操作 ==="
        echo "1. 启动容器"
        echo "2. 停止容器"
        echo "3. 强制停止容器"
        echo "4. 重启容器"
        echo "5. 删除容器"
        echo "0. 返回主菜单"
        read -p "请选择操作: " choice
        case $choice in
            1) start_container ;;
            2) stop_container ;;
            3) force_stop_container ;;
            4) restart_container ;;
            5) remove_container ;;
            0) return ;;
            *) echo "❌ 无效选择" ;;
        esac
    done
}

# 卸载脚本
uninstall_script() {
    echo "是否卸载 docker-easy 脚本？(y/n)"
    read -r confirm
    if [[ "$confirm" == "y" ]]; then
        rm -f "$SCRIPT_PATH"
        echo "✅ 已卸载 docker-easy"
        exit 0
    fi
}

# 卸载全部（Docker所有容器、镜像和脚本本身）
uninstall_all() {
    echo "⚠️  警告：此操作将删除所有Docker容器、镜像、卷以及docker-easy脚本本身！"
    echo "⚠️  这是一个不可逆的操作，请谨慎选择！"
    echo "是否继续？(y/n)"
    read -r confirm
    if [[ "$confirm" != "y" ]]; then
        echo "❌ 已取消卸载"
        return
    fi

    # 停止并删除所有容器
    if docker ps -aq 2>/dev/null | grep -q .; then
        echo "🛑 停止并删除所有容器..."
        docker stop $(docker ps -aq) 2>/dev/null
        docker rm -f $(docker ps -aq) 2>/dev/null
    fi

    # 删除所有镜像
    if docker images -q 2>/dev/null | grep -q .; then
        echo "🗑️  删除所有镜像..."
        docker rmi -f $(docker images -q) 2>/dev/null
    fi

    # 删除所有卷
    if docker volume ls -q 2>/dev/null | grep -q .; then
        echo "🗑️  删除所有卷..."
        docker volume rm -f $(docker volume ls -q) 2>/dev/null
    fi

    # 删除所有网络（除了默认网络）
    if docker network ls -q --filter type=custom 2>/dev/null | grep -q .; then
        echo "🗑️  删除所有自定义网络..."
        docker network rm $(docker network ls -q --filter type=custom) 2>/dev/null
    fi

    # 卸载Docker
    echo "🗑️  卸载Docker..."
    if command -v apt &>/dev/null; then
        sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        sudo apt-get autoremove -y
    elif command -v yum &>/dev/null; then
        sudo yum remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

    # 删除Docker相关文件和目录
    echo "🧹 清理Docker相关文件..."
    sudo rm -rf /var/lib/docker
    sudo rm -rf /var/lib/containerd
    sudo rm -rf /etc/docker

    # 删除脚本
    echo "🗑️  删除docker-easy脚本..."
    sudo rm -f "$SCRIPT_PATH"

    echo "✅ 所有Docker组件和脚本已完全卸载！"
    exit 0
}

# 更新脚本
update_script() {
    echo "⬇️ 正在更新 docker-easy 脚本..."

    # 创建备份
    BACKUP_PATH="${SCRIPT_PATH}.bak"
    sudo cp "$SCRIPT_PATH" "$BACKUP_PATH"
    echo "📦 已创建备份: $BACKUP_PATH"

    SCRIPT_URL="https://raw.githubusercontent.com/Lanlan13-14/Docker-Easy/refs/heads/main/docker.sh"
    tmpfile=$(mktemp)

    if curl -fsSL "$SCRIPT_URL" -o "$tmpfile"; then
        # 检查下载的脚本是否有效
        if bash -n "$tmpfile" 2>/dev/null; then
            chmod +x "$tmpfile"
            sudo mv "$tmpfile" "$SCRIPT_PATH"
            echo "✅ docker-easy 脚本已更新完成！"

            # 询问是否重新加载脚本
            echo "是否立即重新加载脚本？(y/n)"
            read -r reload_choice
            if [[ "$reload_choice" == "y" ]]; then
                echo "🔄 重新加载脚本..."
                exec sudo bash "$SCRIPT_PATH"
            else
                echo "ℹ️  下次使用请输入: sudo docker-easy"
            fi

            # 删除备份
            sudo rm -f "$BACKUP_PATH"
        else
            echo "❌ 下载的脚本语法有误，恢复备份..."
            sudo mv "$BACKUP_PATH" "$SCRIPT_PATH"
            rm -f "$tmpfile"
            echo "✅ 已恢复备份脚本"
        fi
    else
        echo "❌ 更新失败，恢复备份..."
        sudo mv "$BACKUP_PATH" "$SCRIPT_PATH"
        rm -f "$tmpfile"
        echo "✅ 已恢复备份脚本"
        echo "❌ 请检查网络或链接是否有效"
    fi
}

# 卸载菜单
uninstall_menu() {
    while true; do
        echo ""
        echo "=== 卸载选项 ==="
        echo "1. 仅卸载脚本"
        echo "2. 卸载全部（Docker所有容器、镜像和脚本）"
        echo "0. 返回主菜单"
        read -p "请选择操作: " choice
        case $choice in
            1) uninstall_script ;;
            2) uninstall_all ;;
            0) return ;;
            *) echo "❌ 无效选择" ;;
        esac
    done
}

# 主菜单
menu() {
    check_jq
    while true; do
        echo ""
        echo "====== Docker Easy 工具 ======"
        echo "1. 更新容器"
        echo "2. 安装/更新 Docker"
        echo "3. 容器操作"
        echo "4. 删除镜像"
        echo "5. Docker 服务管理"
        echo "6. 卸载选项"
        echo "7. 更新 docker-easy 脚本"
        echo "0. 退出"
        echo "================================"
        read -p "请选择操作: " choice
        case $choice in
            1) update_container ;;
            2) install_docker ;;
            3) container_operations ;;
            4) remove_image ;;
            5) docker_service ;;
            6) uninstall_menu ;;
            7) update_script ;;
            0) 
                echo "👋 已退出 docker-easy，下次使用请输入: sudo docker-easy"
                exit 0 ;;
            *) echo "❌ 无效选择" ;;
        esac
    done
}

menu