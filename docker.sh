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

# 检查是否以 root 运行
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "⚠️ 部分功能需要 root 权限，建议使用 sudo 运行"
    fi
}

# 配置 Docker IPv6 支持
configure_ipv6() {
    echo ""
    echo "=== [8] 配置 Docker IPv6 支持 ==="
    
    # 检查 Docker 是否安装
    if ! command -v docker &>/dev/null; then
        echo "❌ 未检测到 docker，请先安装 Docker"
        return
    fi
    
    # 检查当前 IPv6 状态
    local current_ipv6_status=$(docker info --format '{{json .}}' 2>/dev/null | jq -r '.IPv6Routing' 2>/dev/null)
    if [ "$current_ipv6_status" == "true" ]; then
        echo "✅ 当前 Docker IPv6 已启用"
    else
        echo "ℹ️ 当前 Docker IPv6 未启用"
    fi
    
    echo ""
    echo "请选择操作:"
    echo "[1] 启用 IPv6 支持"
    echo "[2] 禁用 IPv6 支持"
    echo "[3] 查看当前 IPv6 配置"
    echo "[0] 返回主菜单"
    read -p "请选择 [0-3]: " ipv6_choice
    
    case $ipv6_choice in
        1)
            enable_ipv6
            ;;
        2)
            disable_ipv6
            ;;
        3)
            view_ipv6_config
            ;;
        0)
            return
            ;;
        *)
            echo "❌ 无效选择"
            ;;
    esac
}

# 启用 IPv6
enable_ipv6() {
    echo ""
    echo "🔧 配置 Docker IPv6 支持..."
    
    # 获取用户输入的 IPv6 子网
    echo "请输入 IPv6 子网 (默认: 2001:db8:1::/64)"
    read -p "IPv6 子网: " ipv6_subnet
    if [ -z "$ipv6_subnet" ]; then
        ipv6_subnet="2001:db8:1::/64"
    fi
    
    # 验证 IPv6 子网格式（简单验证）
    if ! echo "$ipv6_subnet" | grep -q "^[0-9a-fA-F:]*/[0-9]\{1,3\}$"; then
        echo "⚠️ IPv6 子网格式可能不正确，继续使用: $ipv6_subnet"
    fi
    
    # 创建或修改 daemon.json
    local daemon_file="/etc/docker/daemon.json"
    local temp_file=$(mktemp)
    
    # 如果文件存在，读取现有配置
    if [ -f "$daemon_file" ]; then
        jq --arg subnet "$ipv6_subnet" '. + {"ipv6": true, "fixed-cidr-v6": $subnet}' "$daemon_file" > "$temp_file"
    else
        # 创建新配置
        echo "{\"ipv6\": true, \"fixed-cidr-v6\": \"$ipv6_subnet\"}" | jq '.' > "$temp_file"
    fi
    
    # 检查 jq 操作是否成功
    if [ $? -eq 0 ] && [ -s "$temp_file" ]; then
        sudo mv "$temp_file" "$daemon_file"
        echo "✅ IPv6 配置已写入: $daemon_file"
        echo "📄 当前配置:"
        cat "$daemon_file" | jq '.'
        
        # 重启 Docker 服务
        echo ""
        echo "🔄 重启 Docker 服务以应用配置..."
        sudo systemctl restart docker 2>/dev/null || sudo service docker restart
        
        if [ $? -eq 0 ]; then
            echo "✅ Docker 服务已重启，IPv6 已启用"
            
            # 验证 IPv6 是否启用
            sleep 2
            local new_status=$(docker info --format '{{json .}}' 2>/dev/null | jq -r '.IPv6Routing' 2>/dev/null)
            if [ "$new_status" == "true" ]; then
                echo "✅ IPv6 已成功启用"
            else
                echo "⚠️ IPv6 可能未正确启用，请检查配置"
            fi
        else
            echo "❌ Docker 服务重启失败"
        fi
    else
        echo "❌ 配置写入失败"
        rm -f "$temp_file"
    fi
}

