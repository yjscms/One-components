## 2026-11-24 / 双域名独立反代部署
- 目标：单业务容器复用直连自动 HTTPS、CF 灵活 SSL 的 HTTP 回源入口。
- 工作：独立 detached 工作区实现，不变更 Project 未发布内容或线上节点。
- 文件：install.sh、README.md、test/test_install.py。
- 测试：bash -n；8 项隔离 Python 编排测试通过，无真实 Docker/DNS/CF 操作。
- 发布：v1.2.0；保留 v1.1.0 单域名使用方式，已绑定 CF 的升级自动恢复绑定。
- 待验收：新 VPS 的真实安装、双线路视频分片/画面、CPU/内存与上游出口可用性。
- 范围：不改 MissavProvider 核心；worker7m 强制本机解析；不改业务镜像或应用缓存。
