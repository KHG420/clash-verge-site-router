# Clash Verge Site Router

把指定网站分配给指定订阅，其余流量继续使用当前主订阅的规则。

例如：GitHub 使用「开发订阅」，其他网站保持「日常订阅」的设置。工具读取 Clash Verge Rev 中已有的订阅，通过 `proxy-providers`、独立策略组和前置域名规则完成配置。使用 Ruby 标准库，运行时不需要安装额外 gem。

> **生效方式：** `add` 保存映射，`plan` 预览，`apply` 写入持久化扩展。随后在 Clash Verge 中点击 **订阅 → 重新激活订阅**，再用 `verify` 核对运行状态。`apply` 本身不负责重新加载内核。

## 适用范围

- macOS 优先，Ruby **2.6+**。已在 macOS、Clash Verge Rev **2.5.2**、Mihomo **v1.19.29** 上完成本机目录读取、只读规划和内核配置校验。
- Linux 和 Windows 提供默认目录识别，也可用 `--data-dir` 明确指定；尚未完成这些系统的真实客户端端到端验收，Windows 需要自行准备 Ruby。
- 主订阅已有独立的 `merge`、`groups`、`rules` 扩展文件，且当前运行在 **规则模式**。
- 目标为已经导入并更新过的远程订阅，本地缓存包含 `proxies` 节点列表。
- 使用系统代理或 TUN 接入 Clash Verge 的流量才会经过这些规则。工具不修改系统代理、TUN、DNS、Git 或浏览器设置。

## 快速开始

```bash
git clone https://github.com/KHG420/clash-verge-site-router.git
cd clash-verge-site-router

# 名称以你自己的订阅列表为准；重名时使用 UID
./bin/verge-router subscriptions

# GitHub 预设包括主站、API、Pages、静态资源和下载等相关域名
./bin/verge-router add github --to '开发订阅'

# 自定义域名：默认包含该域名及所有子域名
./bin/verge-router add example.com --to '备用订阅'

# 只匹配一个完整域名
./bin/verge-router add api.example.com --to '开发订阅' --exact

./bin/verge-router list
./bin/verge-router plan
./bin/verge-router apply
```

在 Clash Verge 中点击 **订阅 → 重新激活订阅**，然后执行：

```bash
./bin/verge-router verify
```

第一次添加映射时，当前启用的订阅会成为主订阅。后续切换了主订阅，工具会停止写入并提示，避免把配置应用到错误的订阅。

新增的策略组以 `网站分流 · 订阅名称 · 短编号` 命名。每个目标订阅只创建一个组，多个网站可以共用它。在 Clash Verge 的代理页面中选择该组的具体节点；组只包含对应订阅的节点。

## 修改与撤销

重新执行 `add` 可以更改网站的目标订阅：

```bash
./bin/verge-router add github --to '另一个订阅'
./bin/verge-router plan
./bin/verge-router apply
```

移除某个网站的专用分流：

```bash
./bin/verge-router remove github
./bin/verge-router apply
```

移除后，该网站重新遵循原有规则。工具只移除自己管理的条目；如果你之前手动配置过该网站，手动规则仍然保留。

恢复最近一次写入之前的配置：

```bash
./bin/verge-router backups
./bin/verge-router rollback
# 或指定 backups 输出中的一个编号
./bin/verge-router rollback 20260101-120000-0123abcd
```

每次 `apply` 或 `rollback` 后，都需要在 Clash Verge **重新激活订阅**。回滚保留网站映射文件；再次 `apply` 会按这个映射文件重新生成配置。需要永久撤销映射时，用 `remove` 加 `apply`。

## 批量配置

可以直接编辑 JSON 映射文件。文件中填写订阅名称或 UID，**无需填写订阅链接或节点密码**：

```json
{
  "version": 1,
  "base_profile": "日常订阅",
  "routes": [
    { "site": "github", "subscription": "开发订阅" },
    { "domain": "example.com", "subscription": "备用订阅" },
    { "domain": "api.example.com", "exact": true, "subscription": "开发订阅" }
  ]
}
```

```bash
cp routing.example.json routes.local.json
# 编辑 routes.local.json，将名称替换为已有订阅
./bin/verge-router plan --config routes.local.json
./bin/verge-router apply --config routes.local.json
# 在客户端重新激活订阅后，用同一个配置文件验证
./bin/verge-router verify --config routes.local.json
```

不使用 `--config` 时，映射保存在 Clash Verge 数据目录下的 `verge-router/routes.json`。使用自定义文件时，后续 `add`、`list`、`remove`、`plan`、`apply`、`verify` 都应带上同一个 `--config`。

域名使用 ASCII 或 Punycode，不含 `https://`、路径、端口或通配符。域名大小写会统一转为小写，末尾的点会被移除。更具体的子域名优先于父域名，同一域名的完整匹配优先于后缀匹配；完全相同的匹配条件不能指向两个订阅。

## 工作原理

工具按照 `profiles.yaml` 的引用关系定位主订阅的三个扩展文件：

| 扩展 | 新增内容 |
| --- | --- |
| `merge` | 每个目标订阅一个 HTTP 代理集合，直接使用本机已有订阅 URL |
| `groups` | 每个代理集合一个独立的 `select` 策略组 |
| `rules` | 位于原有规则之前的网站域名规则 |