# 禁用 IPv6
disable_ipv6() {
    echo ""
    echo "🔧 禁用 Docker IPv6 支持..."
    
    local daemon_file="/etc/docker/daemon.json"
    
    if [ ! -f "$daemon_file" ]; then
        echo "ℹ️ Docker 配置文件不存在，无需操作"
        return
    fi
    
    local temp_file=$(mktemp)
    
    # 移除 IPv6 相关配置
    jq 'del(.ipv6) | del(.["fixed-cidr-v6"])' "$daemon_file" > "$temp_file"
    
    # 如果结果为空对象，删除文件
    if [ "$(cat "$temp_file")" == "{}" ]; then
        sudo rm "$daemon_file"
        echo "✅ 已删除 Docker 配置文件"
    else
        sudo mv "$temp_file" "$daemon_file"
        echo "✅ IPv6 配置已从 $daemon_file 移除"
        echo "📄 当前配置:"
        cat "$daemon_file" | jq '.'
    fi
    
    # 重启 Docker 服务
    echo ""
    echo "🔄 重启 Docker 服务以应用配置..."
    sudo systemctl restart docker 2>/dev/null || sudo service docker restart
    
    if [ $? -eq 0 ]; then
        echo "✅ Docker 服务已重启，IPv6 已禁用"
    else
        echo "❌ Docker 服务重启失败"
    fi
}

# 查看 IPv6 配置
view_ipv6_config() {
    echo ""
    echo "=== Docker IPv6 配置状态 ==="
    
    # 查看 Docker 配置
    local daemon_file="/etc/docker/daemon.json"
    if [ -f "$daemon_file" ]; then
        echo "📄 Docker 配置文件 ($daemon_file):"
        cat "$daemon_file" | jq '.'
    else
        echo "ℹ️ Docker 配置文件不存在"
    fi
    
    echo ""
    echo "📊 Docker IPv6 运行时状态:"
    docker info --format 'table {{.IPv6Routing}}\t{{.ExperimentalBuild}}' 2>/dev/null | sed 's/true/✅ 启用/g' | sed 's/false/❌ 禁用/g'
    
    echo ""
    echo "🌐 当前网络配置:"
    docker network ls --format "table {{.Name}}\t{{.Driver}}\t{{.IPv6}}" | sed 's/enabled/✅ 启用/g' | sed 's/disabled/❌ 禁用/g'
}

# 配置 Docker 镜像加速器
configure_mirror() {
    echo ""
    echo "=== [9] 配置 Docker 全局镜像加速 ==="
    
    # 检查 Docker 是否安装
    if ! command -v docker &>/dev/null; then
        echo "❌ 未检测到 docker，请先安装 Docker"
        return
    fi
    
    # 显示当前配置
    local daemon_file="/etc/docker/daemon.json"
    if [ -f "$daemon_file" ]; then
        local current_mirrors=$(jq -r '.["registry-mirrors"] // [] | join("\n    ")' "$daemon_file" 2>/dev/null)
        if [ -n "$current_mirrors" ] && [ "$current_mirrors" != "" ]; then
            echo "📋 当前镜像加速器配置:"
            echo "    $current_mirrors"
        else
            echo "ℹ️ 当前未配置镜像加速器"
        fi
    else
        echo "ℹ️ Docker 配置文件不存在"
    fi
    
    echo ""
    echo "请选择操作:"
    echo "[1] 添加镜像加速器"
    echo "[2] 删除镜像加速器"
    echo "[3] 清空所有镜像加速器"
    echo "[4] 查看当前配置"
    echo "[0] 返回主菜单"
    read -p "请选择 [0-4]: " mirror_choice
    
    case $mirror_choice in
        1)
            add_mirror
            ;;
        2)
            remove_mirror
            ;;
        3)
            clear_mirrors
            ;;
        4)
            view_mirror_config
            ;;
        0)
            return
            ;;
        *)
            echo "❌ 无效选择"
            ;;
    esac
}

