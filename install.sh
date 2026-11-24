#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

info() { printf '%s\n' "$*" >&2; }
die() { info "$*"; exit 1; }

usage() {
    cat <<'EOF'
用法: sudo bash install.sh -zl 直连域名 -cf CF域名 镜像 [--service missav|worker7m|supjav|library]
兼容: sudo bash install.sh 直连域名 CF域名 镜像
兼容: sudo bash install.sh 直连域名 镜像（升级时保留已有 CF 入口）
                          [--upstream https://仓库域名] [--port 端口] [--env-file 文件] [--local]
                          [--registry-user GitHub用户名]
                          [--verify-path /路径 --verify-body 预期文本]

两个域名共享一个业务容器；CF 域名使用橙云 + 灵活 SSL，HTTP 回源。
两个入口全部验收通过才清理旧容器；失败则恢复旧路由。
worker7m 默认本机解析，不填写远程计算核心。标准输出只有后台配置行。
镜像名包含 missav、worker7m、supjav 或 supfast 时，自动识别服务。
--local 使用 VPS 上已有的镜像。默认从镜像仓库拉取。
--registry-user 在安装 Docker 后提示输入私有 GHCR 的令牌。
--verify-path 和 --verify-body 一起使用，增加真实业务请求验收。
library 使用 caddy:2-alpine；必须提供 /v/.../index.m3u8 验收路径，默认回源 80stor-cf.23m3u.top。
EOF
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    usage
    exit 0
fi
# 显式双域名参数；保留原位置参数形式，避免影响已有升级命令。
if [[ ${1:-} == -zl || ${1:-} == -cf ]]; then
    direct_arg= cf_arg=
    while [[ ${1:-} == -zl || ${1:-} == -cf ]]; do
        (( $# >= 2 )) && [[ -n $2 && $2 != -* ]] || die "$1 缺少域名"
        case $1 in
            -zl) [[ -z $direct_arg ]] || die '-zl 不能重复'; direct_arg=$2 ;;
            -cf) [[ -z $cf_arg ]] || die '-cf 不能重复'; cf_arg=$2 ;;
        esac
        shift 2
    done
    [[ -n $direct_arg && -n $cf_arg && $# -ge 1 && $1 != -* ]] ||
        die '请提供 -zl 直连域名 -cf CF域名 镜像'
    set -- "$direct_arg" "$cf_arg" "$@"
fi
(( $# >= 2 )) || { usage >&2; exit 2; }
domain=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')
cf_domain=
if (( $# >= 3 )) && [[ $3 != --* ]]; then
    cf_domain=$(printf '%s' "$2" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    image=$3
    shift 3
else
    image=$2
    shift 2
fi
service= port= env_file= verify_path= verify_body= registry_user= upstream= local_image=0
while (( $# )); do
    case $1 in
        --local) local_image=1; shift; continue ;;
        --service|--port|--env-file|--verify-path|--verify-body|--registry-user|--upstream)
            (( $# >= 2 )) && [[ -n $2 ]] || die "$1 缺少参数"
            case $1 in
                --upstream) upstream=$2 ;;
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
if [[ -n $cf_domain ]]; then
    [[ ${#cf_domain} -le 253 && $cf_domain =~ ^($label\.)+$label$ && ${cf_domain##*.} =~ [a-z] && $cf_domain != "$domain" ]] ||
        die 'CF 域名必须是与直连域名不同的完整域名'
fi
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
    library)
        port=${port:-8080}
        probe_path=/healthz
        probe_status=200
        probe_body='"service":"library"'
        upstream=${upstream:-https://80stor-cf.23m3u.top}
        upstream=${upstream%/}
        [[ $image == caddy:2-alpine ]] || die 'library 模式使用 caddy:2-alpine 官方镜像'
        [[ $upstream =~ ^https://($label\.)+$label$ && ${upstream##*.} =~ [a-z] ]] || die '--upstream 必须为 HTTPS 域名，不含路径、端口或参数'
        upstream_host=${upstream#https://}
        [[ $upstream_host != "$domain" && $upstream_host != "$cf_domain" ]] || die '仓库回源域名不能与新入口相同，以免循环回源'
        [[ $verify_path == /v/*.m3u8* ]] || die 'library 模式请提供 --verify-path /v/.../index.m3u8 进行真实清单验收'
        [[ -n $verify_body ]] || verify_body='#EXTM3U'
        ;;
    supjav)
        port=${port:-8789}
        probe_path='/?status'
        probe_status=200
        probe_body='"status"[[:space:]]*:[[:space:]]*"ok"'
        ;;
    *) die '--service 必须是 missav、worker7m、supjav 或 library' ;;
esac
[[ $service == library || -z $upstream ]] || die '--upstream 仅适用于 library 仓库反代'
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
site=$state/sites/$domain.caddy
if [[ -z $cf_domain && -f $site ]]; then
    cf_domain=$(awk '$1=="#" && $2=="cf-domain" {print $3}' "$site")
fi
if [[ -n $cf_domain ]]; then
    [[ ${#cf_domain} -le 253 && $cf_domain =~ ^($label\.)+$label$ && ${cf_domain##*.} =~ [a-z] && $cf_domain != "$domain" ]] || die '已保存 CF 域名无效'
fi
if [[ $service == library && $upstream_host == "$cf_domain" ]]; then
    die '仓库回源域名不能与已有 CF 入口相同，以免循环回源'
fi
for hostname in "$domain" ${cf_domain:+"$cf_domain"}; do
    getent ahosts "$hostname" >/dev/null || die "DNS 尚未解析到域名 $hostname"
done
# 一个入口只能归属一个业务容器，不能覆盖其他站点的绑定。
legacy_alias=
for existing in "$state"/sites/*.caddy; do
    [[ -f $existing && $existing != "$site" ]] || continue
    for hostname in "$domain" ${cf_domain:+"$cf_domain"}; do
        if awk -v host="$hostname" '$2=="{" && ($1==host || $1=="http://"host || $1=="https://"host) {found=1} END {exit !found}' "$existing"; then
            # 接管先前手工添加的 CF 别名；只接受同一主站、同一旧后端。
            if [[ $hostname == "$cf_domain" && $existing == "$state/sites/$cf_domain.caddy" && -f $site ]] &&
               grep -Fxq "# CF alias of $domain" "$existing" &&
               [[ $(awk '$1=="reverse_proxy" {print $2}' "$existing") == "$(awk '$1=="reverse_proxy" {print $2}' "$site")" ]]; then
                legacy_alias=$existing
            else
                die "域名 $hostname 已由其他站点管理，停止以免覆盖"
            fi
        fi
    done
done

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
old_backend=
backend_config=$state/backends/$backend.caddy
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
            if [[ -f $work/legacy-alias ]]; then
                mv -f "$work/legacy-alias" "$legacy_alias"
            fi
            if (( started )); then
                docker rm -f "$gateway" >/dev/null 2>&1 || info '恢复入口时无法移除新建的 Caddy 容器'
            elif ! reload_gateway; then
                info '入口恢复失败，保留两个版本以便排查'
                rm -rf "$work"
                return "$result"
            fi
        fi
        if docker rm -f "$backend" >/dev/null 2>&1; then rm -f "$backend_config"; fi
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
if [[ $service == worker7m ]]; then
    # 此安装入口统一部署独立解析节点，覆盖镜像和 env-file 中的旧远程地址。
    container_options+=(--env 'RESOLVE_API_BASE=')
fi
if [[ $service == missav || $service == worker7m ]]; then
    container_options+=(--env "PORT=$port")
fi
if [[ $service == library ]]; then
    mkdir -p "$state/backends"
    cat >"$backend_config" <<EOF
{
    admin off
    auto_https off
}
:$port {
    header {
        Access-Control-Allow-Origin "*"
        Access-Control-Allow-Methods "GET, HEAD, OPTIONS"
        Access-Control-Allow-Headers "Range, Origin, Accept, Content-Type"
        Access-Control-Expose-Headers "Content-Length, Content-Range, Accept-Ranges"
    }
    route {
        @preflight method OPTIONS
        respond @preflight 204
        handle /healthz {
            header Cache-Control "no-store"
            respond \`{"ok":true,"service":"library"}\` 200
        }
        handle /v/* {
            reverse_proxy $upstream {
                header_up Host $upstream_host
                header_up User-Agent "Mozilla/5.0"
                header_up Accept-Encoding "identity;q=1, *;q=0"
                header_down -Access-Control-Allow-Origin
                header_down -Access-Control-Allow-Methods
                header_down -Access-Control-Allow-Headers
                header_down -Access-Control-Expose-Headers
                transport http {
                    compression off
                    dial_timeout 10s
                    response_header_timeout 60s
                }
                @failure status 3xx 4xx 5xx
                handle_response @failure {
                    header Cache-Control "no-store"
                    copy_response_headers {
                        exclude Cache-Control Expires Access-Control-Allow-Origin Access-Control-Allow-Methods Access-Control-Allow-Headers Access-Control-Expose-Headers
                    }
                    copy_response
                }
            }
        }
        handle {
            header Cache-Control "no-store"
            respond "Not found" 404
        }
    }
    handle_errors {
        header Cache-Control "no-store"
        respond "Upstream unavailable" {err.status_code}
    }
}
EOF
    container_options+=(--mount "type=bind,source=$backend_config,target=/etc/caddy/Caddyfile,readonly")
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
if [[ -n $cf_domain ]]; then
    printf '# cf-domain %s\n' "$cf_domain" >>"$work/site"
    cat >>"$work/site" <<EOF
http://$cf_domain {
    @deployment header X-VPS-Deploy $release
    header @deployment X-VPS-Deploy $release
    reverse_proxy $backend:$port {
        header_up -X-VPS-Deploy
        header_up X-Forwarded-Proto https
    }
}
EOF
fi
published=1
if [[ -n $legacy_alias ]]; then
    mv "$legacy_alias" "$work/legacy-alias"
fi
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

if [[ -n $cf_domain ]]; then
    probe_cf() {
        local path=$1 expected=$2 timeout=$3
        shift 3
        request "$1$path" "$expected" "$timeout" --header "X-VPS-Deploy: $release" --header 'Cache-Control: no-cache' "${@:2}" || return 1
        grep -Eixq "x-vps-deploy:[[:space:]]*$release[[:space:]]*" "$work/headers" || { probe_error='CF 请求未到达本次部署入口'; return 1; }
    }
    info "等待 $cf_domain 的 HTTP 回源和橙云 HTTPS 验收（需灵活 SSL）"
    deadline=$(( SECONDS + 180 ))
    until probe_cf "$probe_path" "$probe_status" 15 http://127.0.0.1 --header "Host: $cf_domain" &&
          grep -Eq "$probe_body" "$work/body" &&
          probe_cf "$probe_path" "$probe_status" 15 "https://$cf_domain" &&
          grep -Eq "$probe_body" "$work/body"; do
        (( SECONDS < deadline )) || die "CF 入口验收失败：${probe_error}；检查橙云、灵活 SSL 和 80 端口"
        sleep 3
    done
    if [[ -n $verify_path ]]; then
        probe_cf "$verify_path" 200 60 "https://$cf_domain" && grep -Fq -- "$verify_body" "$work/body" ||
            die "CF 真实业务请求验收失败：$probe_error"
    fi
fi
info 'VPS 侧双入口验收完成。浏览器播放和不同用户网络仍需实测'
# 通过验收后才清理本站点的旧容器。
if [[ $old_backend =~ ^vps-proxy-[a-zA-Z0-9]+$ &&
      $(docker inspect -f "{{ index .Config.Labels \"$owner\" }}" "$old_backend" 2>/dev/null) == "$domain" ]]; then
    if grep -Fq "reverse_proxy $old_backend:" "$state"/sites/*.caddy; then
        info '旧容器仍被其他入口引用，保留；请用双域名命令接管旧 CF 别名'
    else
        if docker rm -f "$old_backend" >/dev/null; then
            rm -f "$state/backends/$old_backend.caddy"
        else info "旧容器 $old_backend 清理失败"; fi
    fi
fi
printf 'VPS|https://%s%s|stable\n' "$domain" "$node_path"

if [[ -n $cf_domain ]]; then
    printf 'VPS|https://%s%s|stable\n' "$cf_domain" "$node_path"
fi
if [[ $service == worker7m ]]; then
    printf 'VPS|https://%s/7m/|stable\n' "$domain"
    [[ -z $cf_domain ]] || printf 'VPS|https://%s/7m/|stable\n' "$cf_domain"
fi
