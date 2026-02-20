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
        return 0 # 已是最新
    else
        return 1 # 不是最新
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
    OLD_IMAGE_ID=$(docker inspect --format='{{.Image}}' "$CID") # 获取当前镜像ID
    echo "✅ 选中容器: $CNAME (镜像: $IMAGE)"

    # 询问是否指定版本
    echo "是否指定版本？(y/n，默认拉取最新版本)"
    read -r specify_version
    if [[ "$specify_version" == "y" ]]; then
        read -p "请输入版本号 (例如: 1.2.3, alpine, 直接回车使用latest): " VERSION
        # 如果用户未输入版本号，则使用latest
        if [ -z "$VERSION" ]; then
            VERSION="latest"
            echo "ℹ️ 未输入版本号，使用默认版本: latest"
        fi
        # 从原镜像中提取镜像名称（去掉版本部分）
        BASE_IMAGE=$(echo "$IMAGE" | cut -d: -f1)
        IMAGE_TO_PULL="${BASE_IMAGE}:${VERSION}"
        echo "ℹ️ 将拉取指定版本: $IMAGE_TO_PULL"
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
        echo "ℹ️ 将拉取最新版本: $IMAGE_TO_PULL"
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

# 停止容器（支持批量）
stop_container() {
    docker ps --format "table {{.ID}}\t{{.Names}}"
    read -p "请输入要停止的容器ID（可多个，空格分隔）: " CIDs
    [ -z "$CIDs" ] && echo "⚠️ 未输入容器ID" && return 1
    docker stop $CIDs && echo "✅ 容器已停止"
}

# 强制停止容器（支持批量）
force_stop_container() {
    docker ps --format "table {{.ID}}\t{{.Names}}"
    read -p "请输入要强制停止的容器ID（可多个，空格分隔）: " CIDs
    [ -z "$CIDs" ] && echo "⚠️ 未输入容器ID" && return 1
    docker kill $CIDs && echo "✅ 容器已强制停止"
}

# 启动容器（支持批量）
start_container() {
    docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
    read -p "请输入要启动的容器ID（可多个，空格分隔）: " CIDs
    [ -z "$CIDs" ] && echo "⚠️ 未输入容器ID" && return 1
    docker start $CIDs && echo "✅ 容器已启动"
}

# 重启容器（支持批量）
restart_container() {
    docker ps --format "table {{.ID}}\t{{.Names}}"
    read -p "请输入要重启的容器ID（可多个，空格分隔）: " CIDs
    [ -z "$CIDs" ] && echo "⚠️ 未输入容器ID" && return 1
    docker restart $CIDs && echo "✅ 容器已重启"
}

# 删除容器（支持批量）
remove_container() {
    docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
    read -p "请输入要删除的容器ID（可多个，空格分隔）: " CIDs
    [ -z "$CIDs" ] && echo "⚠️ 未输入容器ID" && return 1
    docker rm -f $CIDs && echo "✅ 容器已删除"
}

# 进入容器
enter_container() {
    docker ps --format "table {{.ID}}\t{{.Names}}"
    read -p "请输入要进入的容器名称: " CONTAINER_NAME
    if [ -z "$CONTAINER_NAME" ]; then
        echo "⚠️ 未输入容器名称"
        return 1
    fi
    CID=$(docker ps -q -f name="$CONTAINER_NAME")
    if [ -z "$CID" ]; then
        echo "❌ 未找到运行中的容器: $CONTAINER_NAME"
        echo "请确保容器正在运行，并检查名称是否正确"
        return 1
    fi
    FULL_ID=$(docker ps --filter "id=$CID" --format "{{.ID}}")
    echo "✅ 进入容器 $CONTAINER_NAME (ID: $FULL_ID)"
    docker exec -it "$CONTAINER_NAME" /bin/bash || docker exec -it "$CONTAINER_NAME" /bin/sh
}

