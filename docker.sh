#!/usr/bin/env bash
# docker-easy: Docker 容器管理工具

SCRIPT_PATH="/usr/local/bin/docker-easy"

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

build_docker_run_cmd() {
    local CID="$1"
    local CONFIG=$(docker inspect "$CID")

    local CNAME=$(echo "$CONFIG" | jq -r '.[0].Name' | sed 's#^/##')
    local IMAGE=$(echo "$CONFIG" | jq -r '.[0].Config.Image')

    local CMD="docker run -d --name \"$CNAME\""

    # 网络
    local NETWORK=$(echo "$CONFIG" | jq -r '.[0].HostConfig.NetworkMode')
    if [[ "$NETWORK" != "default" && "$NETWORK" != "bridge" ]]; then
        CMD="$CMD --network \"$NETWORK\""
    fi

    # 重启策略
    local RESTART_POLICY=$(echo "$CONFIG" | jq -r '.[0].HostConfig.RestartPolicy.Name')
    if [[ "$RESTART_POLICY" != "no" ]]; then
        CMD="$CMD --restart \"$RESTART_POLICY\""
    fi

    # 用户
    local USER=$(echo "$CONFIG" | jq -r '.[0].Config.User')
    [[ -n "$USER" && "$USER" != "null" ]] && CMD="$CMD --user \"$USER\""

    # 工作目录
    local WORKDIR=$(echo "$CONFIG" | jq -r '.[0].Config.WorkingDir')
    [[ -n "$WORKDIR" && "$WORKDIR" != "null" ]] && CMD="$CMD -w \"$WORKDIR\""

    # CapAdd
    local CAPS=$(echo "$CONFIG" | jq -r '.[0].HostConfig.CapAdd[]?' 2>/dev/null)
    while read -r cap; do [[ -n "$cap" ]] && CMD="$CMD --cap-add $cap"; done <<< "$CAPS"

    # Devices
    local DEVS=$(echo "$CONFIG" | jq -r '.[0].HostConfig.Devices[]? | "--device \(.PathOnHost):\(.PathInContainer)"' 2>/dev/null)
    [[ -n "$DEVS" ]] && CMD="$CMD $DEVS"

    # Extra Hosts
    local HOSTS=$(echo "$CONFIG" | jq -r '.[0].HostConfig.ExtraHosts[]?' 2>/dev/null)
    while read -r host; do [[ -n "$host" ]] && CMD="$CMD --add-host $host"; done <<< "$HOSTS"

    # Log Options
    local LOG_OPTS=$(echo "$CONFIG" | jq -r '.[0].HostConfig.LogConfig.Config | to_entries[]? | "--log-opt \(.key)=\(.value)"' 2>/dev/null)
    [[ -n "$LOG_OPTS" ]] && CMD="$CMD $LOG_OPTS"

    # ShmSize
    local SHM_SIZE=$(echo "$CONFIG" | jq -r '.[0].HostConfig.ShmSize')
    [[ "$SHM_SIZE" != "null" && "$SHM_SIZE" -gt 0 ]] && CMD="$CMD --shm-size ${SHM_SIZE}b"

    # Ulimits
    local ULIMITS=$(echo "$CONFIG" | jq -r '.[0].HostConfig.Ulimits[]? | "--ulimit \(.Name)=\(.Soft):\(.Hard)"' 2>/dev/null)
    [[ -n "$ULIMITS" ]] && CMD="$CMD $ULIMITS"

    # Volumes
    local VOLS=$(echo "$CONFIG" | jq -r '.[0].Mounts[]? | "-v \(.Source):\(.Destination)"' 2>/dev/null)
    [[ -n "$VOLS" ]] && CMD="$CMD $VOLS"

    # 端口映射
    local PORTS=$(echo "$CONFIG" | jq -r '.[0].HostConfig.PortBindings | to_entries[]? | "-p \(.value[0].HostPort):\(.key | split("/")[0])"' 2>/dev/null)
    [[ -n "$PORTS" ]] && CMD="$CMD $PORTS"

    # 环境变量
    local ENVS=$(echo "$CONFIG" | jq -r '.[0].Config.Env[]?' 2>/dev/null | sed 's/^/-e /' | tr '\n' ' ')
    [[ -n "$ENVS" ]] && CMD="$CMD $ENVS"

    # 镜像
    CMD="$CMD \"$IMAGE\""

    # Entrypoint & Cmd
    local EP=$(echo "$CONFIG" | jq -r '.[0].Config.Entrypoint | join(" ")')
    [[ -n "$EP" && "$EP" != "null" ]] && CMD="$CMD $EP"
    local CMDS=$(echo "$CONFIG" | jq -r '.[0].Config.Cmd | join(" ")')
    [[ -n "$CMDS" && "$CMDS" != "null" ]] && CMD="$CMD $CMDS"

    echo "$CMD"
}

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

    CNAME=$(docker inspect --format='{{.Name}}' "$CID" | sed 's/^\/\(.*\)/\1/')
    IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CID")

    echo "✅ 选中容器: $CNAME (镜像: $IMAGE)"
    echo "⬇️ 正在拉取最新镜像..."
    docker pull "$IMAGE"

    echo "🛑 停止并删除旧容器..."
    docker stop "$CID" 2>/dev/null
    docker rm "$CID" 2>/dev/null

    echo "🚀 使用新镜像启动容器..."
    DOCKER_CMD=$(build_docker_run_cmd "$CID")
    eval "$DOCKER_CMD"

    if [ $? -eq 0 ]; then
        echo "✅ 容器 $CNAME 已更新完成！"
    else
        echo "❌ 容器启动失败，请检查命令:"
        echo "$DOCKER_CMD"
    fi
}

