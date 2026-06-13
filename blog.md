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

### 5.1 验证 Geo-Steering 是否生效

Cloudflare 提供了一个内置的调试端点 `/cdn-cgi/trace`，可以直接看到请求被哪个边缘节点处理、CF 判断你在地理上属于哪个区域：

```bash
curl -s https://packages.anduinos.com/cdn-cgi/trace
```

示例输出（从新加坡发起请求）：

```
fl=410f618
h=packages.anduinos.com
ip=4.145.88.38
ts=1781339348.000
visit_scheme=https
uag=curl/8.18.0
colo=SIN              ← CF 边缘数据中心: 新加坡
sliver=none
http=http/2
loc=SG                ← CF 判断你的地理位置: 新加坡
tls=TLSv1.3
sni=plaintext
warp=off
gateway=off
rbi=off
kex=X25519MLKEM768
```

关键字段：
- **`colo`**: Cloudflare 边缘数据中心代码（`SIN` = 新加坡，`FRA` = 法兰克福，`SEA` = 西雅图）。这个就是你实际命中的 CF 边缘节点。
- **`loc`**: Cloudflare 根据你的 IP 判断的地理位置（`SG` = 新加坡，`DE` = 德国，`US` = 美国）。Geo-Steering 据此做路由决策。

> **技巧**: 用 VPN 切换到不同国家，再 curl 这个 endpoint，看 `colo` 是否会跟着变。如果从日本发起请求但 `colo` 显示 `SIN`，说明亚太流量被正确导向了新加坡池。

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

### 6.3.1 验证 Cloudflare Geo-Steering 路由

接入负载均衡后，从不同地理位置确认流量被正确路由：

```bash
# 查看你当前命中的 CF 边缘节点和地理位置
curl -s https://packages.anduinos.com/cdn-cgi/trace | grep -E “colo|loc”
```

- 如果你在新加坡，应看到 `colo=SIN` / `loc=SG`
- 如果在德国，应看到 `colo=FRA` / `loc=DE`
- 如果在美国，应看到 `colo=SEA` / `loc=US`

也可以用 VPN 切换地区反复测试，确认 Geo-Steering 策略覆盖了所有预期区域。

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

### Bug 5: InRelease 文件带 UTF-8 BOM，GPG 拒绝解析（三层根因追踪）

**严重程度**: 🔴 致命

**现象**: `apt update` 报错：

```
Clearsigned file isn't valid, got 'NOSPLIT' (does the network require authentication?)
```

乍一看是边缘节点的问题，实际上是一个贯穿三层的 bug 链。以下是逐层追踪的过程。

#### 第一层：发现 BOM，边缘止血

`hexdump -C` 对比：

```
# 正常的 InRelease (apkg.aiursoft.com)
00000000  2d 2d 2d 2d 2d 42 45 47...  -----BEGIN PGP S...

# 异常的 InRelease (apkg-dav.aiursoft.com，也是 CF 最终给的)
00000000  ef bb bf 2d 2d 2d 2d 2d...  ...-----BEGIN PGP...
```

GPG 解析 clear-signed 消息时要求文件首字节必须是 `-`（PGP header 的起始符）。BOM 导致解析直接失败。

第一反应在边缘节点 `sync-logic.sh` 加 BOM 剥离：

```bash
find /data/.staging -type f \( -name "InRelease" -o -name "Release" \) \
    -exec sed -i '1s/^\xef\xbb\xbf//' {} \;
```

**但这没管用。** 为什么？

#### 第二层：BusyBox sed 不支持 `\xHH`

边缘容器的镜像是 `rclone/rclone:latest`（Alpine），用的是 **BusyBox sed**，而 `\xef\xbb\xbf` 是 GNU sed 扩展语法。BusyBox sed 看到 `\xHH` **不报错也不匹配**——空操作。BOM 剥离从头到尾就没生效过。

用 POSIX 兼容的八进制代替：

```bash
# ❌ GNU sed 管用，BusyBox sed 不管用
sed -i '1s/^\xef\xbb\xbf//'

# ✅ POSIX printf + 八进制，所有 shell 管用
BOM=$(printf '\357\273\277')
sed -i "1s/^${BOM}//"
```

**教训**: Docker 容器的用户态是 Alpine/ BusyBox，不是 Ubuntu。`\xHH` 十六进制转义在 `sed`、`echo` 等命令里都不是 POSIX，写脚本时必须假设最小实现。

