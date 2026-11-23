#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

info() { printf '%s\n' "$*" >&2; }
die() { info "$*"; exit 1; }

usage() {
    cat <<'EOF'
用法: sudo bash install.sh 域名 镜像 [--service missav|worker7m|supjav]
                          [--port 端口] [--env-file 文件] [--local]
                          [--registry-user GitHub用户名]
                          [--verify-path /路径 --verify-body 预期文本]

每次安装或更新一个域名。健康检查通过后，标准输出只有后台配置行。
镜像名包含 missav、worker7m、supjav 或 supfast 时，自动识别服务。
--local 使用 VPS 上已有的镜像。默认从镜像仓库拉取。
--registry-user 在安装 Docker 后提示输入私有 GHCR 的令牌。
--verify-path 和 --verify-body 一起使用，增加真实业务请求验收。
EOF
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    usage
    exit 0
fi
(( $# >= 2 )) || { usage >&2; exit 2; }
domain=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')
image=$2
shift 2
service= port= env_file= verify_path= verify_body= registry_user= local_image=0
while (( $# )); do
    case $1 in
        --local) local_image=1; shift; continue ;;
        --service|--port|--env-file|--verify-path|--verify-body|--registry-user)
            (( $# >= 2 )) && [[ -n $2 ]] || die "$1 缺少参数"
            case $1 in
                --service) service=$2 ;;
                --port) port=$2 ;;
                --env-file) env_file=$2 ;;
                --verify-path) verify_path=$2 ;;
                --verify-body) verify_body=$2 ;;
                --registry-user) registry_user=$2 ;;
            esac
            shift 2 ;;
        *) die "未知参数 $1" ;;
    esac
done

label='[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
[[ ${#domain} -le 253 && $domain =~ ^($label\.)+$label$ && ${domain##*.} =~ [a-z] ]] ||
    die '请输入完整域名，例如 sup.example.com'
[[ $image =~ ^[a-zA-Z0-9][a-zA-Z0-9._/:@-]*$ ]] || die '镜像名无效'
if [[ -n $registry_user ]]; then
    [[ $image == ghcr.io/* && $local_image == 0 && $registry_user =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] ||
        die '--registry-user 适用于拉取 ghcr.io 的镜像，请填写 GitHub 用户名'
    [[ -t 0 ]] || die '--registry-user 需要在交互终端中运行'
fi
if [[ -z $service ]]; then
    case ${image##*/} in
        *missav*) service=missav ;;
        *worker7m*) service=worker7m ;;
        *supjav*|*supfast*) service=supjav ;;
        *) die '无法从镜像名识别服务，请通过 --service 指定 missav、worker7m 或 supjav' ;;
    esac
fi
node_path=/
case $service in
    missav)
        port=${port:-8081}
        probe_path=/missav/api/
        probe_status=400
        probe_body='"error"[[:space:]]*:[[:space:]]*"missing_key"'
        ;;
    worker7m)
        port=${port:-9000}
        probe_path=/su/api/
        probe_status=200
        probe_body='"error"[[:space:]]*:[[:space:]]*"missing_link"'
        node_path=/su/
        ;;
    supjav)
        port=${port:-8789}
        probe_path='/?status'
        probe_status=200
        probe_body='"status"[[:space:]]*:[[:space:]]*"ok"'
        ;;
    *) die '--service 必须是 missav、worker7m 或 supjav' ;;
