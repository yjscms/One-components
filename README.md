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