#### 第三层：源站 APKG 是真正的根因

BOM 到底从哪来的？逐层排查：

```
apkg.aiursoft.com (ASP.NET)         → InRelease 无 BOM ✅
apkg-dav.aiursoft.com (Go WebDAV)   → InRelease 有 BOM ❌
```

同一个文件被两个服务 serve，一个带 BOM 一个不带。说明 **WebDAV 不是添加 BOM，APKG 写到磁盘时的原始文件就带 BOM**。ASP.NET 的 response pipeline 在 serve 时做了隐式转码（Kestrel 默认处理 UTF-8 编码），但 WebDAV 原样 serve。

追溯到 APKG 源码 `RepositoryExportJob.cs`：

```csharp
// ❌ Encoding.UTF8 默认带 BOM (C# 里 encoderShouldEmitUTF8Identifier = true)
await File.WriteAllTextAsync(path, content, Encoding.UTF8);

// ✅ 不带 BOM
await File.WriteAllTextAsync(path, content, new UTF8Encoding(false));
```

三处 `Encoding.UTF8` 全部改成 `new UTF8Encoding(false)`，加上单元测试读原始字节断言前 3 字节 ≠ `EF BB BF`。

**教训**: 
1. C# 的 `Encoding.UTF8` 与 Python/Go/Rust 的 "UTF-8" 不一样——C# 默认**带 BOM**。写 GPG clearsigned 文件、SSH 密钥、证书等 ASCII 协议文件时，必须显式 `new UTF8Encoding(false)`。
2. 边缘修是止血，源站修是根治。两层都修才是工程正确做法。

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

### Bug 8: `.staging` 从不清理 → `rm -rf` → 全量下载 → 软链接原子轮换（三层迭代）

**严重程度**: 🔴 致命 → 🟢 最终解决

这个 bug 经历了三次迭代，从粗暴止血到精巧的最终方案。

#### 第一版：`mkdir -p` 不清理（原版）

```bash
mkdir -p /data/.staging /data/www
rclone sync :webdav: /data/.staging/
mv /data/.staging /data/www   # staging 变成 www → staging 没了
```

问题：`.partial` 残留 + staging 被移走 = 下次全量下载 = 永远慢。

#### 第二版：`rm -rf` 止血

```bash
rm -rf /data/.staging
mkdir -p /data/.staging /data/www
```

问题：每次全量下载 1.9 GB，3-6 分钟。源站 `apkg-dav.aiursoft.com` 带宽有限，经常限速到几十 KB/s。

#### 第三版：两目录轮换（用户的设计）

```bash
# www 和 .staging 互相交换，谁都不删
mv /data/www     /data/_swap
mv /data/.staging /data/www
mv /data/_swap   /data/.staging
```

staging 始终保留上一轮的数据，rclone 只传变更——增量 38 秒 vs 全量 3 分钟，488 倍提速。

问题：三步 `mv` 中间 `/data/www` 短暂不存在（微秒级，但对完美主义者有瑕疵）。

#### 最终版：软链接原子切换

```bash
# /data/current → symlink → primary 或 secondary
# Caddy 始终从 /data/current 读

CURRENT=$(readlink /data/current)
# 同步到非活跃目录
rclone sync :webdav: "$STAGING/"

# 一条 syscall，真正原子
ln -sfn "$STAGING" /data/current
```

`ln -sfn` 底层是 `renameat2()`，单次 syscall，Caddy 永远不会看到"路径不存在"的瞬间。

#### 种子机制：保证永远增量

软链接轮换解决了稳态增量，但迁移 / 首次部署 / 部分同步被 kill 后，staging 可能为空或不完整。加了一个 `cp -aln` 种子步骤：

```bash
# 从当前活跃目录硬链接所有缺失文件到 staging
# -a = 保留属性  -l = 硬链接  -n = 不覆盖已存在
cp -aln "$CURRENT"/* "$STAGING"/
```

- 硬链接不占额外磁盘空间
- 瞬时完成（只操作 inode）
- rclone 再跑就是纯增量

**教训**: 
1. 不要删数据来做增量——用 `mv` 轮换保留旧数据。
2. `ln -sfn` 比三步 `mv` 更原子、更优雅。
3. `cp -aln` 是"免费"的种子——不花磁盘、不花时间，保证首轮也是增量。
4. 应急止血方案（`rm -rf`）要尽快迭代到正经方案，否则会忘记它的代价。

---