esac
[[ $port =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )) || die '容器端口无效'
[[ -z $env_file || -r $env_file ]] || die '无法读取 --env-file'
if [[ -n $verify_path || -n $verify_body ]]; then
    [[ $verify_path == /* && $verify_path != //* && $verify_path != *[[:space:]#]* && -n $verify_body ]] ||
        die '请提供同一域名下的 --verify-path 和非空的 --verify-body'
fi
[[ $OSTYPE == linux* && $EUID == 0 ]] || die '请在 Linux VPS 上以 root 运行'

packages=()
command -v docker >/dev/null || packages+=(docker.io)
command -v curl >/dev/null || packages+=(curl ca-certificates)
command -v flock >/dev/null || packages+=(util-linux)
if [[ -r /sys/module/apparmor/parameters/enabled ]] &&
    grep -qx Y /sys/module/apparmor/parameters/enabled &&
    ! command -v apparmor_parser >/dev/null; then
    info '内核已启用 AppArmor，安装 Docker 所需的 apparmor_parser'
    packages+=(apparmor)
fi
if (( ${#packages[@]} )); then
    command -v apt-get >/dev/null || die "请先安装依赖：${packages[*]}（自动安装支持 Debian/Ubuntu）"
    apt-get update >&2
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" >&2
fi
export DOCKER_HOST=unix:///var/run/docker.sock
unset DOCKER_CONTEXT
if ! docker info >/dev/null 2>&1; then
    command -v systemctl >/dev/null && systemctl enable --now docker >&2
    docker info >/dev/null 2>&1 || die '本机 Docker 未启动'
fi

state=/opt/vps-proxy
gateway=vps-proxy-caddy
network=vps-proxy-net
owner=io.aifeishe.vps-proxy
mkdir -p "$state/sites"
exec 9>"$state/install.lock"
flock -x 9
getent ahosts "$domain" >/dev/null || die "DNS 尚未解析到域名 $domain"

if docker container inspect "$gateway" >/dev/null 2>&1; then
    [[ $(docker inspect -f "{{ index .Config.Labels \"$owner\" }}" "$gateway") == gateway ]] ||
        die "容器名 $gateway 已被占用"
fi
if [[ $(docker container inspect -f '{{.State.Running}}' "$gateway" 2>/dev/null || true) != true ]] &&
    command -v ss >/dev/null &&
    occupied_ports=$(ss -H -ltn '( sport = :80 or sport = :443 )') &&
    [[ -n $occupied_ports ]]; then
    info "$occupied_ports"
    die '80 或 443 已有监听服务。请先确认现有入口的用途，再决定如何部署 Caddy'
fi
if docker network inspect "$network" >/dev/null 2>&1; then
    [[ $(docker network inspect -f "{{ index .Labels \"$owner\" }}" "$network") == gateway ]] ||
        die "网络名 $network 已被占用"
else
    docker network create --label "$owner=gateway" "$network" >&2
fi

if (( ! local_image )); then
    if [[ -n $registry_user ]]; then
        docker login ghcr.io --username "$registry_user" >&2
    fi
    info "拉取镜像 $image"
    docker pull "$image" >&2
fi
image_id=$(docker image inspect --format '{{.Id}}' "$image") || die "找不到镜像 $image"
if [[ ! -f $state/Caddyfile ]]; then
    printf 'import /etc/caddy/sites/*.caddy\n' >"$state/Caddyfile"
fi

work=$(mktemp -d "$state/install.XXXXXXXXXXXX")
release=${work##*.}
backend=vps-proxy-$release
site=$state/sites/$domain.caddy
old_backend=
published=0
started=0
reload_gateway() {
    docker exec "$gateway" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >&2
}
cleanup() {
    local result=$?
    if (( result != 0 )); then
        if (( published )); then
            if [[ -f $work/previous ]]; then
                mv -f "$work/previous" "$site"
            else
                rm -f "$site"
            fi
            if (( started )); then
                docker rm -f "$gateway" >/dev/null 2>&1 || info '恢复入口时无法移除新建的 Caddy 容器'
            elif ! reload_gateway; then
                info '入口恢复失败，保留两个版本以便排查'
                rm -rf "$work"
                return "$result"
            fi
        fi
        docker rm -f "$backend" >/dev/null 2>&1 || true
    fi
    rm -rf "$work"
    return "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

request() {
    local url=$1 expected_status=$2 max_time=$3 status
    shift 3
    probe_error='响应内容与预期不符'
    if status=$(curl --disable --silent --noproxy '*' --globoff --connect-timeout 4 --max-time "$max_time" \
        --dump-header "$work/headers" --output "$work/body" --write-out '%{http_code}' "$@" "$url"); then
        if [[ $status != "$expected_status" ]]; then
            probe_error="收到 HTTP ${status}，预期 HTTP $expected_status"
            return 1
        fi
    else
        case $? in
            6) probe_error='无法解析域名' ;;
            7) probe_error='无法连接目标端口' ;;
            28) probe_error='请求超时' ;;
            35|51|60) probe_error='TLS 握手或证书校验失败' ;;
            *) probe_error='请求未完成' ;;
        esac
        return 1
    fi
}

if [[ -f $site ]]; then
    cp "$site" "$work/previous"
    read -r _ old_backend <"$work/previous"
fi

container_options=(--network "$network")
[[ -z $env_file ]] || container_options+=(--env-file "$env_file")
if [[ $service == missav || $service == worker7m ]]; then
    container_options+=(--env "PORT=$port")
fi
logging=(--log-driver local --log-opt max-size=5m --log-opt max-file=2)
docker run -d --name "$backend" --label "$owner=$domain" --restart unless-stopped \
    "${logging[@]}" "${container_options[@]}" "$image_id" >&2

backend_ip=$(docker container inspect -f "{{with index .NetworkSettings.Networks \"$network\"}}{{.IPAddress}}{{end}}" "$backend")
[[ $backend_ip =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die '候选容器未取得 Docker 网桥 IPv4 地址'
info "检查候选容器的接口（端口 ${port}）"
deadline=$(( SECONDS + 30 ))
until request "http://$backend_ip:$port$probe_path" "$probe_status" 4 --header "Host: $domain" &&
    grep -Eq "$probe_body" "$work/body"; do
    (( SECONDS < deadline )) || die "候选容器接口未就绪（端口 ${port}）：$probe_error"
    sleep 2
done

cat >"$work/site" <<EOF
# $backend
$domain {
    @deployment header X-VPS-Deploy $release
    header @deployment X-VPS-Deploy $release
    reverse_proxy $backend:$port {
        header_up -X-VPS-Deploy
    }
}
EOF
published=1
mv -f "$work/site" "$site"
if docker container inspect "$gateway" >/dev/null 2>&1; then
    docker start "$gateway" >/dev/null
    for attempt in {1..5}; do
        if reload_gateway; then
            break
        fi
        (( attempt < 5 )) || die 'Caddy 载入站点配置失败'
        sleep 1
    done
else
    started=1
    docker run -d --name "$gateway" --label "$owner=gateway" --restart unless-stopped \
        --network "$network" --publish 80:80 --publish 443:443 "${logging[@]}" \
        --mount "type=bind,source=$state/Caddyfile,target=/etc/caddy/Caddyfile,readonly" \
        --mount "type=bind,source=$state/sites,target=/etc/caddy/sites,readonly" \
        --mount type=volume,source=vps-proxy-caddy-data,target=/data \
        --mount type=volume,source=vps-proxy-caddy-config,target=/config \
        caddy:2-alpine >&2
fi

probe_https() {
    local path=$1 expected_status=$2 max_time=$3
    shift 3
    request "https://$domain$path" "$expected_status" "$max_time" \
        --header "X-VPS-Deploy: $release" --header 'Cache-Control: no-cache' "$@" || return 1
    if ! grep -Eixq "x-vps-deploy:[[:space:]]*$release[[:space:]]*" "$work/headers"; then
        probe_error='响应未经过本次部署的 Caddy 站点'
        return 1
    fi
}

check_https_route() {
    probe_https "$probe_path" "$probe_status" 15 "$@" && grep -Eq "$probe_body" "$work/body"
}

info "等待 $domain 的 HTTPS 验收"
deadline=$(( SECONDS + 180 ))
while :; do
    if ! check_https_route --resolve "$domain:443:127.0.0.1"; then
        phase='VPS 本机 Caddy 入口'
    elif ! check_https_route; then
        phase='VPS 按 DNS 访问域名'
    else
        break
    fi
    (( SECONDS < deadline )) || die "HTTPS 验收超时（${phase}，${domain}）：${probe_error}。请检查 DNS、80/443 和证书"
    sleep 3
done
if [[ -n $verify_path ]]; then
    probe_https "$verify_path" 200 60 && grep -Fq -- "$verify_body" "$work/body" ||
        die "真实业务请求验收失败：$probe_error"
fi

info 'VPS 侧 HTTPS 验收通过。其他网络的可达性请从后台服务器或实际客户端确认'
# 通过验收后才清理本站点的旧容器。
if [[ $old_backend =~ ^vps-proxy-[a-zA-Z0-9]+$ &&
      $(docker inspect -f "{{ index .Config.Labels \"$owner\" }}" "$old_backend" 2>/dev/null) == "$domain" ]]; then
    docker rm -f "$old_backend" >/dev/null || info "旧容器 $old_backend 清理失败"
fi
printf 'VPS|https://%s%s|stable\n' "$domain" "$node_path"