# 停止容器
stop_container() {
    docker ps --format "table {{.ID}}\t{{.Names}}"
    read -p "请输入要停止的容器ID: " CID
    docker stop "$CID" && echo "✅ 容器已停止"
}

# 启动容器
start_container() {
    docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
    read -p "请输入要启动的容器ID: " CID
    docker start "$CID" && echo "✅ 容器已启动"
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

# 更新脚本
update_script() {
    echo "⬇️ 正在更新 docker-easy 脚本..."
    SCRIPT_URL="https://raw.githubusercontent.com/Lanlan13-14/Docker-Easy/refs/heads/main/docker.sh"
    tmpfile=$(mktemp)
    if curl -fsSL "$SCRIPT_URL" -o "$tmpfile"; then
        chmod +x "$tmpfile"
        sudo mv "$tmpfile" "$SCRIPT_PATH"
        echo "✅ docker-easy 脚本已更新完成！"
        echo "下次使用请输入: sudo docker-easy"
    else
        echo "❌ 更新失败，请检查网络或链接是否有效"
        rm -f "$tmpfile"
    fi
}

# 主菜单
menu() {
    check_jq
    while true; do
        echo ""
        echo "====== Docker Easy 工具 ======"
        echo "1. 更新容器"
        echo "2. 安装/更新 Docker"
        echo "3. 停止容器"
        echo "4. 启动容器"
        echo "5. 删除容器"
        echo "6. 删除镜像"
        echo "7. Docker 服务管理"
        echo "8. 卸载脚本"
        echo "9. 更新 docker-easy 脚本"
        echo "0. 退出"
        echo "================================"
        read -p "请选择操作: " choice
        case $choice in
            1) update_container ;;
            2) install_docker ;;
            3) stop_container ;;
            4) start_container ;;
            5) remove_container ;;
            6) remove_image ;;
            7) docker_service ;;
            8) uninstall_script ;;
            9) update_script ;;
            0) 
                echo "👋 已退出 docker-easy，下次使用请输入: sudo docker-easy"
                exit 0 ;;
            *) echo "❌ 无效选择" ;;
        esac
    done
}

menu