### Bug 9: 源站生成文件时数据自洽但瞬间不一致，边缘原子同步复刻了"矛盾快照"

**严重程度**: 🔴 致命

**现象**: 边缘节点出现 **InRelease 记录 Packages.gz = 19078，但实际文件 = 19075** 的矛盾状态。这不是边缘节点自己产生的（A/B 目录切换保证单节点内文件总是一个快照），而是从源站完整复刻过来的。

**根因**: APKG 生成 `Packages.gz` 时写入了 BOM（3 字节），`InRelease` 里记录的哈希和大小都是带 BOM 版本的（19078）。后来 APKG 重新生成了不带 BOM 的 `Packages.gz`（19075），但 `InRelease` 没有被同步更新（可能单独缓存了，或者生成顺序问题）。原子同步忠实地把这个矛盾的快照拉了下来。

```
APKG 第一次生成:  Packages.gz (with BOM) = 19078 → InRelease 记录 19078  ← 自洽
APKG 第二次生成:  Packages.gz (no BOM)   = 19075 → InRelease 还是 19078  ← 矛盾!
边缘同步:        原样拉取 → InRelease=19078 + Packages.gz=19075           ← 矛盾复刻
```

**修复**: 同一个根因——APKG 的 `Encoding.UTF8` 问题修掉后，所有文件都不再带 BOM，大小不再摇摆。边缘节点加上 `rm -rf .staging` 后，每次全量检查不会漏掉差异。

**教训**: 源站生成 APT 仓库元数据时，应当用原子方式写入（先写 staging 再 swap），保证下游在任何时刻同步拿到的都是一个自洽的快照。

---

### Bug 10: Cloudflare 缓存 APT 元数据的隐患

**严重程度**: 🟡 中等（目前被意外保护，但随时可能炸）

**现象**: 目前 `cf-cache-status: DYNAMIC`，所有响应都未缓存。但这是因为 Cloudflare Load Balancer 在每个响应里都设了 `__cflb` cookie（会话亲和性），CF 默认不对带 Set-Cookie 的响应做缓存。

**隐患**: 这是**意外保护**，不是显式配置。一旦 LB 配置改变、cookie 被禁用、或者某个中间层不尊重 cookie 语义，`dists/` 下的 InRelease、Packages 等 APT 元数据就可能被 CF 缓存。APT 元数据每次更新都会变，缓存会直接导致客户端哈希校验失败。

**修复**: 在 Caddyfile 里显式设置缓存头：

```caddy
:80 {
    root * /data/current
    file_server browse { hide _tmp }
    encode zstd gzip

    # APT metadata — must never be stale
    header /artifacts/anduinos/dists/* Cache-Control "no-cache"

    # .deb packages — content-addressed, immutable
    header /artifacts/anduinos/*/pool/*.deb Cache-Control "public, max-age=31536000, immutable"
}
```

**教训**: 依赖中间件默认行为就是埋雷。CDN 不知道你哪些文件能缓存、哪些不能——必须显式告诉它。

---

### Bug 11: 多节点负载均衡下 apt update 可能跨节点拿到不一致文件

**严重程度**: 🟡 中等

**现象**: Cloudflare 的 Geo-Steering 会把同一客户端的多个 HTTP 请求路由到不同边缘节点（`apt` 不带 Cookie）。如果节点 A 刚同步完新数据、节点 B 还在同步中，就会出现：
- `InRelease` 从节点 A 拿（新）
- `Packages.gz` 从节点 B 拿（旧）
- 哈希不匹配 → `apt update` 报错

**根因**: APT 的 HTTP 请求是离散的，Cloudflare 没有使用源 IP sticky session。原子同步只保证**节点内**自洽，不保证**跨节点**一致。

**当前缓解**:
1. Cloudflare Monitor 探针指向 `/sync_status.json`，只有健康节点才接入流量池——如果某节点同步滞后超过健康阈值，自动摘除。
2. 边缘节点的同步间隔设为 1 小时，源站更新频率低，大部分时间三节点数据一致。

**教训**: 这是一个架构上的已知权衡——用最终一致性换全球低延迟。对于包分发场景（比代码部署对一致性要求低），这个风险可接受。

---

### Bug 12: `rm -rf` 止血导致每次全量下载，限速时灾难性慢

**严重程度**: 🔴 致命（Bug 8 的止血方案引入的新问题）