# 查看容器日志
view_container_logs() {
    docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
    read -p "请输入要查看日志的容器名称: " CONTAINER_NAME
    if [ -z "$CONTAINER_NAME" ]; then
        echo "⚠️ 未输入容器名称"
        return 1
    fi
    CID=$(docker ps -aq -f name="$CONTAINER_NAME")
    if [ -z "$CID" ]; then
        echo "❌ 未找到容器: $CONTAINER_NAME"
        return 1
    fi
    FULL_ID=$(docker ps -a --filter "id=$CID" --format "{{.ID}}")
    echo "📊 查看容器 $CONTAINER_NAME (ID: $FULL_ID) 的日志:"
    echo "----------------------------------------"
    docker logs "$CONTAINER_NAME"
    echo "----------------------------------------"
}

# 删除镜像（支持批量）
remove_image() {
    docker images --format "table {{.ID}}\t{{.Repository}}\t{{.Tag}}"
    read -p "请输入要删除的镜像ID（可输入多个，空格分隔）: " IIDs
    if [ -z "$IIDs" ]; then
        echo "⚠️ 未输入任何镜像ID"
        return 1
    fi
    docker rmi -f $IIDs && echo "✅ 镜像已删除"
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
        echo "6. 进入容器"
        echo "7. 查看容器日志"
        echo "0. 返回主菜单"
        read -p "请选择操作: " choice
        case $choice in
            1) start_container ;;
            2) stop_container ;;
            3) force_stop_container ;;
            4) restart_container ;;
            5) remove_container ;;
            6) enter_container ;;
            7) view_container_logs ;;
            0) return ;;
            *) echo "❌ 无效选择" ;;
        esac
    done
}

