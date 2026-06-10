# 构建 AnduinOS 的全球边缘分发网络：Cloudflare 负载均衡与节点容灾实战

为了让全球用户在更新 AnduinOS 时都能享受到拉满的下载速度，近期我着手规划了一个分布在全球的 Nginx/Caddy 二进制包分发集群。

起初，作为重度容器依赖患者，我构思了一套宏大的 Ansible + Docker Swarm 全局部署方案。但在面对横跨欧洲（德国）、亚洲（新加坡）和美洲（美国）的超长物理延迟时，我意识到强一致性的 Swarm 集群在跨洲际的 WAN 网络下就是一场灾难。

最终，架构回归极简。我采用了一种“Shared-nothing（无共享）”的边缘自治架构，结合 Cloudflare 的全局流量调度（Geo-Steering），打造了一个低成本、极度健壮且完美的全球镜像网络。

以下是整个架构的设计思路、配置流程以及那些让人”汗流浃背”的踩坑记录。

---

## 零、服务器采购：Vultr 三节点全球部署

对于面向终端用户的二进制包分发，节点的地理位置远比 CPU 核数重要。经过对比 Linode、DO、Hetzner 和 Vultr，最终选择了 Vultr——它在西雅图、法兰克福、新加坡三个机房都有 $5/月的最低配实例，且全部标配公网 IPv4 + IPv6。

### 采购清单

| 节点 | 机房 | 规格 | IP | 月费 |
|------|------|------|-----|------|
| apkg-de | 法兰克福 | 1C-1G-25G | `2001:db8:de::1` / `66.77.88.99` | $5 |
| apkg-sg | 新加坡 | 1C-1G-25G | `2001:db8:sg::1` / `66.77.88.100` | $5 |
| apkg-us | 西雅图 | 1C-1G-25G | `2001:db8:us::1` / `66.77.88.101` | $5 |

**总计: $15/月**，覆盖欧亚美三大洲。

> **选型心得**: Vultr 的 IPv6 免费，这是关键加分项。Cloudflare 的 Flexible 模式回源走 IPv4，但节点之间通过 IPv6 SSH 管理完全不消耗 IPv4 的稀缺配额。1 核 1G 足够跑 Caddy + Rclone 两个 Go 写的轻量进程——生产环境内存占用合计不到 100MB。

### 操作系统选型

全部部署 **Ubuntu 26.04 LTS (Resolute)**。这是截至 2026 年 6 月的最新 Ubuntu 长期支持版，内核 7.0.0，自带了 BBR 拥塞控制算法和最新的 Docker 仓库支持。对于 1G 内存的小机器，选择 Ubuntu 而非 Alpine/Debian 的理由很务实——Docker 官方 `get.docker.com` 一键脚本对 Ubuntu 的支持最成熟，不需要手动调内核参数和 Cgroup 配置。

### 采购后第一件事

三台 VPS 开机后，先确认了三件事再开始部署：

1. **IPv6 可达性**: 从本机 `ssh -6` 直连 IPv6 地址，确认不经过跳板机。
2. **公网带宽**: 用 `curl -s https://cloudflare.com/cdn-cgi/trace` 测一下延迟和丢包——Vultr 三个机房的 CF 回源延迟均在 1ms 以内（同城边缘节点）。
3. **安全基线**: 确认 `root` 登录已禁用，`anduin` 用户在 `sudoers` 中。

---

## 一、设计思辨：在三条岔路口的选择

买好服务器之后，摆在面前的问题是：**用什么方式把三台分布在三大洲的机器管起来？**

### 1.1 为什么是 Docker Compose 而不是 Nginx 裸机？

裸机 Nginx + Certbot + cron + rclone 的方案理论上是性能最优解。但考虑到三台机器运行的是 Vultr 的最小化 Ubuntu 镜像，每次重装或扩容都要手动 `apt install nginx certbot rclone`，再逐一同步配置文件。三台还能忍受，但如果未来扩展到 10 个节点，配置漂移（Configuration Drift）就是噩梦。