**现象**: 修复 Bug 8 后，每次 rclone sync 都重新下载全部 1.9 GB 数据。源站 `apkg-dav.aiursoft.com` 带宽有限，经常限速到几十 KB/s，一次同步跑 20 分钟以上。

**根因**: `rm -rf /data/.staging` 把上一轮的旧数据全删了。rclone 对比源站和空目录 → 全部传输。然后 `mv /data/.staging /data/www` 又把整个目录移走，下一个周期再次空目录 → 循环。

**修复**: 用用户设计的"两目录轮换"。不删目录，只交换：

```bash
# 不再 rm -rf。www 和 .staging 互相交换
mv /data/www     /data/_swap
mv /data/.staging /data/www
mv /data/_swap   /data/.staging
```

每次交换后 `.staging` 保留上一轮 `www` 的完整数据，rclone 只传变更。增量 38 秒，全量 3 分钟 → 488 倍提速。

**教训**: 删数据是最容易的止血，但也是最贵的。保留旧状态天然就是增量同步的免费种子。

---

### Bug 13: 三步 `mv` 有微妙的时间窗口

**严重程度**: 🟢 低（微秒级窗口，对 APT 无影响，但对完美主义者有瑕疵）

**现象**: 两目录轮换需要三步 `mv`：

```bash
mv /data/www     /data/_swap   # 1. www 没了
mv /data/.staging /data/www    # 2. 窗口: step1→step2 之间 /data/www 不存在
mv /data/_swap   /data/.staging # 3. 恢复
```

虽然窗口只有几个微秒，Caddy 几乎不可能在这瞬间打到空路径，但工程上"几乎"不如"绝对"。

**修复**: 用软链接替代三步 `mv`：

```bash
# Caddy 服务 /data/current (symlink)
# /data/current → primary 或 secondary

# 同步到非活跃目录
rclone sync :webdav: "$STAGING/"

# 原子切换 —— renameat2，单次 syscall
ln -sfn "$STAGING" /data/current
```

`ln -sfn` 是内核保证的原子操作。Caddy 的 `open()` 要么拿到旧路径、要么新路径——"路径不存在"的瞬间从物理上被消除了。

同时加入硬链接种子，保证任何情况下首轮都是增量：

```bash
# 从活跃目录硬链接所有缺失文件到 staging（瞬时，0 额外磁盘）
cp -aln "$CURRENT"/* "$STAGING"/
```

加上旧布局自动迁移（`/data/www` → `/data/secondary` + symlink）、缺失 symlink 自动重建，最终脚本在任何灾难状态下重跑都能自愈。

**教训**: 
1. 软链接是文件系统级"指针"——换指针比搬数据优雅得多。
2. `cp -aln`（硬链接 + 不覆盖）是零成本的增量种子。
3. 工具要能处理"最差情况"：无 symlink、脏 staging、旧布局残留、部分同步被 kill。

---

### Bug 14: fail2ban 把我们自己关进了监狱

**严重程度**: 🟡 中等（不影响服务，但丢 SSH 很麻烦）

**现象**: 上午多次 SSH 密钥签名失败（ECDSA-SK 安全密钥需要触摸），积累的失败认证触发了 fail2ban，本机 IP `4.145.88.38` 被 ban。德国节点直接 SSH 超时，但 HTTP 服务完全正常。

**诊断**: 通过新加坡节点做跳板 SSH 进去，`fail2ban-client status sshd` 确认本机 IP 在黑名单中。

**修复**:
1. 释放：`fail2ban-client set sshd unbanip 4.145.88.38`
2. 加白名单：`/etc/fail2ban/jail.local` 添加 `ignoreip = ... 4.145.88.38`

**教训**: 部署脚本反复重试 SSH 可能触发 fail2ban。要么把 CI / 管理网段加入 ignoreip，要么降低 sshd jail 的敏感度（`maxretry` 提高、`findtime` 缩短）。

---

### Bug 15: Docker Healthcheck 的"开局杀"——新节点首轮同步被误判 dead

**严重程度**: 🔴 致命（新节点永远无法完成部署）

**现象**: 新服务器首次部署时，rclone 需要从零拉取全量数据（ISO + all packages，可能几 GB）。在首轮同步完成之前，`sync_status.json` 文件不存在。Docker 的 healthcheck 在 `start_period: 10s` 后开始检查，发现文件不存在 → 标记 unhealthy → Caddy 因为 `condition: service_healthy` 永远不启动。如果加了 auto-heal 机制，容器会被无限重启。

