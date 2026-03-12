# OpenClaw 看门狗 使用指南

自动监控 OpenClaw 服务运行状态，出现问题时通过飞书群通知。

## 功能

| 故障类型 | 自动处理 | 飞书通知内容 |
|---------|---------|-------------|
| 服务崩溃 / 进程挂了 | ✅ 自动重启 + doctor 修复 | "机器人已自动重启，请等 1-2 分钟" |
| 内存不足 (OOM) | ✅ 自动重启 + doctor 修复 | "内存不足，已重启。频繁出现请加内存" |
| 飞书通道断连 | ✅ 先 doctor 修复，再等待恢复 | 修好了无通知；修不好则 "通道异常，请联系管理员" |
| 配置损坏 / 状态不一致 | ✅ doctor 自动修复 | 静默修复，不打扰用户 |
| AI 服务余额不足 | ❌ 需人工处理 | "余额不足，请管理员充值"（附操作步骤） |
| AI 服务限流 | ⏳ 自动恢复 | "暂时繁忙，几分钟后自动恢复，不需要操作" |
| AI 服务过载 | ⏳ 自动恢复 | "服务暂时不可用，通常会自动恢复" |
| 对话上下文过长 | ℹ️ 提示用户操作 | "对话太长了，请发 /reset 清理历史后重新开始" |
| 网络连接异常 | ⏳ 通常自动恢复 | "无法连接 AI 服务，检查网络" |
| AI 模型不可用 | ❌ 需人工处理 | "模型不存在或已下线，请管理员更换"（附操作步骤） |
| API Key 失效 | ❌ 需人工处理 | "API Key 无效，请管理员更换"（附操作步骤） |
| 飞书授权过期 | ❌ 需人工处理 | "飞书授权异常，请管理员重新授权"（附操作步骤） |
| 自动重启失败 | ❌ 需人工处理 | "服务中断，自动重启未成功，请联系管理员" |

## 系统要求

- macOS 或 Linux
- 已安装 `curl`（通常已内置）
- 已安装并运行 OpenClaw

## 安装（3 步，约 3 分钟）

### 第 1 步：下载脚本

```bash
# 进入任意目录
curl -O https://你的地址/openclaw-watchdog.sh
```

或者直接复制 `scripts/openclaw-watchdog.sh` 到服务器上。

### 第 2 步：运行安装

```bash
bash openclaw-watchdog.sh install
```

安装过程中，脚本会：
1. 自动检测系统环境和 OpenClaw 运行状态
2. 引导你在飞书群里创建一个通知机器人（有详细步骤说明）
3. 你只需要把飞书里的 Webhook 地址复制粘贴进来
4. 脚本会自动发一条测试消息确认连接成功
5. 自动配置定时检查任务（每分钟检查一次）

### 第 3 步：没有第 3 步

安装完成后，看门狗会自动运行。你不需要做任何其他操作。

## 安装过程演示

```
$ bash openclaw-watchdog.sh install

🤖 OpenClaw 看门狗 v1.0.0
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

▶ 第 0 步：检测环境

  系统: Linux
  ✅ curl 已安装
  ✅ crontab 可用
  ✅ OpenClaw 已安装
  ✅ Gateway 正在运行 (端口 18789)
  ✅ 日志目录: /root/.openclaw/logs

▶ 第 1 步：设置飞书通知

  看门狗会在机器人出问题时，通过飞书群通知你。
  你需要在飞书群里添加一个「自定义机器人」来接收通知。

  请按以下步骤操作：

  ┌──────────────────────────────────────────────────┐
  │                                                  │
  │  1. 打开飞书，进入你想接收通知的群               │
  │                                                  │
  │  2. 点右上角 ··· → 设置 → 群机器人               │
  │                                                  │
  │  3. 点「添加机器人」                             │
  │                                                  │
  │  4. 选择「自定义机器人」                         │
  │                                                  │
  │  5. 名字随便填（比如填「服务监控」）             │
  │                                                  │
  │  6. 点完成后，复制弹出的 Webhook 地址            │
  │                                                  │
  └──────────────────────────────────────────────────┘

  📋 请粘贴 Webhook 地址: https://open.feishu.cn/open-apis/bot/v2/hook/xxxx

  正在发送测试消息...
  ✅ 发送成功！请查看飞书群是否收到消息

  给这个通知群起个名字（方便你记忆，比如「运维群」）: 运维群

▶ 第 2 步：安装看门狗

  ✅ 脚本已安装到 /root/.openclaw/watchdog/watchdog.sh
  ✅ 配置已保存到 /root/.openclaw/watchdog/config.sh

▶ 第 3 步：设置定时检查

  ✅ 定时任务已添加（每分钟检查一次）

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  🎉 安装完成！
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  看门狗每分钟检查一次 OpenClaw 运行状态。
  发现问题时，「运维群」飞书群会收到通知。

  常用命令：
    查看状态:   /root/.openclaw/watchdog/watchdog.sh status
    发测试通知: /root/.openclaw/watchdog/watchdog.sh test
    查看日志:   tail -50 /root/.openclaw/watchdog/watchdog.log
    卸载:       /root/.openclaw/watchdog/watchdog.sh uninstall
```

