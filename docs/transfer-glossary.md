# 传输域词汇表

`br push` / `br pull` 与设备 PushServer 之间传输协议的常用术语。
协议细节见 [docs/transfer-spec.md](transfer-spec.md)，术语在代码与文档中统一使用。

| 术语 | 含义 | 备注/出处 |
|---|---|---|
| PushServer | App 内 8888 端口的 TCP 服务，接收 push、响应 pull | `PushServer.ets` |
| 远端名 (remote name) | 设备侧目标相对路径，≤256 字节 | `MAX_REMOTE_NAME_BYTES` |
| fport 隧道 | `hdc fport` 把 PC 本地端口转发到设备 8888 | `hdc.py` 的 `ensure_forward` |
| 魔数 (magic) | 协议头首 u32，用于分流/识别版本 | v1 `nameLen`、v2 `RESUME_MAGIC`(BRN2)、PULL |
| payloadSize | 文件**完整**内容的字节数（u64） | 头部字段 |
| 分块 (chunk) | 客户端单次 `sendall` 的 256KiB 数据 | `PUSH_CHUNK_SIZE` |
| 流式落盘 | 服务端头部到齐即 open，`message` 事件直接 writeSync | `RecvState` 状态机 |
| `.part` | 传输中间文件；收满才原子 rename 为正式名 | 中断产物供续传 |
| 探针 (probe) | 文件头部 ≤4KiB，用于确认 `.part` 属于同一文件 | v2 头附加字段 |
| resumeFrom | 设备已落盘可复用字节数（u64），0 = 从头 | 续传协商 |
| ACK | 设备每落盘 4MiB 回一个 u64 累计已写字节 | `ACK_INTERVAL` |
| 在途上限 | 已发送未确认的字节上限，超限等待 ACK | `MAX_INFLIGHT_BYTES` |
| 续传 (resume) | 断线后从 `resumeFrom` 继续发送剩余 payload | `FLAG_RESUME` |
| ENOSPC 兜底 | 设备空间不足时写盘失败 → `fail()` 清理 fd 与 `.part` | `PushServer.ets` |
| MAX_FILE_SIZE | 单文件策略上限 4GiB，双端常量一致 | #5；见 ADR-0001 |
| `br pull` | 设备 → PC 的文件拉取，复用 8888 与 `PULL_MAGIC` 分流 | `pull.py` |