# 设置 Watchtower 自动更新
setup_watchtower() {
    if ! command -v docker &>/dev/null; then
        echo "❌ 未检测到 docker，请先安装"
        return
    fi

    echo "🔍 检查现有 Watchtower 容器..."
    WATCHTOWER_CONTAINER=$(docker ps -a --filter "name=watchtower" --format "{{.ID}}")

    if [ -n "$WATCHTOWER_CONTAINER" ]; then
        echo "⚠️ 发现已存在的 Watchtower 容器"
        echo "是否删除现有 Watchtower 容器并重新设置？(y/n)"
        read -r choice
        if [[ "$choice" != "y" ]]; then
            echo "❌ 已取消操作"
            return
        fi
        echo "🛑 停止并删除现有 Watchtower 容器..."
        docker rm -f "$WATCHTOWER_CONTAINER"
    fi

    echo ""
    echo "📋 当前正在运行的容器："
    docker ps --format "table {{.Names}}\t{{.Image}}"
    echo ""
    echo "💡 请输入要自动更新的容器名称（多个容器用空格分隔，输入'all'表示所有容器）"
    read -r -p "容器名称: " CONTAINERS
    # 验证容器名
    if [[ "$CONTAINERS" != "all" ]]; then
        VALID_CONTAINERS=""
        for c in $CONTAINERS; do
            if docker ps --format '{{.Names}}' | grep -qx "$c"; then
                VALID_CONTAINERS="$VALID_CONTAINERS $c"
            else
                echo "⚠️ 跳过无效容器名: $c"
            fi
        done
        if [ -z "$VALID_CONTAINERS" ] && [ -n "$CONTAINERS" ]; then
            echo "❌ 没有有效的容器名，请检查输入"
            return
        fi
        CONTAINERS="$VALID_CONTAINERS"
    fi

    echo ""
    echo "🔧 检测 Docker API 版本信息..."

    # 获取 Docker API 版本信息
    DOCKER_VERSION_INFO=$(docker version --format '{{.Server.APIVersion}} {{.Server.MinAPIVersion}}' 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$DOCKER_VERSION_INFO" ]; then
        echo "⚠️ 无法检测 Docker API 版本信息，使用默认版本"
        CURRENT_API="1.44"
        MIN_API="1.44"
        MAX_API="1.44"
    else
        CURRENT_API=$(echo "$DOCKER_VERSION_INFO" | awk '{print $1}')
        MIN_API=$(echo "$DOCKER_VERSION_INFO" | awk '{print $2}')
        # 最大 API 版本就是当前 API 版本
        MAX_API="$CURRENT_API"
    fi

    echo "📊 Docker API 版本信息："
    echo "   当前版本: $CURRENT_API"
    echo "   最小支持: $MIN_API"
    echo "   最大支持: $MAX_API"

    # 智能选择 API 版本
    DEFAULT_TARGET="1.44"
    if [ "$(echo "$MIN_API > 1.44" | bc -l 2>/dev/null)" = "1" ] || [ "$MIN_API" = "1.44" ] && [ "$(echo "$MIN_API >= 1.44" | bc -l 2>/dev/null)" = "1" ]; then
        # 如果最小 API >= 1.44，使用最小 API
        TARGET_API="$MIN_API"
        echo "✅ 系统最小 API ($MIN_API) >= 1.44，使用最小 API 版本"
    else
        if [ "$(echo "$MAX_API < 1.44" | bc -l 2>/dev/null)" = "1" ]; then
            # 如果最大 API < 1.44，使用最大 API
            TARGET_API="$MAX_API"
            echo "⚠️ 系统最大 API ($MAX_API) < 1.44，使用最大 API 版本以确保兼容性"
        else
            # 默认使用 1.44
            TARGET_API="1.44"
            echo "ℹ️ 使用默认 API 版本 1.44"
        fi
    fi

    echo "🎯 推荐使用的 Docker API 版本: $TARGET_API"
    echo ""
    echo "是否使用推荐的 API 版本？(y/n)"
    read -r USE_RECOMMENDED_API

    DOCKER_API_VERSION="$TARGET_API"
    if [[ "$USE_RECOMMENDED_API" != "y" ]]; then
        echo "请输入自定义 Docker API 版本 (当前支持范围: $MIN_API - $MAX_API)"
        read -r -p "Docker API 版本: " CUSTOM_API

        # 验证自定义版本是否在支持范围内
        if [ -n "$CUSTOM_API" ]; then
            if [ "$(echo "$CUSTOM_API < $MIN_API" | bc -l 2>/dev/null)" = "1" ] || [ "$(echo "$CUSTOM_API > $MAX_API" | bc -l 2>/dev/null)" = "1" ]; then
                echo "⚠️ 自定义版本不在支持范围内，使用推荐版本 $TARGET_API"
                DOCKER_API_VERSION="$TARGET_API"
            else
                DOCKER_API_VERSION="$CUSTOM_API"
            fi
        else
            echo "⚠️ 输入为空，使用推荐版本 $TARGET_API"
            DOCKER_API_VERSION="$TARGET_API"
        fi
    fi

    echo ""
    echo "⏰ 请选择更新检查频率："
    echo "1. 每小时检查一次"
    echo "2. 每天检查一次（凌晨2点）"
    echo "3. 每周检查一次（周日凌晨2点）"
    echo "4. 自定义 cron 表达式"
    read -r -p "请选择 (1-4): " FREQ_CHOICE

    SCHEDULE=""
    INTERVAL=""

    case $FREQ_CHOICE in
        1) INTERVAL=3600 ;;  # 每小时
        2) SCHEDULE="0 0 2 * * *" ;;  # 每天凌晨2点（6字段）
        3) SCHEDULE="0 0 2 * * 0" ;;  # 每周日凌晨2点（6字段）
        4)
            echo "📝 请输入自定义 cron 表达式（格式: '秒 分 时 日 月 周'，例如 '0 0 2 * * *'）"
            read -r -p "cron 表达式: " SCHEDULE
            # 验证 cron 表达式（简单检查是否包含6个字段）
            if [[ ! "$SCHEDULE" =~ ^[0-9*]+[[:space:]][0-9*]+[[:space:]][0-9*]+[[:space:]][0-9*]+[[:space:]][0-9*]+[[:space:]][0-9*]+$ ]]; then
                echo "❌ 无效的 cron 表达式，请使用6字段格式（如 '0 0 2 * * *'）"
                return
            fi
            ;;
        *)
            echo "❌ 无效选择，使用默认值: 每天凌晨2点"
            SCHEDULE="0 0 2 * * *"
            ;;
    esac

    echo ""
    echo "🧹 更新后是否清理旧镜像？(y/n)"
    read -r CLEANUP_CHOICE
    CLEANUP_FLAG=""
    if [[ "$CLEANUP_CHOICE" == "y" ]]; then
        CLEANUP_FLAG="--cleanup"
    fi

    echo ""
    echo "📋 即将创建的 Watchtower 配置："
    echo "📦 监控容器: ${CONTAINERS:-all}"
    echo "🔧 Docker API 版本: $DOCKER_API_VERSION (范围: $MIN_API - $MAX_API)"
    if [[ -n "$INTERVAL" ]]; then
        echo "⏰ 检查频率: 每 $((INTERVAL / 3600)) 小时"
    else
        echo "⏰ 检查频率: $SCHEDULE"
    fi
    echo "🧹 清理旧镜像: $( [ -n "$CLEANUP_FLAG" ] && echo "是" || echo "否" )"
    echo ""
    echo "是否确认创建？(y/n)"
    read -r CONFIRM
    if [[ "$CONFIRM" != "y" ]]; then
        echo "❌ 已取消操作"
        return
    fi

    # 构建 Watchtower 启动命令
    WATCHTOWER_CMD="docker run -d \
        --name watchtower \
        --restart unless-stopped \
        -e DOCKER_API_VERSION=$DOCKER_API_VERSION \
        -v /var/run/docker.sock:/var/run/docker.sock \
        containrrr/watchtower"

    if [[ -n "$INTERVAL" ]]; then
        WATCHTOWER_CMD="$WATCHTOWER_CMD --interval $INTERVAL"
    else
        WATCHTOWER_CMD="$WATCHTOWER_CMD --schedule \"$SCHEDULE\""
    fi

    WATCHTOWER_CMD="$WATCHTOWER_CMD $CLEANUP_FLAG"

    # 添加要监控的容器
    if [[ "$CONTAINERS" != "all" ]] && [ -n "$CONTAINERS" ]; then
        WATCHTOWER_CMD="$WATCHTOWER_CMD $CONTAINERS"
    fi

    echo "🚀 启动 Watchtower 容器..."
    echo "执行命令: $WATCHTOWER_CMD"
    eval "$WATCHTOWER_CMD"

    if [ $? -eq 0 ]; then
        echo "✅ Watchtower 自动更新服务已启动"
        echo "📊 使用以下命令查看日志："
        echo "   docker logs watchtower"
        echo "📊 查看运行状态："
        echo "   docker ps | grep watchtower"
    else
        echo "❌ Watchtower 启动失败"
    fi
}