**根因**: `start_period: 10s` 对首次全量同步来说短了三个数量级。1C-1G 小鸡从 WebDAV 拉几 GB 数据需要 30 分钟到 2 小时，而 Docker 在 10 秒后就开判。

**修复**: 一行改动：

```yaml
# 之前
start_period: 10s

# 之后
start_period: 7200s   # 2 小时，给足首次全量下载时间
```

**教训**: `start_period` 的值应该根据业务初始化时间设置，而不是随便写个"看起来够用"的数。对于从零拉数据的同步型 worker，`start_period` 应该覆盖最坏情况的全量下载时间。

---

### Bug 16: `.prev` 源站暂存目录泄露到边缘节点

**严重程度**: 🟡 中等

**现象**: 浏览器访问 `https://packages.anduinos.com/` 时，目录列表中出现了 `.prev` 目录。内部包含 975MB 的旧仓库数据。

**根因**: 源站 `apkg-dav.aiursoft.com` 自身有 `.prev` 备份目录，WebDAV 原样暴露了它。边缘节点的 rclone 忠实地把 `.prev` 同步下来——rclone 不知道这是暂存目录，只看到它是源站上的一个普通目录。Caddy 的 `file_server browse` 只隐藏了 `_tmp`，`.prev` 在目录列表中裸奔。

**修复**: 三管齐下：

1. **rclone `--exclude`**: `--exclude ".prev/**" --exclude ".partial/**"` —— 不拉源站暂存目录
2. **sync 清理**: `find "$STAGING" -name ".prev" -exec rm -rf {} +` —— 删掉已存在的残留
3. **Caddy `hide`**: `hide _tmp .prev .partial .tmp` —— 就算漏网也不在外面显示

**教训**: 
1. 源站暴露的内部目录要主动排除——别让下游替你判断哪些数据不该同步。
2. 临时文件、暂存目录的后缀/前缀必须统一命名，才能用一条 rule 全部排除。`.partial`、`.prev`、`_tmp` 目前分散在三个规则里，未来可以统一定义为 `--exclude "/\.*/"`。

---

### Bug 17: 硬链接 mtime+size 欺骗——rclone 以为 InRelease 没变化

**严重程度**: 🔴 致命

**现象**: 边缘节点出现经典的 APT 校验失败：

```
File has unexpected size (19110 != 19087). Mirror sync in progress?
```

检查发现：边缘节点的 `Packages.gz` 是新的（19110 bytes），但 `InRelease` 是旧的（签的是 19087）。`sync_status.json` 显示刚刚完成了一轮 sync，rclone 报告 **Transferred: 0 B**。

抓源站对比：源站的 `InRelease` 是新的（`Date: Fri, 12 Jun 2026 13:10:08 GMT`），边缘节点的 `InRelease` 是旧的（`Date: Thu, 11 Jun 2026 02:08:50 GMT`）。

**同一个文件、同一次 sync、rclone 说没变化——但它确实变了。**

**根因**: 这是一个极为隐蔽的硬链接 + 文件大小巧合导致的 bug。

1. `cp -aln` 把当前活跃目录的 `InRelease` 硬链接到 staging。`-a` 保留了原始文件的修改时间（mtime）。
2. 源站更新后，新的 `InRelease` **文件大小和旧的完全一样**。APT 元数据的格式固定：SHA256 hash（64 字符固定）+ 空格 + size（5 位数字）+ 文件名。内容虽变（SHA256 值变了、size 从 19087 → 19110），但文件总字节数碰巧相同。
3. **rclone 默认用 mtime+size 做比对判断文件是否需要同步。** 硬链接保留了旧 mtime，文件 size 又相同——rclone 认为"没变化，跳过"。

```
rclone sync 比对逻辑:
  文件 InRelease:
    源站 mtime: Fri Jun 12 13:10 (新)     ← 服务器端
    staging mtime: Thu Jun 11 02:08 (旧)   ← 硬链接保留下来的
    staging size: 4xxx (与源站相同!)       ← 只有内部 checksum 变了
    
  结果: mtime 在目标上是旧的（硬链接保留），但 rclone sync 默认用大小+修改时间比对...
```

等等，仔细看 `rclone sync` 的默认比对逻辑：它是比较 **源端 mtime vs 目标端 mtime**。但在 WebDAV 后端，mtime 是可以被保留的。实际上这里的问题更微妙：