而 Docker Compose 把每个节点的运行态收敛到一个目录下：`docker-compose.yml` + `Caddyfile` + `sync-logic.sh`。新机器上线只需要 Docker 和这三个文件，环境绝对干净。

### 1.2 为什么不是 Docker Swarm？

最初的直觉是把三台机器加入 Swarm 集群，用 Global Service 一键部署。但很快意识到自杀性缺陷：Swarm 的 Raft 共识协议需要 Manager 节点之间频繁心跳。法兰克福↔新加坡的延迟在 150ms 以上，这种 WAN 环境下 Raft 会频繁选举超时，Ingress 网络的跨洲流量也会被延迟拖死。

"Shared-nothing"（无共享）才是正确答案：节点之间完全不需要通信。每台机器独立从 WebDAV 主站拉数据，独立提供 HTTP 服务，坏了也不影响其他节点。Cloudflare 在更上层做流量调度。

### 1.3 为什么纯 HTTP，不用 HTTPS？

这是整个设计中最关键的决策，也是最终让脚本实现 100% 可开源的关键。

#### 问题：多节点共用同一域名时，Let's Encrypt 根本拿不到证书

三台机器都想用 `packages.anduinos.com` 对外服务。如果让每台机器的 Caddy 自己向 Let's Encrypt 申请证书：

1. 德国节点发起证书申请，LE 发送 HTTP-01 验证请求到 `packages.anduinos.com/.well-known/...`
2. 这个请求打到 Cloudflare，CF 负载均衡随机转发给了新加坡节点
3. 新加坡节点根本没发起过申请，目录下没有验证 token，返回 404
4. 德国节点证书申请失败

五台机器互相抢验证请求，谁也拿不到证书。这是多节点共用一个域名时的经典死锁。

#### 三条岔路

**方案 A: Cloudflare Origin Certificate。** 在 CF 后台下载一对 15 年有效期的内部证书，下发到每台机器。CF↔节点之间 Full (Strict) 加密。**问题**: 私钥文件 `key.pem` 不能进 Git 仓库。要么用 Ansible Vault 加密（引入 Secret 管理），要么手动 SCP（引入人工步骤）。对于一个追求"clone 下来就能跑"的脚本，这是致命伤。团队后人加新节点时，必须先从 CF 后台下载证书，再想办法塞进服务器——这违背了"一把梭"的初衷。

**方案 B: 每个节点用独立域名。** 德国节点用 `packages-de.anduinos.com`，新加坡用 `packages-sg.anduinos.com`。每个 Caddy 各自向 Let's Encrypt 申请证书——因为域名唯一，验证请求精准命中，不会互相抢。然后在 Cloudflare 用 Worker 根据 GeoIP 做 302 重定向。**问题**: 这需要改 APT 源地址、改 Worker 脚本、维护多套 DNS 记录。复杂度直接翻倍。

**方案 C: 纯 HTTP。** 节点上的 Caddy 只监听 80 端口。所有 TLS 加密卸载到 Cloudflare 边缘层。用户↔CF 之间是 HTTPS（CF 自动签发边缘证书），CF↔节点之间是 HTTP 明文。Cloudflare SSL 模式设为 **Flexible**。

#### 为什么方案 C 是安全的

决定性的论据：**APT 仓库的安全机制根本不依赖传输层加密。**

APT 的完整信任链：

```
GPG 签名验证 InRelease
  └─ InRelease 内含 Release 的 SHA256 哈希
       └─ Release 内含 Packages 的 SHA256 哈希
            └─ Packages 内含每个 .deb 的 SHA256 + MD5 哈希
```

即使攻击者在 CF↔节点之间的 HTTP 链路上做了中间人攻击，篡改了 `.deb` 文件：

1. `apt update` 下载 `InRelease` → GPG 签名验证通过（文件未被篡改）
2. 下载 `Packages` → 与 `InRelease` 中的哈希对比 → 不匹配 → **拒绝**
3. 即使哈希也被替换了，`InRelease` 的 GPG 签名会检验失败 → **拒绝**