# 添加镜像加速器
add_mirror() {
    echo ""
    echo "📝 请输入镜像加速器地址"
    echo ""
    echo "💡 提示：您可以访问以下网站查询可用的镜像加速器："
    echo "   🔗 https://status.anye.xyz/  - 容器镜像可用性查询"
    echo ""
    echo "支持输入多个加速器地址，每输入一个按回车确认"
    
    local mirrors=()
    while true; do
        echo ""
        read -p "请输入加速器地址 (直接回车结束添加): " mirror_url
        if [ -z "$mirror_url" ]; then
            if [ ${#mirrors[@]} -eq 0 ]; then
                echo "❌ 未添加任何镜像加速器"
                return
            fi
            break
        fi
        
        # 验证 URL 格式
        if ! echo "$mirror_url" | grep -q "^https\?://"; then
            echo "⚠️ URL 格式可能不正确，应该以 http:// 或 https:// 开头"
            echo "是否仍然添加？(y/n)"
            read -r force_add
            if [[ "$force_add" != "y" ]]; then
                echo "❌ 已跳过: $mirror_url"
                continue
            fi
        fi
        
        mirrors+=("$mirror_url")
        echo "✅ 已添加: $mirror_url"
        
        echo ""
        echo "是否继续添加下一个？(y/n)"
        read -r continue_add
        if [[ "$continue_add" != "y" ]]; then
            break
        fi
    done
    
    if [ ${#mirrors[@]} -eq 0 ]; then
        echo "❌ 未添加任何镜像加速器"
        return
    fi
    
    echo ""
    echo "即将添加以下镜像加速器:"
    for mirror in "${mirrors[@]}"; do
        echo "  - $mirror"
    done
    
    read -p "确认添加？(y/n): " confirm
    if [[ "$confirm" != "y" ]]; then
        echo "❌ 已取消"
        return
    fi
    
    # 更新 daemon.json
    local daemon_file="/etc/docker/daemon.json"
    local temp_file=$(mktemp)
    
    # 创建临时文件，包含所有镜像
    local mirrors_json=""
    for mirror in "${mirrors[@]}"; do
        if [ -n "$mirrors_json" ]; then
            mirrors_json="$mirrors_json, \"$mirror\""
        else
            mirrors_json="\"$mirror\""
        fi
    done
    mirrors_json="[$mirrors_json]"
    
    # 如果文件存在，合并现有配置
    if [ -f "$daemon_file" ]; then
        # 获取现有镜像列表并合并
        local existing_mirrors=$(jq -c '.["registry-mirrors"] // []' "$daemon_file")
        local new_mirrors=$(jq -c --argjson existing "$existing_mirrors" --argjson new "$mirrors_json" '$existing + $new | unique' <<< "{}")
        jq --argjson mirrors "$new_mirrors" '. + {"registry-mirrors": $mirrors}' "$daemon_file" > "$temp_file"
    else
        # 创建新配置
        jq -n --argjson mirrors "$mirrors_json" '{"registry-mirrors": $mirrors}' > "$temp_file"
    fi
    
    # 应用配置
    if [ $? -eq 0 ] && [ -s "$temp_file" ]; then
        sudo mv "$temp_file" "$daemon_file"
        echo "✅ 镜像加速器配置已更新"
        
        # 显示最终配置
        echo "📄 当前镜像加速器列表:"
        jq -r '.["registry-mirrors"] // [] | .[]' "$daemon_file" | sed 's/^/  - /'
        
        # 询问是否重启 Docker
        echo ""
        read -p "是否重启 Docker 服务以应用配置？(y/n): " restart_choice
        if [[ "$restart_choice" == "y" ]]; then
            echo "🔄 重启 Docker 服务..."
            sudo systemctl restart docker 2>/dev/null || sudo service docker restart
            if [ $? -eq 0 ]; then
                echo "✅ Docker 服务已重启"
            else
                echo "❌ Docker 服务重启失败"
            fi
        else
            echo "ℹ️ 配置将在下次 Docker 服务重启后生效"
        fi
    else
        echo "❌ 配置写入失败"
        rm -f "$temp_file"
    fi
}

# 删除镜像加速器
remove_mirror() {
    local daemon_file="/etc/docker/daemon.json"
    
    if [ ! -f "$daemon_file" ]; then
        echo "❌ Docker 配置文件不存在"
        return
    fi
    
    # 显示当前镜像列表
    local mirrors=$(jq -r '.["registry-mirrors"] // [] | to_entries | .[] | "\(.key): \(.value)"' "$daemon_file" 2>/dev/null)
    if [ -z "$mirrors" ]; then
        echo "ℹ️ 当前没有配置镜像加速器"
        return
    fi
    
    echo "📋 当前镜像加速器列表:"
    echo "$mirrors" | sed 's/^/  /'
    
    echo ""
    echo "请输入要删除的镜像序号（可输入多个，用空格分隔）"
    echo "或输入 'all' 删除所有"
    read -p "选择: " remove_choice
    
    local temp_file=$(mktemp)
    
    if [ "$remove_choice" == "all" ]; then
        # 删除所有镜像
        jq 'del(.["registry-mirrors"])' "$daemon_file" > "$temp_file"
        echo "✅ 将删除所有镜像加速器"
    else
        # 获取要删除的索引
        local indices=($remove_choice)
        local delete_indices=$(printf '%s\n' "${indices[@]}" | jq -R . | jq -s 'map(tonumber)')
        
        # 删除指定索引的镜像
        jq --argjson indices "$delete_indices" '.["registry-mirrors"] |= (if . then . as $arr | [($indices | map(tonumber)) as $idx | $arr | to_entries | map(select(.key as $k | $idx | index($k) | not)) | map(.value)] else [] end)' "$daemon_file" > "$temp_file"
    fi
    
    # 应用配置
    if [ $? -eq 0 ]; then
        # 如果镜像列表为空，删除该字段
        jq 'if .["registry-mirrors"] == [] then del(.["registry-mirrors"]) else . end' "$temp_file" > "${temp_file}.tmp"
        mv "${temp_file}.tmp" "$temp_file"
        
        # 如果结果为空对象，删除文件
        if [ "$(cat "$temp_file")" == "{}" ]; then
            sudo rm "$daemon_file"
            echo "✅ 已删除 Docker 配置文件"
        else
            sudo mv "$temp_file" "$daemon_file"
            echo "✅ 镜像加速器已删除"
            
            # 显示更新后的配置
            local remaining_mirrors=$(jq -r '.["registry-mirrors"] // [] | .[]' "$daemon_file" 2>/dev/null)
            if [ -n "$remaining_mirrors" ]; then
                echo "📄 剩余镜像加速器:"
                echo "$remaining_mirrors" | sed 's/^/  - /'
            fi
        fi
        
        # 询问是否重启 Docker
        echo ""
        read -p "是否重启 Docker 服务以应用配置？(y/n): " restart_choice
        if [[ "$restart_choice" == "y" ]]; then
            echo "🔄 重启 Docker 服务..."
            sudo systemctl restart docker 2>/dev/null || sudo service docker restart
            if [ $? -eq 0 ]; then
                echo "✅ Docker 服务已重启"
            else
                echo "❌ Docker 服务重启失败"
            fi
        fi
    else
        echo "❌ 删除失败"
        rm -f "$temp_file"
    fi
}

# 清空所有镜像加速器
clear_mirrors() {
    local daemon_file="/etc/docker/daemon.json"
    
    if [ ! -f "$daemon_file" ]; then
        echo "ℹ️ Docker 配置文件不存在"
        return
    fi
    
    read -p "确定要清空所有镜像加速器吗？(y/n): " confirm
    if [[ "$confirm" != "y" ]]; then
        echo "❌ 已取消"
        return
    fi
    
    local temp_file=$(mktemp)
    
    # 删除 registry-mirrors 字段
    jq 'del(.["registry-mirrors"])' "$daemon_file" > "$temp_file"
    
    # 如果结果为空对象，删除文件
    if [ "$(cat "$temp_file")" == "{}" ]; then
        sudo rm "$daemon_file"
        echo "✅ 已删除 Docker 配置文件"
    else
        sudo mv "$temp_file" "$daemon_file"
        echo "✅ 所有镜像加速器已清空"
    fi
    
    # 询问是否重启 Docker
    echo ""
    read -p "是否重启 Docker 服务以应用配置？(y/n): " restart_choice
    if [[ "$restart_choice" == "y" ]]; then
        echo "🔄 重启 Docker 服务..."
        sudo systemctl restart docker 2>/dev/null || sudo service docker restart
        if [ $? -eq 0 ]; then
            echo "✅ Docker 服务已重启"
        else
            echo "❌ Docker 服务重启失败"
        fi
    fi
}

# 查看镜像加速器配置
view_mirror_config() {
    echo ""
    echo "=== Docker 镜像加速器配置 ==="
    
    local daemon_file="/etc/docker/daemon.json"
    if [ -f "$daemon_file" ]; then
        echo "📄 Docker 配置文件 ($daemon_file):"
        cat "$daemon_file" | jq '.'
        
        echo ""
        echo "📋 当前镜像加速器列表:"
        jq -r '.["registry-mirrors"] // [] | .[]' "$daemon_file" 2>/dev/null | sed 's/^/  - /'
        if [ $? -ne 0 ] || [ -z "$(jq -r '.["registry-mirrors"] // [] | .[]' "$daemon_file" 2>/dev/null)" ]; then
            echo "  未配置镜像加速器"
        fi
    else
        echo "ℹ️ Docker 配置文件不存在"
    fi
    
    echo ""
    echo "📊 Docker 运行时信息:"
    docker info 2>/dev/null | grep -E "Registry Mirrors|Insecure Registries" || echo "  无法获取运行时信息"
}

# 安装或更新 Docker
install_docker() {
    echo ""
    echo "=== [2] 安装/更新 Docker ==="
    echo "⚡ 将通过 Docker 官方脚本安装/更新 Docker"
    echo "是否继续？(y/n)"
    read -r choice
    if [[ "$choice" == "y" ]]; then
        curl -fsSL https://get.docker.com | sh
        echo "✅ Docker 已安装/更新完成"
        docker --version
        
        # 安装后询问是否配置镜像加速器
        echo ""
        read -p "是否立即配置镜像加速器？(y/n): " config_mirror
        if [[ "$config_mirror" == "y" ]]; then
            configure_mirror
        fi
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
    echo ""
    echo "=== [1] 更新容器 ==="
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

    # 询问是否指定版本
    echo "是否指定版本？(y/n，默认拉取最新版本)"
    read -r specify_version
    if [[ "$specify_version" == "y" ]]; then
        read -p "请输入版本号 (例如: 1.2.3, alpine, 直接回车使用latest): " VERSION
        if [ -z "$VERSION" ]; then
            VERSION="latest"
            echo "ℹ️ 未输入版本号，使用默认版本: latest"
        fi
        BASE_IMAGE=$(echo "$IMAGE" | cut -d: -f1)
        IMAGE_TO_PULL="${BASE_IMAGE}:${VERSION}"
        echo "ℹ️ 将拉取指定版本: $IMAGE_TO_PULL"
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
        echo "ℹ️ 将拉取最新版本: $IMAGE_TO_PULL"
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
    echo ""
    echo "=== 停止容器 ==="
    docker ps --format "table {{.ID}}\t{{.Names}}"
    read -p "请输入要停止的容器ID（可多个，空格分隔）: " CIDs
    [ -z "$CIDs" ] && echo "⚠️ 未输入容器ID" && return 1
    docker stop $CIDs && echo "✅ 容器已停止"
}

# 强制停止容器（支持批量）
force_stop_container() {
    echo ""
    echo "=== 强制停止容器 ==="
    docker ps --format "table {{.ID}}\t{{.Names}}"
    read -p "请输入要强制停止的容器ID（可多个，空格分隔）: " CIDs
    [ -z "$CIDs" ] && echo "⚠️ 未输入容器ID" && return 1
    docker kill $CIDs && echo "✅ 容器已强制停止"
}

# 启动容器（支持批量）
start_container() {
    echo ""
    echo "=== 启动容器 ==="
    docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
    read -p "请输入要启动的容器ID（可多个，空格分隔）: " CIDs
    [ -z "$CIDs" ] && echo "⚠️ 未输入容器ID" && return 1
    docker start $CIDs && echo "✅ 容器已启动"
}

# 重启容器（支持批量）
restart_container() {
    echo ""
    echo "=== 重启容器 ==="
    docker ps --format "table {{.ID}}\t{{.Names}}"
    read -p "请输入要重启的容器ID（可多个，空格分隔）: " CIDs
    [ -z "$CIDs" ] && echo "⚠️ 未输入容器ID" && return 1
    docker restart $CIDs && echo "✅ 容器已重启"
}

# 删除容器（支持批量）
remove_container() {
    echo ""
    echo "=== 删除容器 ==="
    docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
    read -p "请输入要删除的容器ID（可多个，空格分隔）: " CIDs
    [ -z "$CIDs" ] && echo "⚠️ 未输入容器ID" && return 1
    docker rm -f $CIDs && echo "✅ 容器已删除"
}

# 进入容器
enter_container() {
    echo ""
    echo "=== 进入容器 ==="
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
    echo ""
    echo "=== 查看容器日志 ==="
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
    echo ""
    echo "=== 删除镜像 ==="
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
    echo "[1] 启动 Docker"
    echo "[2] 停止 Docker"
    echo "[3] 重启 Docker"
    echo "[0] 返回"
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
        echo "[1] 启动容器"
        echo "[2] 停止容器"
        echo "[3] 强制停止容器"
        echo "[4] 重启容器"
        echo "[5] 删除容器"
        echo "[6] 进入容器"
        echo "[7] 查看容器日志"
        echo "[0] 返回主菜单"
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

    DOCKER_VERSION_INFO=$(docker version --format '{{.Server.APIVersion}} {{.Server.MinAPIVersion}}' 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$DOCKER_VERSION_INFO" ]; then
        echo "⚠️ 无法检测 Docker API 版本信息，使用默认版本"
        CURRENT_API="1.44"
        MIN_API="1.44"
        MAX_API="1.44"
    else
        CURRENT_API=$(echo "$DOCKER_VERSION_INFO" | awk '{print $1}')
        MIN_API=$(echo "$DOCKER_VERSION_INFO" | awk '{print $2}')
        MAX_API="$CURRENT_API"
    fi

    echo "📊 Docker API 版本信息："
    echo "   当前版本: $CURRENT_API"
    echo "   最小支持: $MIN_API"
    echo "   最大支持: $MAX_API"

    DEFAULT_TARGET="1.44"
    if [ "$(echo "$MIN_API > 1.44" | bc -l 2>/dev/null)" = "1" ] || [ "$MIN_API" = "1.44" ] && [ "$(echo "$MIN_API >= 1.44" | bc -l 2>/dev/null)" = "1" ]; then
        TARGET_API="$MIN_API"
        echo "✅ 系统最小 API ($MIN_API) >= 1.44，使用最小 API 版本"
    else
        if [ "$(echo "$MAX_API < 1.44" | bc -l 2>/dev/null)" = "1" ]; then
            TARGET_API="$MAX_API"
            echo "⚠️ 系统最大 API ($MAX_API) < 1.44，使用最大 API 版本以确保兼容性"
        else
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
        1) INTERVAL=3600 ;;
        2) SCHEDULE="0 0 2 * * *" ;;
        3) SCHEDULE="0 0 2 * * 0" ;;
        4)
            echo "📝 请输入自定义 cron 表达式（格式: '秒 分 时 日 月 周'，例如 '0 0 2 * * *'）"
            read -r -p "cron 表达式: " SCHEDULE
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
        echo "[1] 设置自动更新"
        echo "[2] 删除自动更新"
        echo "[3] 查看当前状态"
        echo "[0] 返回主菜单"
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

    if docker ps -aq 2>/dev/null | grep -q .; then
        echo "🛑 停止并删除所有容器..."
        docker stop $(docker ps -aq) 2>/dev/null
        docker rm -f $(docker ps -aq) 2>/dev/null
    fi

    if docker images -q 2>/dev/null | grep -q .; then
        echo "🗑️ 删除所有镜像..."
        docker rmi -f $(docker images -q) 2>/dev/null
    fi

    if docker volume ls -q 2>/dev/null | grep -q .; then
        echo "🗑️ 删除所有卷..."
        docker volume rm -f $(docker volume ls -q) 2>/dev/null
    fi

    if docker network ls -q --filter type=custom 2>/dev/null | grep -q .; then
        echo "🗑️ 删除所有自定义网络..."
        docker network rm $(docker network ls -q --filter type=custom) 2>/dev/null
    fi

    echo "🗑️ 卸载Docker..."
    if command -v apt &>/dev/null; then
        sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        sudo apt-get autoremove -y
    elif command -v yum &>/dev/null; then
        sudo yum remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

    echo "🧹 清理Docker相关文件..."
    sudo rm -rf /var/lib/docker
    sudo rm -rf /var/lib/containerd
    sudo rm -rf /etc/docker

    echo "🗑️ 删除docker-easy脚本..."
    sudo rm -f "$SCRIPT_PATH"

    echo "✅ 所有Docker组件和脚本已完全卸载！"
    exit 0
}

# 更新脚本
update_script() {
    echo "⬇️ 正在更新 docker-easy 脚本..."

    BACKUP_PATH="${SCRIPT_PATH}.bak"
    sudo cp "$SCRIPT_PATH" "$BACKUP_PATH"
    echo "📦 已创建备份: $BACKUP_PATH"

    SCRIPT_URL="https://raw.githubusercontent.com/Lanlan13-14/Docker-Easy/refs/heads/main/docker.sh"
    tmpfile=$(mktemp)
    if curl -fsSL "$SCRIPT_URL" -o "$tmpfile"; then
        if bash -n "$tmpfile" 2>/dev/null; then
            chmod +x "$tmpfile"
            sudo mv "$tmpfile" "$SCRIPT_PATH"
            sudo rm -f "$BACKUP_PATH"
            echo "✅ docker-easy 脚本已更新完成，备份已自动删除"
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
        echo "[1] 仅卸载脚本"
        echo "[2] 卸载全部（Docker所有容器、镜像和脚本）"
        echo "[0] 返回主菜单"
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
    check_root
    while true; do
        echo ""
        echo "====== Docker Easy 工具 ======"
        echo "[1] 更新容器"
        echo "[2] 安装/更新 Docker"
        echo "[3] 容器操作"
        echo "[4] 删除镜像"
        echo "[5] Docker 服务管理"
        echo "[6] Watchtower 自动更新"
        echo "[7] 卸载选项"
        echo "[8] 配置 Docker IPv6 支持"
        echo "[9] 配置 Docker 全局镜像加速"
        echo "[10] 更新 docker-easy 脚本"
        echo "[0] 退出"
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
            8) configure_ipv6 ;;
            9) configure_mirror ;;
            10) update_script ;;
            0)
                echo "👋 已退出 docker-easy，下次使用请输入: sudo docker-easy"
                exit 0 ;;
            *) echo "❌ 无效选择" ;;
        esac
    done
}

menu