## 日常使用

安装后**不需要任何日常操作**。以下命令供需要时使用：

### 查看看门狗状态

```bash
~/.openclaw/watchdog/watchdog.sh status
```

输出示例：

```
🤖 OpenClaw 看门狗 v1.0.0
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  配置信息：
    通知群:     运维群
    Webhook:    https://open.feishu.cn/open-apis/bot/v2/hook/xxxxx...
    Gateway端口: 18789
    日志目录:    /root/.openclaw/logs

  运行状态：
    ✅ 定时任务: 运行中（每分钟检查）
    ✅ Gateway:  正常运行
    ✅ 通道:     就绪

  最近告警：
    （无告警，一切正常 ✨）
```

### 手动发送测试通知

```bash
~/.openclaw/watchdog/watchdog.sh test
```

### 查看看门狗运行日志

```bash
tail -50 ~/.openclaw/watchdog/watchdog.log
```

### 卸载

```bash
~/.openclaw/watchdog/watchdog.sh uninstall
```

## 飞书通知效果

机器人出问题时，飞书群会收到一条卡片消息，例如：

> **⚠️ AI 服务额度不足**
>
> 机器人使用的 AI 服务**余额不足**，暂时无法回复消息。
>
> **请联系管理员操作：**
> 1. 登录 AI 服务商后台（如 OpenAI、DeepSeek 等）
> 2. 查看 API Key 的余额
> 3. 充值后机器人会自动恢复
>
> 不知道找谁？请把这条消息截图发给领导。

通知特性：
- 同类告警 **5 分钟内不会重复发送**，避免刷屏
- 问题恢复后，告警状态自动清除
- 能自动修复的问题（崩溃、OOM、配置损坏），修复后才发通知，告诉用户"已恢复"
- 通道异常时先自动运行 `openclaw doctor --fix` 尝试修复，修好了就不打扰用户

## 常见问题

### Q: 安装后飞书群没收到测试消息？

检查：
1. Webhook 地址是否正确粘贴（应以 `https://open.feishu.cn/open-apis/bot/v2/hook/` 开头）
2. 服务器是否能访问外网（`curl https://open.feishu.cn` 测试）
3. 飞书群里的自定义机器人是否还在（没被删除）

### Q: macOS 上 cron 不执行？

macOS 首次使用 cron 时，可能需要在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」中允许 `cron`。

### Q: 如何修改通知群？

重新运行安装即可，会覆盖旧配置：

```bash
bash openclaw-watchdog.sh install
```

### Q: 如何临时停止看门狗？

```bash
# 停止（移除 cron，但保留配置）
crontab -l | grep -v 'openclaw-watchdog' | crontab -

# 恢复
~/.openclaw/watchdog/watchdog.sh install
```

### Q: 看门狗自身会占用多少资源？

几乎不占：每分钟运行一次，正常情况下每次耗时不到 1 秒，内存占用可忽略。
触发 doctor 修复时会多花几秒，但只在检测到异常时才运行。

### Q: `openclaw doctor --fix` 是什么？安全吗？

这是 OpenClaw 内置的自动诊断修复命令。它会修复配置损坏、session 锁残留、
状态文件迁移等已知问题。不会删除用户数据、不会改变 AI 模型配置、不会影响
正在进行的对话。OpenClaw 自身的版本升级流程也会自动调用这个命令。

看门狗会在以下场景自动运行 doctor：
- Gateway 重启成功后（清理重启遗留的 session 锁等）
- 通道异常时（修复可能的配置不一致）
- 内存溢出重启后（修复可能损坏的状态文件）

## 文件说明

安装后的文件都在 `~/.openclaw/watchdog/` 目录下：

```
~/.openclaw/watchdog/
├── watchdog.sh      # 主脚本
├── config.sh        # 配置文件（Webhook 地址等）
├── watchdog.log     # 看门狗自身运行日志
└── state/           # 告警状态（用于去重）
    ├── alert-down
    ├── alert-billing
    └── ...
```

看门狗会扫描以下两个位置的 OpenClaw 日志：

```
~/.openclaw/logs/
├── gateway.log        # 进程日志（OOM 崩溃等）
└── gateway.err.log    # 进程错误日志

/tmp/openclaw/
└── openclaw-YYYY-MM-DD.log   # 应用日志（billing、rate limit、auth 等）
```
