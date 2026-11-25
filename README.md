# VPS 反代一键部署

Debian/Ubuntu、root、Linux amd64。一个业务容器同时提供直连 HTTPS 和 Cloudflare 橙云入口。Missav 与 worker7m 分别安装；若同机部署两个业务，每个业务使用自己的一对域名，共用 Caddy 的 80/443 入口。

## DNS 与安装

- 直连域名：灰云 A 记录指向 VPS；如有 AAAA，确保也是本机且可达。
- CF 域名：橙云 A 指向同机，或橙云 CNAME 指向直连域名；SSL 使用 **灵活**。浏览器到 CF 使用 HTTPS，CF 到 VPS 使用 HTTP。
- 放行 TCP 80/443，端口由 Caddy 管理。脚本不会修改 Cloudflare 配置。

```bash
bash install.sh -zl miss10.example.com -cf miss11.example.com ghcr.io/yjscms/missav-proxy:v1.0.1
bash install.sh -zl seven-direct.example.com -cf seven-cf.example.com ghcr.io/yjscms/worker7m:v1.0.0
```

直连入口由 Caddy 自动签发证书。CF 入口仅提供 HTTP，不强制跳 HTTPS，并向应用传入 HTTPS 协议信息，避免清单生成 HTTP 播放链接。两个入口复用一个业务容器，不按线路名称区分角色。

Missav 的 Web 后台核心节点继续负责列表、搜索和详情，本脚本不改变它。worker7m 安装时显式清空 `RESOLVE_API_BASE`，7m 与 Sup 均由本机解析；本版本不部署计算/带宽分离节点。

安装后标准输出为可填写后台的地址行。Missav 输出两个根地址；worker7m 先输出两条 `/su/`，再输出两条 `/7m/`，分别填写对应的 Supjav 与 7m 节点配置。

## 更新与回滚

同一对域名、同一个或新版本镜像重跑即可。`-zl` 和 `-cf` 放在镜像前，两者顺序可以交换；旧的双域名位置参数形式仍兼容。域名与新容器路由在同一配置文件中统一更新。兼容旧的 `直连域名 镜像` 两参数命令：已绑定的 CF 域名会从配置中恢复，不会在更新时丢失。

之前通过手工别名脚本添加的入口，首次请传入两个域名。脚本仅在别名标记、主域名与旧后端全部匹配时接管；不覆盖其他服务的域名。发现其他入口仍引用旧容器时保留旧容器，避免旧别名失效。

候选接口、本机直连 TLS、公开直连 HTTPS、本机 CF HTTP 路由、公开 CF HTTPS 全部通过后才移除不再被引用的旧容器。CF 请求必须带回本次部署标记，旧缓存响应不能冒充部署成功。任一验收失败恢复旧配置，保留旧业务容器；成功后也不会修改其他域名。

`/healthz` 或缺少参数的 API 响应不能证明视频可播。可以指定一部已知可用影片做两条公开入口的清单验收：

```bash
bash install.sh -zl miss10.example.com -cf miss11.example.com ghcr.io/yjscms/missav-proxy:v1.0.1 \
  --verify-path /9211af04-5ad2-4ae6-9112-139ee3926607/playlist.m3u8 --verify-body '#EXTM3U'
```

清单成功后仍需浏览器验证分片、实际画面、跨域与并发 CPU/内存；上游是否可用因影片和 VPS 出口而异。

可选参数：`--env-file`、`--service missav|worker7m|supjav`、`--port`、`--registry-user`、`--local`。修改运行环境后需重建容器，重启不足以更新。日志每容器限制为 2 × 5 MB；应用磁盘缓存策略由业务镜像负责，不等同于 Docker 日志限制。

## 本地验证

```bash
bash -n install.sh
python3 -m unittest discover -s test -v
```

测试在临时目录中模拟 Docker、curl、DNS；覆盖双入口、升级保留 CF、旧手工别名接管、失败回滚、不覆盖其他站点、worker7m 本机解析及单域名兼容。不会连接真实 Docker、CF 或生产服务器。这不代替 VPS 上的真实部署验收。