# 删除 Watchtower
remove_watchtower() {
    echo "🔍 检查 Watchtower 容器..."
    WATCHTOWER_CONTAINER=$(docker ps -a --filter "name=watchtower" --format "{{.ID}}")
    if [ -z "$WATCHTOWER_CONTAINER" ]; then
        echo "ℹ️ 未找到 Watchtower 容器"
        return
    fi
    echo "🛑 停止并删除 Watchtower 容器..."
    docker rm -f "$WATCHTOWER_CONTAINER" && echo "✅ Watchtower 已删除" || echo "❌ 删除失败"
}

# Watchtower 管理子菜单
watchtower_menu() {
    while true; do
        echo ""
        echo "=== Watchtower 自动更新 ==="
        echo "1. 设置自动更新"
        echo "2. 删除自动更新"
        echo "3. 查看当前状态"
        echo "0. 返回主菜单"
        read -p "请选择操作: " choice
        case $choice in
            1) setup_watchtower ;;
            2) remove_watchtower ;;
            3)
                echo "🔍 Watchtower 状态："
                docker ps -a --filter "name=watchtower" --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
                if docker ps -a --filter "name=watchtower" | grep -q "watchtower"; then
                    echo "📊 使用 'docker logs watchtower' 查看详细日志"
                else
                    echo "ℹ️ Watchtower 容器未运行"
                fi
                ;;
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
        # 删除 Watchtower 容器（如果存在）
        WATCHTOWER_CONTAINER=$(docker ps -a --filter "name=watchtower" --format "{{.ID}}" 2>/dev/null)
        if [ -n "$WATCHTOWER_CONTAINER" ]; then
            echo "🛑 删除 Watchtower 容器..."
            docker rm -f $WATCHTOWER_CONTAINER 2>/dev/null
        fi

        rm -f "$SCRIPT_PATH"
        echo "✅ 已卸载 docker-easy"
        exit 0
    fi
}