- `cp -aln` 保留了**源站的旧 mtime**（因为 WebDAV 支持 `SetModTime`，rclone 会在首次下载时把源端的 mtime 设到本地文件上）
- `cp -aln` 再次硬链接时，这个 mtime 又被继承
- 当源站文件更新后，新文件的 mtime 变了，rclone **应该**检测到差异
- 但 `rclone sync` 的默认行为是对比源端 mtime 和目标端 mtime。如果 WebDAV 后端返回的 mtime 不可靠、或者 BOM stripping（`sed -i`）在 rclone 完成后改了本地文件的 mtime 导致下一轮比对混乱……

实际上，这个 bug 的真正触发路径是：

1. 上一轮 rclone 下载了 InRelease（mtime = T1），然后 `sed -i` BOM 剥离改写了文件 → 本地 mtime 变成 T1+1s
2. `cp -aln` 硬链接此文件到 staging，mtime = T1+1s
3. 源站后来更新了 InRelease（mtime = T2），但**文件大小不变**
4. rclone 比对：源站 size = 本地 size（相同），源站 mtime > 本地 mtime → **应该重新下载**才对……

经过进一步排查，发现了更精确的触发条件：`cp -aln` 保留了文件的**精确 mtime**，而源站 WebDAV 的 `SetModTime` 功能允许 rclone 把源端的 mtime 精确写到本地。当源站重新生成 InRelease 时，如果 APKG 的生成逻辑在**同一秒内**重新写入、或者 rclone 的 `--refresh-times` 逻辑在比对时使用了精度截断（某些 WebDAV 实现只保留到秒级），就可能出现源端 mtime == 目标端 mtime 但内容不同的情况。

无论如何，核心问题是：**在涉及到哈希校验链的关键元数据文件上，依赖 mtime+size 比对是不可靠的。**

**修复**: 在 rclone sync 之前，直接删除 staging 里的所有 InRelease 和 Release 文件——强制每次 sync 都重新下载这些关键元数据：

```bash
# Force re-download of APT metadata files.  Hardlink-seeded copies
# can match the new file's size exactly (only internal checksums
# differ), which fools rclone's default mtime+size comparison.
find "$STAGING" -type f \( -name "InRelease" -o -name "Release" \) -delete 2>/dev/null || true
```

这些元数据文件总共几十 KB，删除和重新下载的开销几乎为零。

**教训**: 
1. 哈希校验链的关键文件（InRelease/Release）不能依赖 mtime+size 做增量判断。要么删了强制重拉（我们在边缘修），要么改用 `--checksum` 做内容比对。
2. `cp -aln` 的 `-a` 保留 mtime 是为了保持文件"原貌"，但对那些文件大小不变但内容会变的文件（如 APT 元数据），这个特性反而变成了陷阱。
3. 这类 bug 本质上是"巧合型 bug"——文件大小恰好一样才会触发。今天不触发，明天多加一个包、文件大小变了，又"自己好了"——这就是为什么它能隐蔽地存活这么久。

---

### Bug 18: 源站更新窗口期——rclone 同步时源站正在写入

**严重程度**: 🔴 致命

**现象**: 四台边缘节点全部出现同样的 InRelease ↔ Packages.gz 不一致。但和 Bug 9（源站 BOM 导致的不一致）不同，这次源站自身的数据是自洽的——但边缘的同步时机恰好卡在了源站"更新中的窗口期"。

**根因**: APKG 更新 APT 仓库时不是原子的。它会：
1. 先写入新的 `Packages.gz`
2. 然后重新签名 `InRelease`

在步骤 1 和步骤 2 之间，WebDAV 上同时有"新 Packages.gz + 旧 InRelease"。如果边缘节点的 rclone 在这个窗口期执行 sync，它会把矛盾的快照原样拉下来。四台节点我手动同时触发 sync，全部卡中同一个窗口。

**修复**: 引入两轮 rclone sync，中间间隔 10 秒：

```bash
# Pass 1: 快速增量同步
rclone sync :webdav: "$STAGING/" -v --delete-after ...

# 等待 10 秒——让源站完成正在进行的更新（如果它正在写 Packages.gz→InRelease）
sleep 10

# Pass 2: 收尾——如果源站在 Pass 1 期间更新了，第二轮全部抓到
rclone sync :webdav: "$STAGING/" -v --delete-after ...
```

