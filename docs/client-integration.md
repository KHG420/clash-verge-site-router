# Clash Verge Rev 客户端集成

已核对官方 `v2.5.2` 源码；以下是版本相关行为，不是承诺未来版本的私有接口保持稳定。

| 功能 | 客户端内部行为 | 本项目入口 |
| --- | --- | --- |
| 刷新单个订阅 | Tauri `update_profile` | 辅助功能定位具名订阅卡的“刷新”按钮；重名时拒绝单独自动刷新 |
| 刷新全部 | UI 逐个执行远程订阅更新 | 客户端“更新所有订阅”按钮 |
| 重新激活 | `enhance_profiles` → `update_config_forced` | 客户端“重新激活订阅”按钮 |
| 运行集合刷新 | Mihomo `PUT /providers/proxies/:name` | 客户端源资料更新后，仅更新工具管理的对应集合 |
| 核验 | Mihomo `/configs`、`/rules`、`/proxies`、`/providers/proxies` | 检查规则模式、优先级、集合成员和所选节点来源 |
| 诊断 | Mihomo `/rules`、`/connections` | 仅读取所查询域名的活动连接摘要 |

应用的 loopback HTTP `/commands/*` 和 `clash-verge:` scheme 不提供已有订阅的完整管理接口。scheme 用于导入新订阅，不能冒充刷新。工具没有调用未授权来源的 Tauri IPC，也没有自己修改客户端驻内存的订阅注册表。

macOS 桥接器只寻找准确的按钮文字。找不到、找到多个、无窗口、权限不足或超时时返回手动步骤，不使用坐标盲点、不激活别的订阅、不修改辅助功能权限。它仅作用于默认客户端数据目录；用临时目录运行测试不会误操作真实客户端。

订阅更新可能在下载失败后仍返回成功，因此使用 `updated` 变化作为成功证据。等待窗口默认 30 秒；超时的项目报告“未观察到成功”，可能仍由客户端继续更新。客户端网络或响应校验失败时保留原节点缓存。工具不把失败响应保存为节点文件。

`deploy` 先写持久化扩展，然后尝试客户端重新激活，最后读取核心核验。尚未核验通过时不会显示“已生效”；回滚后的运行状态同样需要重新激活和检查。订阅更新后，主配置的自定义脚本可能覆盖扩展，需查看核验结果。

## 官方源码依据

- [订阅命令](https://github.com/clash-verge-rev/clash-verge-rev/blob/v2.5.2/src-tauri/src/cmd/profile.rs)
- [更新与失败处理](https://github.com/clash-verge-rev/clash-verge-rev/blob/v2.5.2/src-tauri/src/feat/profile.rs)
- [配置重建与 reload/restart](https://github.com/clash-verge-rev/clash-verge-rev/blob/v2.5.2/src-tauri/src/core/manager/config.rs)
- [客户端订阅页按钮](https://github.com/clash-verge-rev/clash-verge-rev/blob/v2.5.2/src/pages/profiles.tsx)
- [客户端本地 HTTP 服务](https://github.com/clash-verge-rev/clash-verge-rev/blob/v2.5.2/src-tauri/src/utils/server.rs)
