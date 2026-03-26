# OpenClaw RDP 多用户部署方案

基于 OpenClaw 官方镜像，在其基础上加装 xfce4 桌面环境与 xrdp 远程桌面服务，可通过 RDP 客户端连入独立容器，容器内还预装了 Chrome，可开箱即用地访问 OpenClaw Web UI。每个用户对应一个完全隔离的容器，数据互不干扰。

## 文件结构

```
openclaw-rdp/
├── Dockerfile.rdp      # 扩展官方镜像：加装 xfce4 + xrdp + supervisord
├── supervisord.conf    # 进程管理：同时守护 xrdp 和 openclaw-gateway
├── entrypoint.sh       # 容器启动时初始化 openclaw 配置，设置 RDP 密码
├── launch.sh           # 按用户名生成并执行 docker run 命令的辅助脚本
└── README.md
```

## 架构说明

```
外部网络（Windows 客户端）
        │ VSCode SSH 端口转发
        ▼
┌───────────────────────────────────────────────┐
│  宿主机                                        │
│  127.0.0.1  <rdp-port>  → container:3389      │ ← 仅本机可达
│  127.0.0.1  <gw-port>   → container:18789     │ ← 仅本机可达
│  127.0.0.1  <br-port>   → container:18790     │ ← 仅本机可达
│                                               │
│  ┌─────────────────────────────────────────┐  │
│  │  openclaw-net-<username>  (独立网络)     │  │
│  │                                         │  │
│  │  container: openclaw-<username>         │  │
│  │  supervisord                            │  │
│  │  ├── xrdp-sesman  :3389                 │  │
│  │  ├── xrdp         :3389                 │  │
│  │  └── openclaw-gateway (node) :18789/90  │  │
│  │                                         │  │
│  │  volume: openclaw-data-<username>       │  │
│  └─────────────────────────────────────────┘  │
└───────────────────────────────────────────────┘
```

**进程管理**：supervisord 在单容器内同时管理 xrdp 和 openclaw-gateway，无需 docker-compose 的双容器依赖。

**数据隔离**：每个用户的配置文件、会话历史、工作区文件均存储在独立的 Docker named volume（`openclaw-data-<username>`），容器删除后数据保留，重新部署可恢复。

**网络隔离**：每个容器运行在独立的 Docker bridge 网络（`openclaw-net-<username>`）中，用户之间无法互相访问。

**端口暴露策略**：所有端口（RDP、Gateway、Bridge）均绑定到宿主机 `127.0.0.1`，只能通过 VSCode SSH 端口转发从客户端访问，不对任何网络直接暴露。

**免交互初始化**：entrypoint.sh 在首次启动时以 `--non-interactive --accept-risk` 参数运行官方 `onboard` 命令，完成 identity 密钥生成、agent 配置等初始化，随后用 Python 精准 patch `openclaw.json` 中的 gateway token 与 MaaS provider 配置，其余字段（hooks、plugins、tools 等）均保持 onboard 写入的默认值。再次启动时检测到 identity 目录已存在则跳过 onboard，只执行 patch 步骤。

---

## 部署步骤

### 第一步：构建镜像（仅需一次）

```bash
cd openclaw-rdp

docker build --build-arg OPENCLAW_IMAGE=ghcr.io/openclaw/openclaw:latest -f Dockerfile.rdp -t openclaw-rdp:latest .
```

构建完成后可通过 `docker images openclaw-rdp` 确认。

若需固定到某个 OpenClaw 版本，将 `latest` 替换为具体 tag，例如 `ghcr.io/openclaw/openclaw:2026.3.23`。

### 第二步：为每个用户启动容器

```bash
chmod +x launch.sh

./launch.sh <username> \
  --rdp-port 13389 \
  --gateway-port 18789 \
  --bridge-port 18790 \
  --maas-api-key <你的MaaS API Key> \
  --rdp-password Alice@2026
```

---

## 多用户端口规划

每个用户需要三个不重复的端口。建议按以下方式递增分配：

| 用户  | RDP 端口 | Gateway 端口 | Bridge 端口 |
|-------|----------|-------------|------------|
| alice | 13389    | 18789       | 18790      |
| bob   | 13390    | 18889       | 18890      |
| carol | 13391    | 18989       | 18990      |
| dave  | 13392    | 19089       | 19090      |

