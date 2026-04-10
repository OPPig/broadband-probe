# 📡 Broadband Probe

多出口网络质量监控系统（Docker + macvlan + Zabbix）

> 通过多路探测头检测不同 ISP 出口的延迟、丢包、DNS 解析、HTTP 可用性等指标，对接 Zabbix 实现自动发现与告警。

---

## ⚡ 快速开始

### 0. 前置要求

| 依赖 | 说明 |
| :--- | :--- |
| Docker | 宿主机已安装 Docker |
| Python 3 | 宿主机已有 |
| `pyyaml` | 宿主机依赖：`pip3 install pyyaml` |
| Zabbix Server | 接收探测数据（可选，不影响本地测试） |

### 1. 克隆

```bash
git clone https://github.com/OPPig/broadband-probe.git
cd broadband-probe
```

### 2. 初始化配置文件

```bash
cp config/global.example.yaml config/global.yaml
cp inventory/networks.example.csv  inventory/networks.csv
cp inventory/probes.example.csv     inventory/probes.csv
cp inventory/probe_targets.example.csv inventory/probe_targets.csv
cp inventory/targets_special.example.csv inventory/targets_special.csv
```

### 3. 修改配置

```bash
vim config/global.yaml           # Zabbix 服务器地址、探测间隔
vim inventory/networks.csv       # 仅 macvlan 模式需要
vim inventory/probes.csv          # 核心：探针列表
vim inventory/probe_targets.csv  # 探测目标（可选，见下方说明）
vim inventory/targets_special.csv # 每台主机的专属目标（可选）
```

### 4. （可选）手动构建镜像

```bash
cd image
docker build -t broadband-probe:latest .
cd ..
```

> 默认情况下，`./deploy.sh` 会自动构建镜像并自动注入宿主机 `UID/GID`，一般无需手动执行此步骤。
>
> 如需手动构建并对齐宿主机权限，可在构建时指定 UID/GID：

```bash
cd image
docker build \
  --build-arg PROBE_UID=$(id -u) \
  --build-arg PROBE_GID=$(id -g) \
  --build-arg APK_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/alpine \
  -t broadband-probe:latest .
cd ..
```

> 如你所在网络访问 Alpine 默认源较慢，可通过 `APK_MIRROR` 指定更快镜像源。

### 5. 部署

```bash
./deploy.sh
```

可选环境变量：

```bash
# 跳过自动构建镜像（例如 CI 已提前构建）
SKIP_IMAGE_BUILD=1 ./deploy.sh

# 手动指定容器内 probe 用户 UID/GID（默认取本机 id -u / id -g）
PROBE_UID=1001 PROBE_GID=1001 ./deploy.sh

# 构建时指定 Alpine 软件源镜像（用于加速 apk 安装）
APK_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/alpine ./deploy.sh
```

### 6. 一键卸载

```bash
./uninstall.sh
```

可选参数：

```bash
# 同时删除 generated/ 与 instances/
./uninstall.sh --purge-files

# 同时删除探针镜像（读取 global.yaml 中 docker.image）
./uninstall.sh --remove-image
```

---

## 🌐 网络模式说明

本项目支持两种网络模式，可同时使用：

### 🟢 macvlan（多线路推荐）

用于模拟真实 ISP 出口路径，每个容器有独立 IP 和网关。

```
容器 (独立IP) ── VLAN ── 运营商网关
```

特点：独立 IP / 独立网关 / 真实出口路径

### 🔵 host（本机出口）

直接使用宿主机默认网络，无需 VLAN 配置。

特点：使用宿主机默认出口 / 无需 VLAN / 适合做基准对比

---

## 🧾 配置说明

### `global.yaml`（必填）

```yaml
zabbix:
  server: 1.1.8.10       # Zabbix Server 地址
  port: 10051             # Zabbix Agent 端口

docker:
  image: broadband-probe:latest

probe:
  interval: 60            # 探测间隔（秒）
  discovery_interval: 300 # Zabbix LLD 发现间隔（秒）
  concurrency: 4          # 每类探测的并发数（建议 2~10）
```

### `networks.csv`（仅 macvlan 模式）

```csv
network_name,vlan_id,parent_if,subnet,gateway
macvlan-100,100,eth0,192.168.100.0/24,192.168.100.1
```

> ⚠️ `parent_if` 必须是宿主机上真实存在的网卡名称。

### `probes.csv`（核心）

```csv
name,zbx_host,checks,public_ip_url,network_mode,network_name,ip,dns_servers
probe-ct,Probe-CT,"mtr dns http publicip",https://4.ipw.cn,macvlan,macvlan-100,192.168.100.10,223.5.5.5
probe-cu,Probe-CU,"mtr dns http",https://4.ipw.cn,macvlan,macvlan-200,192.168.200.10,119.29.29.29
probe-local,Probe-LOCAL,"http dns publicip",https://4.ipw.cn,host,,,223.5.5.5
```

| 字段 | 说明 |
| :--- | :--- |
| `name` | 容器名称，同一文件中唯一 |
| `zbx_host` | Zabbix 主机名，需与 Zabbix Web UI 中的主机名一致 |
| `checks` | 启用的探测模块，空格分隔：`mtr dns http tcp publicip` |
| `network_mode` | `macvlan` 或 `host` |
| `network_name` | macvlan 模式必填，对应 `networks.csv` 中的 `network_name` |
| `ip` | macvlan 模式必填，需在对应 subnet 范围内 |
| `dns_servers` | DNS 服务器 IP，多个用逗号分隔 |

### `probe_targets.csv`（探测目标）

```csv
probe_name,module,target,id,label,extra
probe-ct,mtr,223.5.5.5,ali-anycast,阿里Anycast,
probe-ct,dns,223.5.5.5,ali-dns,阿里DNS,www.baidu.com
probe-ct,http,https://www.baidu.com/,baidu-home,百度官网,
```