整套哈希链由 GPG 签名锚定。TLS 对于 APT 是"锦上添花"，不是"安全必需"。这个结论来自 Debian/Ubuntu 官方文档——APT 在设计之初就假设传输层不可信。

#### 我们做出的牺牲

选择方案 C 不是没有代价的：

| 牺牲 | 影响 | 为什么可以接受 |
|------|------|---------------|
| CF↔节点之间明文传输 | 运营商/IDC 内网可嗅探下载内容 | APT 仓库是公开的，没有敏感数据。下载哪个包、什么版本，本身就不是秘密 |
| 无法防篡改（传输层） | 中间人可替换 HTTP 响应 | GPG 哈希链阻止了任何篡改——篡改过的数据要么被 GPG 拒绝，要么哈希不匹配 |
| Cloudflare Flexible 模式 | CF 到节点不走 HTTPS | Flexible 是 CF 的设计功能之一，不是"不安全"模式——它只是把 TLS 终结位置从源站移到了 CF 边缘 |

#### 回报：100% 可开源的部署脚本

删除 TLS 层后，`deploy-edge.sh` 变成了：

- **零 Secret**: 没有私钥、没有 API token、没有环境变量
- **零证书**: 不依赖 Let's Encrypt，不依赖 CF Origin CA
- **零手动步骤**: 任何人在任何 Ubuntu 26.04 上跑一遍，节点就上线

团队后人在东京加新节点时，不需要找我要证书，不需要登录 CF 后台，不需要配 Ansible Vault。买好 VPS → SCP 脚本 → `sudo bash deploy-edge.sh` → 完成。

### 1.4 为什么放弃 Ansible，改用 Bash 一把梭？

在概念设计阶段，Ansible 是默认选项。但当真正开始实施时，只有三台机器——写 Ansible Playbook + Inventory + 调试的耗时，远超直接把脚本 SCP 上去跑三遍。与其过早引入 IaC 工具的复杂度，不如先把 Bash 脚本打磨到幂等和自修复，等节点数超过 10 台再考虑自动化编排。

这个决策在后续部署中证明了正确性：Bash 脚本在德国节点上跑了 5 轮（测幂等、测自修复、测配置恢复），每次改动都可以立即验证。如果走 Ansible，仅 `ansible-playbook --check` 的调试周期就是现在的 3 倍以上。

---

## 二、 源站：APKG + WebDAV —— 数据的起点

在讨论边缘节点怎么拉数据之前，必须先说清楚数据从哪来。整个分发链路的源头是一台 Docker Swarm 集群上运行的 APKG 服务，它负责生成 APT 仓库，并通过只读 WebDAV 暴露给所有边缘节点。

### 2.1 APKG：APT 仓库生成引擎

APKG 是一个 ASP.NET Core 应用，负责接受 `.apkg` 包上传、签名仓库快照、并以标准 APT 仓库格式组织文件。生产环境用 Docker Swarm 部署：

```yaml
version: "3.9"

services:
  app:
    depends_on:
      - db
    image: pubhub.aiursoft.com/aiursoft/apkg:latest
    volumes:
      - apkg-files:/data/files         # 上传的 .apkg 源文件
      - apkg-export:/export             # 生成的 APT 仓库目录
    environment:
      - Storage__Path=/data/files
      - Storage__ExportPath=/export
      - ConnectionStrings__DefaultConnection=Server=db;Database=apkg;Uid=apkg;Pwd=<password>;
      - ConnectionStrings__DbType=MySql
    networks:
      - proxy_app
      - internal

  db:
    image: pubhub.aiursoft.com/mysql:9.7.0
    command: --skip-log-bin
    volumes:
      - apkg-db:/var/lib/mysql
    environment:
      - MYSQL_DATABASE=apkg
      - MYSQL_USER=apkg
      - MYSQL_PASSWORD=<password>
    networks:
      - internal

  webdav:
    image: localhost:8080/box_starting/local_webdav:latest
    volumes:
      - apkg-export:/export:ro          # 只读挂载 APT 仓库目录
    networks:
      - proxy_app

volumes:
  apkg-files:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /swarm-vol/apkg-data/files
  apkg-export:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /swarm-vol/apkg-data/export
  apkg-db:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /swarm-vol/apkg-data/mysql

networks:
  proxy_app:
    external: true
  internal:
    driver: overlay
```

