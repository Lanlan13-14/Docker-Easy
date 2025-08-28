#!/usr/bin/env bash

# docker-easy: Docker 容器管理工具

SCRIPT_PATH="/usr/local/bin/docker-easy"
WATCHTOWER_CONTAINER="watchtower"

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
    if echo "$pull_output" | grep -q "Image is up to date\|Status: Image is up to date"; then
        return 0
    else
        return 1
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
    OLD_IMAGE_ID=$(docker inspect --format='{{.Image}}' "$CID")

    echo "✅ 选中容器: $CNAME (镜像: $IMAGE)"

    echo "是否指定版本？(y/n，默认拉取最新版本)"
    read -r specify_version
    if [[ "$specify_version" == "y" ]]; then
        read -p "请输入版本号 (例如: 1.2.3, alpine, 直接回车使用latest): " VERSION
        if [ -z "$VERSION" ]; then
            VERSION="latest"
            echo "ℹ️  未输入版本号，使用默认版本: latest"
        fi
        BASE_IMAGE=$(echo "$IMAGE" | cut -d: -f1)
        IMAGE_TO_PULL="${BASE_IMAGE}:${VERSION}"
        echo "ℹ️  将拉取指定版本: $IMAGE_TO_PULL"
        IS_SPECIFIC_VERSION=1
        if [[ "$VERSION" == "latest" ]]; then
            IS_SPECIFIC_VERSION=0
        fi
    else
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

    NEW_CMD=$(echo "$ORIG_CMD" | sed "s|$IMAGE|$IMAGE_TO_PULL|")

    echo "🛑 停止并删除旧容器..."
    docker rm -f "$CID"

    echo "🚀 启动新容器..."
    eval "$NEW_CMD"

    if [ $? -eq 0 ]; then
        echo "✅ 容器 $CNAME 已更新到版本: $IMAGE_TO_PULL"
        echo "🧹 清理旧镜像..."
        NEW_IMAGE_ID=$(docker inspect --format='{{.Image}}' $(docker ps -q --filter "name=$CNAME") 2>/dev/null)
        if [ -n "$NEW_IMAGE_ID" ] && [ "$OLD_IMAGE_ID" != "$NEW_IMAGE_ID" ]; then
            if [ -z "$(docker ps -a -q --filter ancestor="$OLD_IMAGE_ID" | grep -v "$CID")" ]; then
                docker rmi "$OLD_IMAGE_ID" 2>/dev/null && echo "✅ 旧镜像已删除" || echo "⚠️ 无法删除旧镜像"
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

# Watchtower 自动更新管理
watchtower_menu() {
    while true; do
        echo ""
        echo "=== Watchtower 自动更新管理 ==="
        echo "1. 安装并配置 Watchtower"
        echo "2. 查看 Watchtower 状态"
        echo "3. 删除 Watchtower"
        echo "0. 返回主菜单"
        read -p "请选择操作: " choice
        case $choice in
            1)
                echo "请输入检查周期（支持 h、m、s 单位，例如：6h、30m、45s）"
                read -p "检查周期: " interval_input
                if [[ "$interval_input" =~ ^[0-9]+h$ ]]; then
                    num=${interval_input%h}
                    interval=$((num * 3600))
                elif [[ "$interval_input" =~ ^[0-9]+m$ ]]; then
                    num=${interval_input%m}
                    interval=$((num * 60))
                elif [[ "$interval_input" =~ ^[0-9]+s$ ]]; then
                    num=${interval_input%s}
                    interval=$num
                elif [[ "$interval_input" =~ ^[0-9]+$ ]]; then
                    interval=$interval_input
                else
                    echo "❌ 输入不合法，请重新输入"
                    continue
                fi

                echo "📋 当前容器列表："
                docker ps --format "table {{.Names}}"
                echo "请输入要自动更新的容器名称（空格分隔，留空表示全部）："
                read -r containers

                docker rm -f $WATCHTOWER_CONTAINER >/dev/null 2>&1
                docker run -d \
                    --name $WATCHTOWER_CONTAINER \
                    --restart always \
                    -v /var/run/docker.sock:/var/run/docker.sock \
                    containrrr/watchtower \
                    --cleanup \
                    --interval "$interval" \
                    $containers
                echo "✅ Watchtower 已启动，每 $interval 秒检查一次更新"
                ;;
            2)
                docker ps --filter "name=$WATCHTOWER_CONTAINER"
                ;;
            3)
                docker rm -f $WATCHTOWER_CONTAINER && echo "✅ Watchtower 已删除"
                ;;
            0)
                return ;;
            *)
                echo "❌ 无效选择"
                ;;
        esac
    done
}

# 停止容器
stop_container() { docker ps --format "table {{.ID}}\t{{.Names}}"; read -p "请输入要停止的容器ID: " CID; docker stop "$CID" && echo "✅ 容器已停止"; }
force_stop_container() { docker ps --format "table {{.ID}}\t{{.Names}}"; read -p "请输入要强制停止的容器ID: " CID; docker kill "$CID" && echo "✅ 容器已强制停止"; }
start_container() { docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"; read -p "请输入要启动的容器ID: " CID; docker start "$CID" && echo "✅ 容器已启动"; }
restart_container() { docker ps --format "table {{.ID}}\t{{.Names}}"; read -p "请输入要重启的容器ID: " CID; docker restart "$CID" && echo "✅ 容器已重启"; }
remove_container() { docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"; read -p "请输入要删除的容器ID: " CID; docker rm -f "$CID" && echo "✅ 容器已删除"; }
remove_image() { docker images --format "table {{.ID}}\t{{.Repository}}\t{{.Tag}}"; read -p "请输入要删除的镜像ID: " IID; docker rmi -f "$IID" && echo "✅ 镜像已删除"; }

docker_service() {
    echo ""; echo "=== Docker 服务管理 ==="
    echo "1. 启动 Docker"; echo "2. 停止 Docker"; echo "3. 重启 Docker"; echo "0. 返回"
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

container_operations() {
    while true; do
        echo ""; echo "=== 容器操作 ==="
        echo "1. 启动容器"; echo "2. 停止容器"; echo "3. 强制停止容器"
        echo "4. 重启容器"; echo "5. 删除容器"; echo "0. 返回主菜单"
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

uninstall_script() { echo "是否卸载 docker-easy 脚本？(y/n)"; read -r confirm; [[ "$confirm" == "y" ]] && rm -f "$SCRIPT_PATH" && echo "✅ 已卸载 docker-easy" && exit 0; }
# uninstall_all 和 update_script 逻辑同你原来一致，省略...

# 主菜单
menu() {
    check_jq
    while true; do
        echo ""; echo "====== Docker Easy 工具 ======"
        echo "1. 更新容器"; echo "2. 安装/更新 Docker"
        echo "3. 容器操作"; echo "4. 删除镜像"
        echo "5. Docker 服务管理"; echo "6. 卸载选项"
        echo "7. 更新 docker-easy 脚本"; echo "8. Watchtower 自动更新管理"
        echo "0. 退出"; echo "================================"
        read -p "请选择操作: " choice
        case $choice in
            1) update_container ;;
            2) install_docker ;;
            3) container_operations ;;
            4) remove_image ;;
            5) docker_service ;;
            6) uninstall_menu ;;
            7) update_script ;;
            8) watchtower_menu ;;
            0) echo "👋 已退出 docker-easy，下次使用请输入: sudo docker-easy"; exit 0 ;;
            *) echo "❌ 无效选择" ;;
        esac
    done
}

menu