## 80T / 17C 仓库双域名反代（v1.3.0）

复用官方 `caddy:2-alpine`，新建一个仓库反代容器，不构建额外镜像。直连与橙云入口沿用同一套双域名部署/回滚流程，不影响同机 Missav、worker7m。

```bash
bash install.sh -zl stor-direct.example.com -cf stor-cf.example.com caddy:2-alpine \
  --service library --upstream https://80stor-cf.23m3u.top \
  --verify-path '/v/k1/有效签名/d1/ABC/ABC-001/index.m3u8'
```

验收路径必须换成一条当前可播放的 17C m3u8 地址的路径，可从现有播放器复制完整地址后取 `/v/` 开始的部分；不填写私有签名密钥。Web 后台「17C 本地库 → VPS 一键部署」可直接粘贴完整链接并生成命令。library 自动检查正文 `#EXTM3U`，不接受只用健康检查替代真实清单验收。

- 固定 HTTPS 回源域名；原 `/v/...` 路径、签名、查询参数、Range 与清单正文保持不变。现有相对分片地址继续使用访问入口的域名。
- 默认走 `80stor-cf.23m3u.top`，利用该入口的 CF 缓存；新 CF 域名仍设橙云、灵活 SSL。上游不能配置成本次两个入口之一。
- 不保存签名密钥，不做视频磁盘缓存；只保存每个容器的反代配置。Docker 日志保留 2 × 5 MB。
- 明确请求 identity 并关闭回源自动解压，不删除 Content-Encoding；保留源响应语义，避免旧反代的压缩错误。TLS 正常校验证书。
- 仅提供 `/healthz` 和 `/v/*`，支持跨域预检；4xx/5xx 禁止缓存，成功响应保留上游缓存策略。不清理 CF 已有缓存。
- 更新时新配置独立保存，候选及双入口验收通过后清理旧容器和不再使用的配置；失败恢复旧路由，不删除旧配置。

脚本完成只说明清单验收通过，分片、播放画面、CF 命中率及用户网络需实际验收。不会自动修改 17C 后台的播放域名前缀。

额外的本机 Caddy 集成测试（使用本机 HTTP 假上游，不连接生产）：

```bash
CADDY_BIN=/path/to/caddy python3 -m unittest discover -s test -v
```

2026-11-24 验证：13 项测试通过（含实际 Caddy 程序测试）；隔离监听端口读取既有 80T 资源，取得有效清单和 TS 分片。未向生产 VPS 部署、改 DNS 或修改 80T 数据。

## 自动 BBR（v1.4.0）

安装时尝试加载内核已有的 tcp_bbr。支持且系统允许时，设置宿主机 `net.ipv4.tcp_congestion_control=bbr`、默认队列 `fq`，保存到 `/etc/sysctl.d/99-vps-proxy-bbr.conf`。这只是默认队列设置，不声称已经替换现有物理网卡队列。不下载、更换内核，不调大内存缓冲区。

新业务容器与新 Caddy 都显式传入 `--sysctl net.ipv4.tcp_congestion_control=bbr`。安装结束检查容器实际值，避免宿主机已开启但容器仍为 cubic。内核不支持或宿主机权限不足时，明确提示并继续安装，不标称 BBR 已生效。BBR 宿主机配置独立持久保存，后续业务部署失败回滚只恢复业务路由，不撤销该宿主机配置。

已有共享 Caddy 默认不重启：若仍使用 cubic，会报告“入口 BBR 未生效”。维护窗口可在原命令末尾增加：

```text
--restart-gateway-for-bbr
```

该参数会短暂中断本机所有播放入口，仅重启受本安装器管理的 Caddy，不重启 Docker 或其他业务容器。若旧容器已显式固定 cubic/reno，停止并要求另行迁移，不擅自覆盖其启动参数。重启后仍非 BBR，恢复本次部署的旧路由并报告失败。

一键脚本支持不代表直连一定达到端口标称速率；新 VPS 仍需同一网络下实测起播、拖动和持续传输。