### 2.2 WebDAV：只读分发出口

WebDAV 容器是整个分发链路的"闸门"。基于 `hacdias/webdav` 构建，配成完全只读：

**Dockerfile**:
```dockerfile
FROM pubhub.aiursoft.com/hacdias/webdav:latest
COPY webdav-config.yaml /config.yaml
CMD ["-c", "/config.yaml"]
```

**webdav-config.yaml**:
```yaml
address: 0.0.0.0
port: 8080

directory: /export
permissions: R          # 只读 —— PUT/POST/DELETE 全部返回 403

behindProxy: true
```

> **设计意图**: `permissions: R` 是整个分发链路的第一道安全防线。即使边缘节点被入侵，攻击者也无法通过 WebDAV 往回写入恶意包。APT 安全最终由 GPG 签名保证，但"只读源站"在传输层提供了纵深防御。

### 2.3 Caddy 反代：暴露两个域名

源站的 Caddy 配置非常简单——两个域名，各司其职：

```caddy
apkg.aiursoft.com {
    log
    import hsts
    reverse_proxy http://apkg_app:5000
}

apkg-dav.aiursoft.com {
    log
    import hsts
    reverse_proxy http://apkg_webdav:8080 {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

| 域名 | 用途 | 后端 |
|------|------|------|
| `apkg.aiursoft.com` | Web UI + API（包上传、管理） | `apkg_app:5000` |
| `apkg-dav.aiursoft.com` | 只读 WebDAV（边缘节点拉取） | `apkg_webdav:8080` |

边缘节点的 `sync-logic.sh` 就是从这个 `apkg-dav.aiursoft.com` 拉数据的。

---

## 三、 架构概览与设计哲学

整个网络由三台极其轻量的 VPS（1C-1G-25G，运行 Ubuntu 26.04 LTS）组成，分别位于法兰克福、新加坡和西雅图。

**架构核心原则：**

1. **边缘完全自治：** 节点之间不通信。每个节点通过后台死循环默默从主站（WebDAV）拉取数据。
2. **纯 HTTP 裸奔的后端：** 节点服务器上的 Caddy 只监听 80 端口，不处理任何 HTTPS 证书。TLS 卸载全部交给 Cloudflare 边缘节点。
3. **零宕机原子更新：** 彻底杜绝 `apt update` 拉取到损坏依赖的灾难。

---

## 四、 边缘节点：利用 A/B 目录实现”原子级同步”

在配置单台节点时，最核心的痛点是：**如果 rclone 正在同步，刚传了 Packages 索引，但 `.deb` 还没传完，此时用户跑来下载怎么办？**

我们放弃了传统的 Rsync 覆盖，在 `docker-compose.yml` 中引入了经典的 A/B 目录切换策略。

以下是浓缩后的节点核心逻辑：

1. **Caddy 容器：** 仅暴露 80 端口，将 `/data/www` 目录作为静态文件服务器暴露出去。
2. **Rclone 容器：** 运行一个巧妙的 Bash 脚本，先将数据拉取到隐藏的 `.staging` 目录。
3. **原子切换：** 当数据 100% 校验拉取完成后，利用 Linux 的 `mv` 命令，瞬间替换 `www` 目录，并写入一个包含当前时间戳的 `sync_status.json` 文件。

> **架构师心得：** `mv` 操作在同一文件系统下仅修改 inode 指针，耗时不到 1 毫秒。这一瞬间的原子性，保证了 APT 客户端看到的永远是同一个版本的快照。

---

## 五、 Cloudflare 负载均衡：$20 的企业级流量调度

底层就绪后，需要将 `packages.anduinos.com` 这个统一域名分发给这三座孤岛。这里我启用了 Cloudflare 的 Load Balancing 产品，并附加了 Traffic Steering（流量调度）。

**配置三步曲：**

1. **锻造灵魂探针 (Monitors)：**
没有探测 `/` 根目录，而是设置探针每 60 秒 GET 一次 `/sync_status.json`。这确保了节点不仅“活”着，而且数据已经同步就绪。
2. **划分三大战区 (Pools)：**
建立 `pool-eu`（德国 IP）、`pool-asia`（新加坡 IP）和 `pool-us`（美国 IP）三个独立池子。并将 `pool-us` 设为 Fallback（兜底回滚池）。
3. **启用 Geo-Steering (地理位置调度)：**
将欧洲的流量划给德国节点，亚太的划给新加坡节点，南北美洲的划给美国节点。中东和非洲由于海底光缆走向，也优先指向欧洲池。

---

## 六、 实战：加一台新节点的完整流程

以下是给团队后人看的操作手册。当需要在东京或圣保罗加新节点时，照做即可。

### 6.1 采购与基线检查

在 Vultr 选好机房，开一台 Ubuntu 26.04 LTS，1C-1G-25G，确认有公网 IPv4。开机后：

```bash
ssh anduin@<IPv6地址>
# 确认系统版本
lsb_release -d
# 确认公网 IPv4（部署完成后要在 Cloudflare 配）
curl -s -4 ip.sb
# 确认 IPv6 可达和公网带宽
curl -s --head https://cloudflare.com/cdn-cgi/trace | grep 200
```

### 6.2 部署

```bash
# 从 Git 仓库拉脚本（或 SCP 上去）
scp deploy-edge.sh anduin@<节点IP>:~/
ssh anduin@<节点IP>
sudo bash deploy-edge.sh
```

脚本跑完大约 5 分钟。结束后观察容器状态：

```bash
sudo docker ps
# 期望输出：
# anduinos_caddy   Up X seconds
# anduinos_sync    Up Y seconds (healthy)
```

如果 Caddy 没有立即 Up（显示 Created），是因为在等 rclone-worker 的 healthcheck。`docker logs -f anduinos_sync` 可以看同步进度。首轮同步完成后 Caddy 会自动起来。

### 6.3 验证

```bash
# 本地验证
curl -s http://localhost/ | head
curl -s http://localhost/sync_status.json