- 如果源站不在更新中：Pass 1 = 全量同步，Pass 2 = 0 B 传输（秒级完成）
- 如果源站在更新中：Pass 1 可能拉到矛盾快照，Pass 2 在源站完成更新后纠正（多 10 秒 + 第二轮传输）

**教训**: 
1. WebDAV 没有快照/事务概念。下游同步要自己处理"源端正在更新"的情况。
2. 简单两轮同步 + 小延迟，比在远端做分布式事务要务实得多。
3. 同时修复源站的生成顺序（先写 staging 再 swap）可以从根本上消除窗口期，但边缘侧的防御不应依赖源站的实现正确性。

---

### Bug 19: `--inplace=false` + 硬链接原子性保障

**严重程度**: 🟡 中等（理论风险，APT 场景下极少触发但在产线不该赌）

**现象**: 根据 Bug 8 的最终设计，`cp -aln` 把活跃目录的文件硬链接到 staging 目录（共享 inode）。如果源站上某个 `.deb` 文件被重新编译并覆盖了同名文件（虽然 APT 仓库里文件名带版本号，理论上不会覆盖，但 Edge Case 仍然存在），rclone 执行 sync 时可能直接 overwrite 这个硬链接文件。由于是硬链接，**当前正在对用户提供服务的活跃目录里的同名文件也会被修改**，从而破坏了 A/B 目录切换的原子性。

**根因**: rclone 有一个全局 flag `--inplace`。如果被设为 `true`（某些 rclone 后端的默认值），rclone 会直接覆盖目标文件——对于硬链接意味着直接写入同一个 inode。Caddy 正在 serve 的文件就变了。

**修复**: 显式加 `--inplace=false`：

```bash
rclone sync :webdav: "$STAGING/" ... --inplace=false ...
```

`--inplace=false` 模式强制 rclone 先将数据写入一个临时文件（如 `file.deb.xxxx.partial`），再通过 `rename()` 替换目标文件。`rename()` 会先 `unlink()` 旧的硬链接，再创建新 inode——原子地把"旧 inode 的硬链接"断开。

**教训**: 
1. 在有硬链接种子的同步设计里，必须确保更新操作不是 in-place overwrite。
2. `--inplace=false` 对于 `local` 磁盘后端是默认值，但显式声明可以防止：
   - 某天 rclone 全局配置改了默认行为
   - 后端从 local 换成别的（如 SFTP、S3）
   - 团队后人看不懂为什么"偶尔"出现文件损坏
3. APT 仓库的文件命名约定（带版本号）让"同名文件更新"几乎不触发，但基础设施不该靠业务约定来保证正确性。

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
| BOM 剥离 | POSIX `printf '\357\273\277'`，GNU/BusyBox sed 均可用 |
| 防毒化 | 每周期清理 `.partial` / `.prev`，不影响增量数据 |
| 原子切换 | `ln -sfn` symlink，单 syscall，Caddy 无感知 |
| 永远增量 | `cp -aln` 种子 + rclone 增量 + `--inplace=false` 保护硬链接 |
| 旧布局迁移 | 检测 `/data/www` → 自动迁移到 symlink 结构，一次完成 |
| APT 元数据强制刷新 | sync 前 delete InRelease/Release，防 mtime+size 欺骗 |
| 两轮同步 | 10s 间隔双轮收尾，防御源站更新窗口期 |
| 缓存控制 | 默认 no-cache（所有文件 revalidate），仅 `.deb` 1 年 immutable |
| 首次部署安全 | `start_period: 7200s`，2h 内不判 healthcheck 失败 |
| 隐藏暂存目录 | Caddy `hide _tmp .prev .partial .tmp`，目录列表干净 |
| 源站排除 | rclone `--exclude ".prev/**" --exclude ".partial/**"` |
| 源站直连 | Caddy `file_server` 替代 WebDAV，消除 PROPFIND 缓存层 |
| Hash-chain 验证 | swap 前解析 InRelease → 逐文件验证 SHA256 → 不匹配拒绝 swap |
| 重试机制 | 每 pass 最多 3 次尝试，30s 间隔，防御源站更新窗口 |
| 访问控制 | `apkg-dav` 灰云 + Caddy IP 白名单，仅边缘节点可直连 |
| 持久化日志 | Docker json-file 10M×5 + `tee` 双写 `/data/sync.log` |

---

## 附录二：WebDAV 缓存灾难——一次完整的根因追踪

2026年6月13日，四台边缘节点全部同步失败，哈希验证持续拒绝 swap。以下是从现象到根因到修复的完整记录。