启动示例：

```bash
KEY=<MaaS API Key>

./launch.sh alice --rdp-port 13389 --gateway-port 18789 --bridge-port 18790 --maas-api-key $KEY --rdp-password Alice@2026
./launch.sh bob   --rdp-port 13390 --gateway-port 18889 --bridge-port 18890 --maas-api-key $KEY --rdp-password Bob@2026
./launch.sh carol --rdp-port 13391 --gateway-port 18989 --bridge-port 18990 --maas-api-key $KEY --rdp-password Carol@2026
```

---

## 用户使用说明

### 连接远程桌面

首先在 VSCode PORTS 标签页转发 RDP 端口（例如转发服务器的 `13389` 到本地 `13389`），然后：

| 系统    | 操作 |
|---------|------|
| Windows | 打开「远程桌面连接」，输入 `localhost:<RDP端口>`，用户名 `node`，密码为部署时设置的 `--rdp-password` |
| macOS   | 安装 [Microsoft Remote Desktop](https://apps.apple.com/app/microsoft-remote-desktop/id1295203466)，添加 PC，地址填 `localhost:<RDP端口>` |
| Linux   | `xfreerdp /v:localhost:<RDP端口> /u:node /p:<密码>` |

### 访问 OpenClaw

进入远程桌面后，打开浏览器访问：

```text
http://localhost:18789
```

输入 Gateway Token（部署时由 `launch.sh` 打印，或 `--gateway-token` 指定）即可登录。

### 使用 Chrome 调试（供 OpenClaw 控制浏览器）

容器内已安装 Google Chrome。由于容器以非特权模式运行，启动时需加 `--no-sandbox --disable-dev-shm-usage`：

```bash
google-chrome-stable --no-sandbox --disable-dev-shm-usage --remote-debugging-port=9222 --user-data-dir="/home/node/chrome-user-data"
```

并访问 `chrome://inspect#remote-debugging` 开启调试

之后与 OpenClaw 对话让它自己配置即可，如“帮你自己配置好通过 Chrome DevTools Protocol 控制我的浏览器进行操作，你可以看看你的browser工具的说明，我已经在9222端口开放了chrome”，OpenClaw 会自动识别并连接这个调试端口，后续就可以自然语言与它对话让它控制浏览器

---

## 安全说明

### 端口暴露策略

所有端口均绑定到宿主机 `127.0.0.1`，只能通过 VSCode SSH 端口转发访问，不对任何网络直接暴露：

| 端口 | 绑定方式 | 访问方式 |
|------|---------|---------|
| RDP（如 13389） | `127.0.0.1` | VSCode 端口转发后，本地 RDP 客户端连接 `localhost:<端口>` |
| Gateway（如 18789） | `127.0.0.1` | VSCode 端口转发，或在 RDP 桌面内用 `localhost` 访问 |
| Bridge（如 18790） | `127.0.0.1` | 同上 |

### 容器网络隔离

每个用户容器使用独立的 Docker bridge 网络（`openclaw-net-<username>`），默认 Docker 的 `docker0` 网桥会让所有容器互相可见，独立网络消除了这个风险。

### 已知剩余风险

| 风险           | 说明                                                                                                                        |
|----------------|-----------------------------------------------------------------------------------------------------------------------------|
| API Key 共享   | 所有容器使用同一个 `MAAS_API_KEY`，以环境变量形式存在，`docker inspect` 可见。条件允许时建议为每个用户申请独立 Key          |
| 容器内 root 进程 | xrdp、supervisord 以 root 运行，openclaw-gateway 以 node 运行。容器内 root 不等于宿主机 root，风险有限                    |

---

## 环境变量参考

| 变量名 | 说明 | 默认值 |
|--------|------|--------|
| `MAAS_API_KEY` | MaaS 平台的 API Key | 无（必填） |
| `MAAS_BASE_URL` | MaaS 服务根地址 | `https://maas-beta.tatucloud.com` |
| `OPENCLAW_GATEWAY_TOKEN` | Gateway 鉴权 Token | 自动随机生成（32字节 hex） |
| `OPENCLAW_RDP_PASSWORD` | 容器内 `node` 用户的 RDP 密码 | `openclaw`（不安全，务必覆盖） |

---

## 常用运维命令

```bash
# 查看某用户容器的实时日志
docker logs -f openclaw-alice

# 单独查看 openclaw gateway 日志
docker exec openclaw-alice tail -f /var/log/supervisor/openclaw-gateway.log

# 进入容器调试
docker exec -it openclaw-alice bash

# 检查 gateway 健康状态
docker exec openclaw-alice node /app/dist/index.js health --token <gateway_token>

# 重启容器（保留数据）
docker restart openclaw-alice

# 彻底删除容器（数据 volume 和独立网络保留）
docker rm -f openclaw-alice

# 删除容器 + 网络（完整清理）
docker rm -f openclaw-alice
docker network rm openclaw-net-alice

# 删除用户数据（不可恢复）
docker volume rm openclaw-data-alice

# 列出所有用户容器
docker ps --filter "name=openclaw-"

# 列出所有用户数据卷
docker volume ls --filter "name=openclaw-data-"

# 列出所有用户网络
docker network ls --filter "name=openclaw-net-"
```

---

## 升级 OpenClaw 版本

镜像升级不影响用户数据（数据存储在 volume 中）：

```bash
# 1. 拉取新版官方镜像并重新构建
docker pull ghcr.io/openclaw/openclaw:latest
docker build --build-arg OPENCLAW_IMAGE=ghcr.io/openclaw/openclaw:latest -f Dockerfile.rdp -t openclaw-rdp:latest .

# 2. 逐个重建用户容器（数据自动恢复）
docker rm -f openclaw-alice
./launch.sh alice --rdp-port 13389 --gateway-port 18789 --bridge-port 18790 \
  --maas-api-key <key> --rdp-password Alice@2026 --gateway-token <原token>
```

`--gateway-token` 建议复用原来的 token，避免用户重新登录 Web UI。原 token 查看方式：

```bash
docker exec openclaw-alice cat /home/node/.openclaw/openclaw.json | python3 -m json.tool | grep token
```

---

## 故障排查

### RDP 连接被拒绝（错误码 0x204）

- 在 VSCode PORTS 标签确认已转发 RDP 端口，并且连接地址是 `localhost:<端口>` 而非服务器 IP
- 检查容器是否正常运行：`docker ps --filter "name=openclaw-alice"`

### RDP 能连接但桌面黑屏 / 立即断开

- 查看 xrdp 日志：`docker exec openclaw-alice cat /var/log/xrdp.log`
- 查看 xrdp-sesman 日志：`docker exec openclaw-alice cat /var/log/xrdp-sesman.log`

### OpenClaw Web UI 无法访问

- Gateway 端口绑定在 `127.0.0.1`，必须在 RDP 桌面内用 `localhost:18789` 访问，不能从外部直接访问
- 确认 gateway 进程正常：`docker exec openclaw-alice supervisorctl status`
- 查看 gateway 日志：`docker exec openclaw-alice tail -30 /var/log/supervisor/openclaw-gateway.log`

### 模型不可用 / API 调用失败

- 确认 API Key 已传入：`docker exec openclaw-alice env | grep MAAS`
- 检查配置文件：`docker exec openclaw-alice cat /home/node/.openclaw/openclaw.json`
- 测试 MaaS 可达性：`docker exec openclaw-alice curl -sf https://maas-beta.tatucloud.com && echo OK`

### 重置某用户配置（保留工作区文件）

删除 `openclaw.json`，重启后 Python patch 会从空配置重建，等效于恢复到 onboard 后的默认状态再应用 env 参数：

```bash
docker exec openclaw-alice rm /home/node/.openclaw/openclaw.json
docker restart openclaw-alice
```

如需强制重新执行完整 onboard（重新生成 identity 密钥），还需同时清空 identity 目录：

```bash
docker exec openclaw-alice sh -c "rm /home/node/.openclaw/openclaw.json && rm -rf /home/node/.openclaw/identity/*"
docker restart openclaw-alice
```