# 外部验证（从你的本机跑）
curl -s -o /dev/null -w “HTTP %{http_code}\n” http://<IPv4>/
curl -s http://<IPv4>/sync_status.json
```

### 6.4 接入 Cloudflare 负载均衡

1. 在 CF 后台 → Traffic → Load Balancing → 找到 `packages.anduinos.com` 的 LB。
2. 将新节点 IP 加入对应地理位置的 Origin Pool（如东京加 `pool-asia`）。
3. Monitor 探针配置：
   - Type: HTTP GET
   - Path: `/sync_status.json`
   - Interval: 60s
   - Timeout: 5s
   - Expected code: 200
4. 等待探针变绿（Healthy），新节点即加入流量池。

### 6.5 验证 APT 可用

```bash
curl -s https://packages.anduinos.com/artifacts/anduinos/dists/questing-addon/InRelease | head -3
# 应输出: -----BEGIN PGP SIGNED MESSAGE----- (无 BOM)
sudo apt update
# 应看到 Get:1 https://packages.anduinos.com/artifacts/anduinos ... InRelease
```

---

## 结语

至此，AnduinOS 的全球边缘分发网络正式点亮。

这个架构有三个特点值得记住：

1. **Shared-nothing**: 节点之间不通信，一个挂了不影响其他。扩容就是加机器、跑脚本、配 DNS。
2. **纯 HTTP 后端**: TLS 在 Cloudflare 终结。APT 的安全由 GPG 签名保证，不依赖传输层加密。这让我们可以写一个零 Secret 的部署脚本。
3. **原子同步**: A/B 目录切换保证 APT 客户端永远不会看到半成品。

对于资源有限的初创项目，这套”极简后端 + 云平台前端”的组合，可能就是云原生时代最务实的解法。

---

## 附录：工程落地踩坑实录

理论再美，真刀真枪推到生产环境时仍然踩了一串坑。以下是从零到三节点全面上线的完整故障清单。

### Bug 1: `lsof` 在最小化镜像上不存在

**严重程度**: 🔴 致命

**现象**: 脚本在干净的 Ubuntu 26.04 VPS 模板上第一行校验就炸了。

**根因**: `port_exist_check` 函数调用了 `lsof`，但 `lsof` 在后续 `apt install` 阶段才装。Ubuntu Server ISO 预装了 `lsof`，但 VPS 厂商的最小化模板经常不装。这是典型的"在满配系统上写脚本"导致的时序依赖错误。

**修复**: 用内核自带的 `ss`（来自 `iproute2`，永驻系统）替代 `lsof`：

```bash
# 之前
sudo lsof -i:"$1" | grep -i -c "listen"