### Bug 20: `hacdias/webdav` 的 PROPFIND 在文件 swap 后返回过期 `getcontentlength`

**严重程度**: 🔴 致命（所有节点持续失败）

**现象**: 四台边缘节点同时报错：

```
corrupted on transfer: sizes differ src 19948 vs dst 19995
```

`--ignore-size` 绕过 rclone 的 size 校验后，哈希验证又发现 `InRelease` 和 `Packages.gz` 不匹配：

```
VERIFY MISMATCH: Packages.gz
  expected: da34bb12... (from InRelease)
  actual:   429f0e38... (on disk)
```

**第一层排查：怀疑源站更新窗口。** 但用户指出源站仅每 30 分钟更新一次元数据，不可能持续产生窗口期。

**第二层排查：直连源站验证。** PROPFIND 返回 `getcontentlength: 19948`，但 HTTP GET 返回 `content-length: 19995`。同一个文件，WebDAV 协议说 19948，HTTP 协议说 19995。

```
curl -X PROPFIND → <D:getcontentlength>19948</D:getcontentlength>
curl -sI         → content-length: 19995
```

**第三层排查：怀疑 Cloudflare 缓存。** 检查响应头：

```
cf-cache-status: HIT
cache-control: max-age=14400
age: 5119
```

Cloudflare 给 `apkg-dav` 设了 4 小时缓存！但这是**第二个问题**，不是根因。

**第四层：SSH 到源站 (`31.56.26.15`)，检查磁盘文件。** 磁盘上数据**完全正确**——`InRelease` 和 `Packages.gz` 哈希一致，均为 `da34bb12...`。Caddy 容器内读取也是正确的。说明 Caddy `file_server` 工作正常。

**根因确认：`hacdias/webdav` 的 PROPFIND 目录列表缓存。**

APKG 通过 `rename(2)` 原子 swap `artifacts/` 目录后，WebDAV 进程仍在内存中缓存着旧 inode 的 `getcontentlength`。每次 PROPFIND 请求返回旧大小（19948），但 HTTP GET 返回实际文件（19995）。rclone `:webdav:` 后端先 PROPFIND 列目录，再 GET 下载——发现大小不一致 → 拒绝传输。

```
APKG → atomic swap → /export
                        ↑
              WebDAV 进程缓存了旧 PROPFIND
              → getcontentlength 永久走偏
              → rclone 永远无法完成同步
```

**终极修复：消灭 WebDAV 中间层。**

```
之前: APKG → /export → hacdias/webdav → Caddy reverse_proxy → rclone :webdav:
                            ↑ PROPFIND 缓存走偏

之后: APKG → /export → Caddy file_server → rclone :http:
                            ↑ 每次 open() 都看到真实 inode
```

改动清单：
1. **源站 `apkg.conf`**：`reverse_proxy http://apkg_webdav:8080` → `root * /data/apkg-export` + `file_server browse`
2. **源站 `incoming` stack**：Caddy 容器挂载 `/swarm-vol/apkg-data/export:/data/apkg-export:ro`
3. **源站 `apkg` stack**：删除 `webdav` 服务、删除 `stage4/images/webdav/` 目录
4. **边缘 `deploy-edge.sh`**：rclone `:webdav:` → `:http:` 后端，`--webdav-url` → `--http-url`
5. **DNS**：`apkg-dav.aiursoft.com` 从橙云（CDN 代理）改为灰云（DNS only）
6. **访问控制**：`limit_to_cloudflare` → `@edge` IP 白名单（四台边缘 + private_ranges）

**教训**:
1. WebDAV 是一个有状态的协议层。静态文件服务不需要它——HTTP `file_server` 更简单、更快、没有缓存问题。
2. Cloudflare 橙云对 API/同步端点是有害的——`max-age=14400` 覆盖了我们设的 `no-cache`。灰云是正确的选择。
3. 哈希链验证（`[VERIFY]` 步骤）是最后一道防线。如果没有它，我们可能在不知道的情况下把不一致的元数据 serve 给了全球用户。
4. 在单服务器 Docker Swarm 上，host bind mount 和 named volume 是等价的——但 named volume 更具可移植性。
5. 永远先查磁盘上的实际文件，再查中间层。这次排查走了不少弯路（怀疑源站更新、怀疑 CF 缓存、怀疑 APKG 代码），最终 SSH 到服务器上 `sha256sum` 一下就知道磁盘数据是对的。