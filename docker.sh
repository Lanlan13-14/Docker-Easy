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
        return
    fi

    echo "📋 当前正在运行的容器："
    docker ps --format "table {{.ID}}\t{{.Image}}\t{{.Names}}"

    read -p "请输入要更新的容器ID(可输入前几位即可): " CONTAINER_ID
    CID=$(docker ps -q --filter "id=$CONTAINER_ID")
    if [ -z "$CID" ]; then
        echo "❌ 未找到容器，请检查输入的ID"
        return
    fi

    CNAME=$(docker inspect --format='{{.Name}}' "$CID" | sed 's#^/##')
    IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CID")
    OLD_IMAGE_ID=$(docker inspect --format='{{.Image}}' "$CID")  # 获取当前镜像ID

    echo "✅ 选中容器: $CNAME (镜像: $IMAGE)"

    # 询问是否指定版本
    echo "是否指定版本？(y/n，默认拉取最新版本)"
    read -r specify_version
    if [[ "$specify_version" == "y" ]]; then
        read -p "请输入版本号 (例如: 1.2.3, alpine, 直接回车使用latest): " VERSION
        # 如果用户未输入版本号，则使用latest
        if [ -z "$VERSION" ]; then
            VERSION="latest"
            echo "ℹ️  未输入版本号，使用默认版本: latest"
        fi
        # 从原镜像中提取镜像名称（去掉版本部分）
        BASE_IMAGE=$(echo "$IMAGE" | cut -d: -f1)
        IMAGE_TO_PULL="${BASE_IMAGE}:${VERSION}"
        echo "ℹ️  将拉取指定版本: $IMAGE_TO_PULL"
        
        # 记录是否是指定版本（非latest）
        IS_SPECIFIC_VERSION=1
        if [[ "$VERSION" == "latest" ]]; then
            IS_SPECIFIC_VERSION=0
        fi
    else
        # 确保镜像名称包含标签
        if [[ "$IMAGE" != *:* ]]; then
            IMAGE_TO_PULL="${IMAGE}:latest"
        else
            IMAGE_TO_PULL="$IMAGE"
        fi
        echo "ℹ️  将拉取最新版本: $IMAGE_TO_PULL"
        IS_SPECIFIC_VERSION=0
    fi

    echo "⬇️ 拉取镜像..."
    PULL_OUTPUT=$(docker pull "$IMAGE_TO_PULL" 2>&1)
    echo "$PULL_OUTPUT"
    
    # 检查是否已是最新版本
    if check_image_up_to_date "$IMAGE_TO_PULL" "$PULL_OUTPUT" && [ $IS_SPECIFIC_VERSION -eq 0 ]; then
        echo "✅ 镜像已是最新版本，无需更新"
        return
    fi

    echo "📥 获取原始启动参数..."
    ORIG_CMD=$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
        assaflavie/runlike "$CID")

    if [ -z "$ORIG_CMD" ]; then
        echo "❌ runlike 获取启动命令失败"
        return
    fi

    # 替换镜像名称
    NEW_CMD=$(echo "$ORIG_CMD" | sed "s|$IMAGE|$IMAGE_TO_PULL|")

    echo "🛑 停止并删除旧容器..."
    docker rm -f "$CID"

    echo "🚀 启动新容器..."
    eval "$NEW_CMD"

    if [ $? -eq 0 ]; then
        echo "✅ 容器 $CNAME 已更新到版本: $IMAGE_TO_PULL"

        # 删除旧镜像（如果新镜像成功启动）
        echo "🧹 清理旧镜像..."
        NEW_IMAGE_ID=$(docker inspect --format='{{.Image}}' $(docker ps -q --filter "name=$CNAME") 2>/dev/null)
        if [ -n "$NEW_IMAGE_ID" ] && [ "$OLD_IMAGE_ID" != "$NEW_IMAGE_ID" ]; then
            # 检查是否有其他容器使用旧镜像
            if [ -z "$(docker ps -a -q --filter ancestor="$OLD_IMAGE_ID" | grep -v "$CID")" ]; then
                docker rmi "$OLD_IMAGE_ID" 2>/dev/null && echo "✅ 旧镜像已删除" || echo "⚠️ 无法删除旧镜像，可能仍被其他容器使用"
            else
                echo "⚠️ 旧镜像仍被其他容器使用，跳过删除"
            fi
        fi
    else
        echo "❌ 容器启动失败，请检查输出"
    fi

    echo "🧹 清理 runlike 镜像..."
    docker rmi -f assaflavie/runlike >/dev/null 2>&1
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