# 之后
sudo ss -tlnp "sport = :$1" | grep -c ":$1"
```

**教训**: 端口检查永远放在依赖安装之前，因此必须只用系统自带工具。`ss`、`ip`、`grep` 才是最小化环境的底线。

---

### Bug 2: `rclone/rclone:latest` 镜像 ENTRYPOINT 冲突

**严重程度**: 🔴 致命

**现象**: 容器 `anduinos_sync` 无限 restart loop。`docker logs` 循环打印：

```
Error: unknown command "/bin/sh" for "rclone"
```

**根因**: `rclone/rclone` 镜像将 ENTRYPOINT 设为 `rclone`。Docker Compose 把 entrypoint + command 拼接成 `rclone /bin/sh /sync-logic.sh`。rclone CLI 收到 `/bin/sh` 作为子命令，直接报错退出。

**修复**: 显式覆盖 entrypoint，不让镜像默认的 `rclone` 参与拼接：

```yaml
rclone-worker:
    image: rclone/rclone:latest
    entrypoint: ["/bin/sh"]        # 覆盖镜像默认的 rclone entrypoint
    command: ["/sync-logic.sh"]
```

**教训**: 永远不要假设第三方镜像的 ENTRYPOINT 行为。`docker inspect <image> | jq '.[].Config.Entrypoint'` 是部署前的必修课。

---

### Bug 3: `depends_on` 是虚假承诺

**严重程度**: 🟡 中等

**现象**: Caddy 在 rclone-worker 启动后立即启动，但此时首轮同步尚未完成（`/data/www/` 为空）。用户访问看到满屏 404。

**根因**: Docker Compose 的 `depends_on` 只等待容器**启动**，不等待业务**就绪**。rclone-worker 启动后立刻进入 while 循环，容器状态变成 `running`，Docker 认为依赖已满足，放行 Caddy。

**修复**: 给 rclone-worker 添加 `healthcheck`，让 Caddy 真正等到 `sync_status.json` 出现：

```yaml
rclone-worker:
    healthcheck:
      test: ["CMD", "test", "-f", "/data/www/sync_status.json"]
      interval: 30s
      timeout: 5s
      retries: 60       # 最多等 30 分钟
      start_period: 10s

caddy-server:
    depends_on:
      rclone-worker:
        condition: service_healthy   # 而非默认的 service_started
```

**教训**: `depends_on` 不加 `condition: service_healthy` 等于没写。对于首次部署（数据从零开始同步），必须给足 healthcheck 超时窗口。

---

### Bug 4: Caddy `hide` 不仅隐藏列表，还阻止文件访问

**严重程度**: 🟡 中等

**现象**: 外部监控探针 GET `/sync_status.json` 返回 404，但文件确实存在。

**根因**: Caddy `file_server browse` 的 `hide` 指令不仅从目录列表隐藏文件，**也阻止 HTTP 访问该文件**。这是安全设计，不是 bug。但 `sync_status.json` 需要作为 Cloudflare health check 和外部监控的探针端点。

**修复**: 从 `hide` 列表中移除 `sync_status.json`：

```caddy
# 之前
file_server browse {
    hide .staging www_old sync_status.json
}