Clash Verge 重建运行配置时会重新合并扩展，因此主订阅更新后映射仍然存在。目标集合每 24 小时独立更新，使用已有订阅的自定义 User-Agent（如果设置了），否则使用 `clash-verge`。集合通过 `DIRECT` 获取订阅，首次加载用本地订阅缓存作为种子。

节点名称增加 `[VR:短编号]` 前缀，避免不同订阅的同名节点混淆。健康检查每 600 秒进行一次，并启用惰性检查。`select` 组保持手动选择，不会自动跨订阅切换。

GitHub 预设定义在 [presets.json](presets.json)，当前有 42 条域名规则，其中 S3 与 Azure 下载地址使用完整域名匹配，避免把整个云存储域名一起分流。预设不包含 npm 或独立的 Copilot 域名；可以另外添加它们。

## 文件、备份与冲突处理

工具数据都位于客户端的数据目录，默认路径为：

| 系统 | 默认数据目录 |
| --- | --- |
| macOS | `~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev` |
| Linux | `$XDG_CONFIG_HOME/io.github.clash-verge-rev.clash-verge-rev`，或 `~/.config/io.github.clash-verge-rev.clash-verge-rev` |
| Windows | `%APPDATA%/io.github.clash-verge-rev.clash-verge-rev` |

实际路径不同时，所有命令都可以指定：

```bash
./bin/verge-router subscriptions --data-dir '/path/to/clash-verge-data'
```

内部文件包括：

```text
verge-router/routes.json                网站映射
verge-router/state.json                 工具条目的名称和内容摘要
verge-router/backups/<编号>/             原始文件快照及写入清单
proxy_providers/verge-router/<编号>.yaml  本地节点缓存
```

- `plan` 只读取文件，不创建缓存、锁或备份，不输出订阅 URL 或节点密码。
- 写入前保存原始文件，逐文件使用临时文件和原子替换；发生可恢复的写入错误时恢复原文件。
- 如果进程在写入中被终止，后续命令会发现未完成的清单并提示 `rollback <编号>`。
- 同一个数据目录的写操作使用文件锁；写入前检查原文件摘要。该锁不能约束 Clash Verge 或其他编辑器，配置期间应避免同时编辑或更新订阅。
- 外部添加的非工具条目会保留；工具条目被外部修改、共享扩展、文件路径异常等情况会中止写入。
- 回滚前核对文件是否仍与写入后的版本一致，拒绝覆盖后续修改。
- YAML 使用语法树编辑，保留未修改值的标量含义和锚点，避免把 `off`、`on`、`yes`、`no` 误改成布尔值。**重新输出 YAML 会调整排版并丢弃注释**，备份保留原始字节，可完整恢复。
- 配置、状态、缓存和备份文件按 `0600` 写入，新建的私有目录按 `0700` 创建。缓存和备份可能含完整订阅凭证，应留在本机，不要提交到公开仓库。回滚会保留节点缓存，供再次应用时使用。

## 验证的含义与限制

`verify` 使用已有的 Unix socket 或回环 TCP 控制器，只读取运行模式、规则、策略组和代理集合。它不会打开新的控制器端口，也不会把密钥发送到远程地址。Windows 命名管道尚未支持。

验证会检查：规则模式已启用；网站规则位于预期的优先级；对应策略组已加载；所选节点属于目标订阅。**它不测试目标网站的实时 HTTP 连通性**，网站响应、账户状态、出口 IP 额度和 DNS/UDP 行为仍需另行确认。

以下情况会明确拒绝自动写入：

- 现有策略组使用 `include-all` 或 `include-all-providers`，新增集合可能使其他网站也选到新订阅。先将这些组改成明确的 `proxies`/`use`。
- 目标只有代理集合引用而没有本地 `proxies` 节点，或不是远程订阅。
- 订阅扩展被多个主配置共用，或待改写的集合字段本身是 YAML 别名。

目标订阅在 Clash Verge 内的扩展脚本、订阅转换和节点改写不会自动应用到新的 HTTP 集合。主配置的其他脚本也可能重新改写规则，因此每次重新激活后应执行 `verify`。这个版本一次管理一个主订阅。

## 开发与测试

运行时只用 Ruby 标准库。测试使用 Minitest（macOS 系统 Ruby 通常已经附带）：

```bash
ruby -Itest test/test_router.rb
```

用已安装的 Mihomo 额外验证生成配置：

```bash
MIHOMO_BIN='/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo' \
  ruby -Itest test/test_router.rb
```

测试使用临时目录和虚构订阅，自动清理自身资源。真实内核校验使用 `-t`，不会启动第二个代理服务。未指定 `MIHOMO_BIN` 时，该项集成测试会标记为跳过。

GitHub Actions 在 Ruby 3.1 和 3.3 上运行测试。本机开发验证使用 Ruby 2.6.10；测试覆盖条目增删、订阅切换、幂等性、优先级、凭证输出保护、外部改动、失败恢复、回滚和控制器读取。

## 参考

- [Clash Verge Rev：扩展配置与脚本](https://www.clashverge.dev/guide/extend.html)
- [Mihomo：代理集合](https://wiki.metacubex.one/config/proxy-providers/)
- [Mihomo：路由规则](https://wiki.metacubex.one/config/rules/)
- [v2fly/domain-list-community：GitHub 域名集合](https://github.com/v2fly/domain-list-community/blob/master/data/github)