| 字段 | 说明 |
| :--- | :--- |
| `probe_name` | 必须在 `probes.csv` 中存在 |
| `module` | `mtr` / `dns` / `http` / `tcp` |
| `target` | 探测目标（IP / 域名 / URL） |
| `id` | 唯一标识符，英文，用于 Zabbix item key |
| `label` | 显示名称，中文，用于 Zabbix 发现规则 |
| `extra` | DNS 模块专用，填写待解析域名 |

> ⚠️ 如果存在 `targets_template.csv`，则每次运行 `generate_configs.py` 时会**自动覆盖** `probe_targets.csv`。如需手动管理目标，请确认已删除或备份模板文件。

### `targets_special.csv`（每台主机专属目标，可选）

当你同时使用 `targets_template.csv` 时，模板会给所有启用了对应模块的 probe 生成“公共目标”；而 `targets_special.csv` 只会为指定 `probe_name` 追加专属目标。

```csv
probe_name,module,target,id,label,extra
probe-ct,tcp,1.1.1.1:443,cloudflare-443,Cloudflare443,
probe-local,http,https://ip.sb/,ip-sb-home,IP.SB,
```

说明：

- 表头必须是：`probe_name,module,target,id,label,extra`
- `probe_name` 必须在 `probes.csv` 中存在
- `module` 仅支持 `mtr/dns/http/tcp`
- `dns` 模块必须填写 `extra`（待解析域名）
- 其他模块 `extra` 留空即可

> ✅ 生成逻辑：`probe_targets.csv = targets_template.csv(公共目标) + targets_special.csv(主机专属目标)`

---

## 📊 支持的探测类型

| 类型 | 说明 | Zabbix Key 示例 |
| :--- | :--- | :--- |
| `mtr` | 延迟 / 丢包 / 抖动 | `net.loss[{#MTRID}]`、`net.latency[{#MTRID}]` |
| `dns` | DNS 解析可用性 | `dns.status[{#DNSID}]` |
| `http` | HTTP 可用性与响应时间 | `http.time[{#HTTPID}]` |
| `tcp` | TCP 端口连通性 | `tcp.status[{#TCPID}]` |
| `publicip` | 公网出口 IP | `net.publicip` |

---

## 🚀 并发探测（避免目标过多导致单周期跑不完）

当前版本支持同一模块内并发探测（`mtr/dns/http/tcp`），默认并发数来自 `global.yaml`：

```yaml
probe:
  concurrency: 4
```

你也可以在实例 `probe.env` 中按模块覆盖：

```bash
HTTP_CONCURRENCY=8
DNS_CONCURRENCY=6
TCP_CONCURRENCY=10
MTR_CONCURRENCY=2
```

未设置模块并发时，回退到 `PROBE_CONCURRENCY`。

---

## 🔍 Zabbix 模板

自动发现规则（LLD）：

```
mtr.discovery
dns.discovery
http.discovery
tcp.discovery
```

容器首次启动时会自动上报所有探测目标的发现数据，在 Zabbix Web UI 中链接对应模板即可。

---

## 🔒 安全设计

- **配置与代码分离**：所有 IP、密码、Token 均在运行时挂载，不写入镜像
- **非 root 运行**：容器以 `probe` 用户身份运行（UID 1000）
- **只读挂载**：配置文件以 `ro` 模式挂入容器

---

## 🛠 常见问题

### ❌ 容器内无法访问外网

```bash
# 检查 VLAN 网卡是否正常
ip link show eth0.100

# 检查 macvlan 网络是否存在
docker network ls | grep macvlan

# 检查网关是否可达
docker exec probe-ct ping -c 3 192.168.100.1
```

### ❌ Zabbix 无数据

- 确认 `probes.csv` 中的 `zbx_host` 与 Zabbix Web UI 中的主机名完全一致
- 确认 Zabbix 模板已正确绑定到该主机
- 确认 Zabbix Server 能访问到容器的 `ZBX_PORT`（默认 10051）

### ❌ MTR 不显示任何节点

- 检查 `probe_targets.csv` 中该 probe 是否有 `module=mtr` 的目标
- 检查 `id` 是否在同一 probe 内重复
- 查看容器日志：`docker logs probe-ct`

### ❌ 挂载配置目录权限不足（使用非 root 运行后）

- 容器内进程默认以 `probe` 用户运行，不要求宿主机存在同名用户。
- 但挂载目录的文件权限必须允许该 UID/GID 访问。
- 可使用以下方式之一解决：
  - 重新构建镜像时通过 `--build-arg PROBE_UID/PROBE_GID` 对齐宿主机用户；
  - 或手动调整宿主机挂载目录权限（如 `chown/chmod`）。

### ❌ 部署脚本报错 "command not found: python3"

宿主机需要安装 Python 3：

```bash
# Ubuntu/Debian
sudo apt install python3 python3-pip

# 安装 YAML 支持
pip3 install pyyaml
```

### ❓ Codex 提示“请创建新的拉取请求（PR）”

- 这通常表示当前会话无法继续更新一个在外部创建/管理的旧 PR。
- 处理方式：在当前分支继续提交，然后创建一个新的 PR（标题可标注 `v2` / `follow-up`）。
- 建议在新 PR 描述中附上“替代旧 PR 链接”，方便审阅关联。

---

## 🧭 Roadmap

- [ ] Web UI（可视化配置管理）
- [ ] SLA 报表导出
- [ ] Grafana + Prometheus 支持
- [ ] 自动 Zabbix 模板生成
- [ ] IPv6 支持
- [ ] 探测目标健康度评分

---

## 📄 License

MIT License