# 之后
file_server browse {
    hide .staging www_old
}
```

**教训**: 如果一个文件既要对外暴露又要不在目录列表中出现，Caddy 的 `hide` 做不到。考虑用单独的 `route` 块或重命名为 `.well-known/` 下的路径。

---

### Bug 5: InRelease 文件带 UTF-8 BOM，GPG 拒绝解析

**严重程度**: 🔴 致命

**现象**: `apt update` 报错：

```
Clearsigned file isn't valid, got 'NOSPLIT' (does the network require authentication?)
```

**根因**: 源站 `apkg-dav.aiursoft.com` 上的 `InRelease` 文件首字节带有 UTF-8 BOM（`EF BB BF`）。用 `hexdump -C` 对比了旧源 `apkg.aiursoft.com`（无 BOM，`apt` 正常）和 CDN 源（有 BOM，`apt` 失败），确认差异：

```
# 旧源 (正常)
00000000  2d 2d 2d 2d 2d 42 45 47...  -----BEGIN PGP S...

# 新源 (失败)
00000000  ef bb bf 2d 2d 2d 2d 2d...  ...-----BEGIN PGP...
```

GPG 解析 clear-signed 消息时要求文件首字节必须是 `-`（PGP header 的起始符）。BOM 导致解析直接失败。

**修复**: 在 `sync-logic.sh` 的原子切换前加入 BOM 剥离步骤：

```bash
find /data/.staging -type f \( -name "InRelease" -o -name "Release" \) \
    -exec sed -i '1s/^\xef\xbb\xbf//' {} \;
```

**教训**: GPG clear-signed 格式对文件头部极度敏感。APT 仓库的 `InRelease`/`Release` 文件绝对不能包含任何前导字节。如果源站无法修复（可能是 APKG 生成逻辑的 bug），在边缘做 sanitize 是最快且不破坏上游的止血方案。

---

### Bug 6: Caddy Virtual Host 导致裸 IP 访问无响应

**严重程度**: 🟢 小问题

**现象**: `http://66.77.88.99/` 返回 HTTP 200 但 `Content-Length: 0`。

**根因**: Caddyfile 的 site label 是 `http://packages.anduinos.com`，通过裸 IP 访问时 Host 头是 `66.77.88.99`，不匹配任何 site block，走到默认空处理器。

**修复**: 改为端口匹配：

```caddy
# 之前
http://packages.anduinos.com { ... }

# 之后
:80 { ... }
```

**教训**: 边缘节点应该对任何合法 Host 头都响应。域名级别的路由应该交给前端的 Cloudflare，后端不该做 Virtual Host 过滤。

---

### Bug 7: 幂等性——重跑脚本时端口检查误杀自己的 Caddy

**严重程度**: 🟡 中等

**现象**: 脚本重跑时 `port_exist_check` 检测到端口 80 被占用，杀死进程后发现杀的是自己上次部署的 Caddy。

**根因**: 端口检查没有区分"Docker 管理的端口"和"未知进程占用的端口"。在生产环境中，docker-proxy 占用 80 端口是正常状态。

**修复**: 在 `port_exist_check` 中加入 Docker 识别逻辑：

```bash
# 如果是 docker-proxy 占用（自己的 Caddy），放行
if sudo ss -tlnp "sport = :$1" | grep -q "docker-proxy"; then
    print_ok "Port $1 is managed by Docker (existing deployment, will refresh)"
    return 0
fi
```

**教训**: 幂等的关键不是"无脑杀"，而是"识别自己人"。进程名、容器名、systemd unit 都是可用的身份标识。

---

### 最终脚本特性

经过全部修复后，`deploy-edge.sh` 具备以下保证：

| 特性 | 实现 |
|------|------|
| 幂等 | 可反复运行，包安装/UFW/BBR 全部 skip 已存在项 |
| 自修复 | 所有配置文件强制覆盖，删除或损坏后重跑即恢复 |
| 数据安全 | `/opt/anduinos-edge/data` 目录不受脚本影响 |
| 不误杀 | 端口检查识别 Docker 管理的端口 |
| 纯开源 | 零 Secret、零证书、零环境变量 |
| 开机自愈 | `systemctl enable docker` + `restart: unless-stopped` |