# 卸载全部（Docker所有容器、镜像和脚本本身）
uninstall_all() {
    echo "⚠️ 警告：此操作将删除所有Docker容器、镜像、卷以及docker-easy脚本本身！"
    echo "⚠️ 这是一个不可逆的操作，请谨慎选择！"
    echo "是否继续？(y/n)"
    read -r confirm
    if [[ "$confirm" != "y" ]]; then
        echo "❌ 已取消卸载"
        return
    fi

    # 停止并删除所有容器（包括Watchtower）
    if docker ps -aq 2>/dev/null | grep -q .; then
        echo "🛑 停止并删除所有容器..."
        docker stop $(docker ps -aq) 2>/dev/null
        docker rm -f $(docker ps -aq) 2>/dev/null
    fi

    # 删除所有镜像
    if docker images -q 2>/dev/null | grep -q .; then
        echo "🗑️ 删除所有镜像..."
        docker rmi -f $(docker images -q) 2>/dev/null
    fi

    # 删除所有卷
    if docker volume ls -q 2>/dev/null | grep -q .; then
        echo "🗑️ 删除所有卷..."
        docker volume rm -f $(docker volume ls -q) 2>/dev/null
    fi

    # 删除所有网络（除了默认网络）
    if docker network ls -q --filter type=custom 2>/dev/null | grep -q .; then
        echo "🗑️ 删除所有自定义网络..."
        docker network rm $(docker network ls -q --filter type=custom) 2>/dev/null
    fi

    # 卸载Docker
    echo "🗑️ 卸载Docker..."
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
    echo "🗑️ 删除docker-easy脚本..."
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
            # 语法无误，自动删除备份
            sudo rm -f "$BACKUP_PATH"
            echo "✅ docker-easy 脚本已更新完成，备份已自动删除"
            # 询问是否重新加载脚本
            echo "是否立即重新加载脚本？(y/n)"
            read -r reload_choice
            if [[ "$reload_choice" == "y" ]]; then
                echo "🔄 重新加载脚本..."
                exec sudo bash "$SCRIPT_PATH"
            else
                echo "ℹ️ 下次使用请输入: sudo docker-easy"
            fi
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
        echo "6. Watchtower 自动更新"
        echo "7. 卸载选项"
        echo "8. 更新 docker-easy 脚本"
        echo "0. 退出"
        echo "================================"
        read -p "请选择操作: " choice
        case $choice in
            1) update_container ;;
            2) install_docker ;;
            3) container_operations ;;
            4) remove_image ;;
            5) docker_service ;;
            6) watchtower_menu ;;
            7) uninstall_menu ;;
            8) update_script ;;
            0)
                echo "👋 已退出 docker-easy，下次使用请输入: sudo docker-easy"
                exit 0 ;;
            *) echo "❌ 无效选择" ;;
        esac
    done
}

menu