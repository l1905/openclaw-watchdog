#!/bin/bash
# ============================================================
# OpenClaw 看门狗 (openclaw-watchdog)
# 自动监控 OpenClaw 服务健康状态，异常时通过飞书群通知
#
# 兼容系统: macOS / Linux
# 依赖: curl, bash, crontab
#
# 用法:
#   bash openclaw-watchdog.sh install     # 交互式安装
#   bash openclaw-watchdog.sh uninstall   # 卸载
#   bash openclaw-watchdog.sh check       # 执行一次健康检查（cron 调用）
#   bash openclaw-watchdog.sh status      # 查看运行状态
#   bash openclaw-watchdog.sh test        # 发送测试通知
# ============================================================

set -uo pipefail

WATCHDOG_VERSION="1.0.0"
INSTALL_DIR="$HOME/.openclaw/watchdog"
CONF_FILE="$INSTALL_DIR/config.sh"
SCRIPT_PATH="$INSTALL_DIR/watchdog.sh"
STATE_DIR="$INSTALL_DIR/state"
LOG_FILE="$INSTALL_DIR/watchdog.log"
CRON_TAG="# openclaw-watchdog"

export PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin:$HOME/Library/pnpm:$HOME/.openclaw/bin:$PATH"

DEFAULT_PORT=18789
ALERT_COOLDOWN=300

OS_TYPE="$(uname -s)"

# ---- 颜色（自动检测终端支持） ----
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

print_banner() {
  echo ""
  echo -e "${BOLD}🤖 OpenClaw 看门狗 v${WATCHDOG_VERSION}${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

print_step() {
  echo -e "\n${BLUE}▶ $1${NC}\n"
}

print_ok() {
  echo -e "  ${GREEN}✅ $1${NC}"
}

print_warn() {
  echo -e "  ${YELLOW}⚠️  $1${NC}"
}

print_err() {
  echo -e "  ${RED}❌ $1${NC}"
}

# ---- 配置读写 ----
load_config() {
  FEISHU_WEBHOOK=""
  GATEWAY_PORT="$DEFAULT_PORT"
  OPENCLAW_LOG_DIR=""
  NOTIFY_CHAT_NAME=""
  if [ -f "$CONF_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONF_FILE"
  fi
}

save_config() {
  mkdir -p "$INSTALL_DIR"
  cat > "$CONF_FILE" <<EOF
# OpenClaw 看门狗配置（自动生成）
FEISHU_WEBHOOK='${FEISHU_WEBHOOK}'
GATEWAY_PORT='${GATEWAY_PORT}'
OPENCLAW_LOG_DIR='${OPENCLAW_LOG_DIR}'
NOTIFY_CHAT_NAME='${NOTIFY_CHAT_NAME}'
EOF
}

# ---- 平台适配：重启 Gateway ----
restart_gateway() {
  case "$OS_TYPE" in
    Darwin)
      if command -v openclaw >/dev/null 2>&1; then
        openclaw gateway restart 2>/dev/null && return 0
      fi
      local uid
      uid=$(id -u)
      launchctl kickstart -k "gui/${uid}/com.openclaw.gateway" 2>/dev/null && return 0
      return 1
      ;;
    Linux)
      systemctl restart openclaw-gateway 2>/dev/null && return 0
      if command -v openclaw >/dev/null 2>&1; then
        openclaw gateway restart 2>/dev/null && return 0
      fi
      return 1
      ;;
    *)
      if command -v openclaw >/dev/null 2>&1; then
        openclaw gateway restart 2>/dev/null && return 0
      fi
      return 1
      ;;
  esac
}

# ---- 尝试 openclaw doctor 自动修复 ----
run_doctor_fix() {
  if command -v openclaw >/dev/null 2>&1; then
    echo "[$(date '+%H:%M:%S')] 运行 openclaw doctor --non-interactive --fix"
    openclaw doctor --non-interactive --fix 2>/dev/null || true
  fi
}

# ---- 收集所有日志文件（最近 2 分钟有更新的） ----
# OpenClaw 有两套日志：
#   1. 进程日志: ~/.openclaw/logs/gateway.log, gateway.err.log（OOM 等崩溃信息）
#   2. 应用日志: /tmp/openclaw/openclaw-YYYY-MM-DD.log（billing、rate limit 等）
collect_recent_log_files() {
  local now_epoch
  now_epoch=$(date +%s)
  local candidates=()

  # 进程日志目录
  for dir in "$HOME/.openclaw/logs" "/root/.openclaw/logs"; do
    if [ -d "$dir" ]; then
      for f in "$dir"/gateway.log "$dir"/gateway.err.log; do
        [ -f "$f" ] && candidates+=("$f")
      done
    fi
  done

  # 应用日志目录（滚动日志 openclaw-YYYY-MM-DD.log）
  for dir in "/tmp/openclaw" "$HOME/.openclaw/tmp"; do
    if [ -d "$dir" ]; then
      for f in "$dir"/openclaw-*.log; do
        [ -f "$f" ] && candidates+=("$f")
      done
    fi
  done

  # 配置文件中自定义的日志目录
  if [ -n "${OPENCLAW_LOG_DIR:-}" ] && [ -d "$OPENCLAW_LOG_DIR" ]; then
    for f in "$OPENCLAW_LOG_DIR"/gateway.log "$OPENCLAW_LOG_DIR"/gateway.err.log "$OPENCLAW_LOG_DIR"/openclaw-*.log; do
      [ -f "$f" ] && candidates+=("$f")
    done
  fi

  # 过滤：只保留最近 2 分钟有更新的文件
  for f in "${candidates[@]}"; do
    local age_ok="false"
    if [ "$OS_TYPE" = "Darwin" ]; then
      local mtime
      mtime=$(stat -f %m "$f" 2>/dev/null || echo "0")
      if [ $((now_epoch - mtime)) -lt 120 ]; then
        age_ok="true"
      fi
    else
      if find "$f" -mmin -2 2>/dev/null | grep -q .; then
        age_ok="true"
      fi
    fi
    if [ "$age_ok" = "true" ]; then
      echo "$f"
    fi
  done
}

# 检测日志目录用于 install 时展示
detect_log_dirs_display() {
  local found=""
  for dir in "$HOME/.openclaw/logs" "/tmp/openclaw"; do
    if [ -d "$dir" ]; then
      if [ -n "$found" ]; then
        found="$found, $dir"
      else
        found="$dir"
      fi
    fi
  done
  echo "${found:-未找到}"
}

# ---- 飞书发消息 ----
send_feishu_card() {
  local title="$1"
  local content="$2"
  local color="${3:-red}"

  if [ -z "${FEISHU_WEBHOOK:-}" ]; then
    return 1
  fi

  local payload
  payload=$(cat <<ENDJSON
{
  "msg_type": "interactive",
  "card": {
    "header": {
      "title": {"tag": "plain_text", "content": "${title}"},
      "template": "${color}"
    },
    "elements": [
      {"tag": "markdown", "content": "${content}"}
    ]
  }
}
ENDJSON
)

  curl -s -m 10 -X POST "$FEISHU_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "$payload" > /dev/null 2>&1
}

send_feishu_text() {
  local text="$1"
  if [ -z "${FEISHU_WEBHOOK:-}" ]; then
    return 1
  fi
  curl -s -m 10 -X POST "$FEISHU_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "{\"msg_type\":\"text\",\"content\":{\"text\":\"${text}\"}}" > /dev/null 2>&1
}

# 同类告警冷却期内不重复发送
alert_once() {
  local key="$1"
  local title="$2"
  local content="$3"
  local color="${4:-red}"

  mkdir -p "$STATE_DIR"
  local flag="$STATE_DIR/alert-${key}"

  if [ -f "$flag" ]; then
    local last now
    last=$(cat "$flag")
    now=$(date +%s)
    if [ $((now - last)) -lt $ALERT_COOLDOWN ]; then
      return 1
    fi
  fi

  if send_feishu_card "$title" "$content" "$color"; then
    date +%s > "$flag"
    return 0
  fi
  return 1
}

# 清除指定告警的冷却状态
clear_alert() {
  rm -f "$STATE_DIR/alert-${1}" 2>/dev/null || true
}

# ============================================================
#  install - 交互式安装
# ============================================================
do_install() {
  print_banner

  # ---- 检测环境 ----
  print_step "第 0 步：检测环境"

  echo "  系统: $OS_TYPE"

  if command -v curl >/dev/null 2>&1; then
    print_ok "curl 已安装"
  else
    print_err "未找到 curl，请先安装 curl"
    exit 1
  fi

  if command -v crontab >/dev/null 2>&1; then
    print_ok "crontab 可用"
  else
    print_err "未找到 crontab，无法设置定时任务"
    exit 1
  fi

  if command -v openclaw >/dev/null 2>&1; then
    print_ok "OpenClaw 已安装"
  else
    print_warn "未检测到 openclaw 命令（可能安装在其他路径）"
  fi

  GATEWAY_PORT=$DEFAULT_PORT
  if curl -sf "http://127.0.0.1:$GATEWAY_PORT/healthz" > /dev/null 2>&1; then
    print_ok "Gateway 正在运行 (端口 $GATEWAY_PORT)"
  else
    print_warn "Gateway 当前未运行或端口不是 $GATEWAY_PORT"
    echo ""
    echo "  如果你的 Gateway 使用了其他端口，请输入端口号。"
    echo "  如果 Gateway 还没启动，直接回车跳过即可。"
    read -rp "  端口号 (回车使用默认 $DEFAULT_PORT): " custom_port
    GATEWAY_PORT="${custom_port:-$DEFAULT_PORT}"
  fi

  local detected_log_dirs
  detected_log_dirs=$(detect_log_dirs_display)
  if [ "$detected_log_dirs" != "未找到" ]; then
    print_ok "日志目录: $detected_log_dirs"
  else
    print_warn "未找到日志目录，日志扫描功能将在 Gateway 首次运行后生效"
  fi
  OPENCLAW_LOG_DIR="$HOME/.openclaw/logs"

  # ---- 飞书 Webhook ----
  print_step "第 1 步：设置飞书通知"

  echo "  看门狗会在机器人出问题时，通过飞书群通知你。"
  echo "  你需要在飞书群里添加一个「自定义机器人」来接收通知。"
  echo ""
  echo -e "  ${BOLD}请按以下步骤操作：${NC}"
  echo ""
  echo "  ┌──────────────────────────────────────────────────┐"
  echo "  │                                                  │"
  echo "  │  1. 打开飞书，进入你想接收通知的群               │"
  echo "  │                                                  │"
  echo "  │  2. 点右上角 ··· → 设置 → 群机器人               │"
  echo "  │                                                  │"
  echo "  │  3. 点「添加机器人」                             │"
  echo "  │                                                  │"
  echo "  │  4. 选择「自定义机器人」                         │"
  echo "  │                                                  │"
  echo "  │  5. 名字随便填（比如填「服务监控」）             │"
  echo "  │                                                  │"
  echo "  │  6. 点完成后，复制弹出的 Webhook 地址            │"
  echo "  │                                                  │"
  echo "  └──────────────────────────────────────────────────┘"
  echo ""

  FEISHU_WEBHOOK=""
  while true; do
    read -rp "  📋 请粘贴 Webhook 地址: " FEISHU_WEBHOOK

    if [ -z "$FEISHU_WEBHOOK" ]; then
      echo "  地址不能为空，请重新粘贴。"
      continue
    fi

    case "$FEISHU_WEBHOOK" in
      https://open.feishu.cn/open-apis/bot/v2/hook/*)
        break
        ;;
      https://open.larksuite.com/open-apis/bot/v2/hook/*)
        break
        ;;
      *)
        print_err "地址格式不对"
        echo "  正确格式应该以下面的地址开头："
        echo "    https://open.feishu.cn/open-apis/bot/v2/hook/..."
        echo "  请重新复制粘贴。"
        ;;
    esac
  done

  echo ""
  echo "  正在发送测试消息..."

  if send_feishu_text "✅ OpenClaw 看门狗连接成功！从现在起，机器人出问题时会在这里通知你。"; then
    print_ok "发送成功！请查看飞书群是否收到消息"
  else
    print_err "发送失败"
    echo ""
    echo "  可能的原因："
    echo "    - Webhook 地址不正确"
    echo "    - 网络无法访问飞书服务器"
    echo ""
    read -rp "  是否继续安装？(y/N) " yn
    case "$yn" in
      [Yy]*) ;;
      *) echo "  已取消。"; exit 0 ;;
    esac
  fi

  echo ""
  read -rp "  给这个通知群起个名字（方便你记忆，比如「龙虾ICU群」）: " NOTIFY_CHAT_NAME
  NOTIFY_CHAT_NAME="${NOTIFY_CHAT_NAME:-通知群}"

  # ---- 安装文件 ----
  print_step "第 2 步：安装看门狗"

  mkdir -p "$INSTALL_DIR" "$STATE_DIR"

  # 复制脚本到安装目录
  local source_script="${BASH_SOURCE[0]}"
  if [ -z "$source_script" ]; then
    source_script="$0"
  fi
  cp "$source_script" "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
  print_ok "脚本已安装到 $SCRIPT_PATH"

  save_config
  print_ok "配置已保存到 $CONF_FILE"

  # ---- 设置 cron ----
  print_step "第 3 步：设置定时检查"

  # 移除旧条目
  local existing_cron
  existing_cron=$(crontab -l 2>/dev/null || true)
  local new_cron
  new_cron=$(echo "$existing_cron" | grep -v "$CRON_TAG" || true)

  local path_line="PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:$HOME/.local/bin:$HOME/Library/pnpm:$HOME/.openclaw/bin"

  # 写入新的 cron
  {
    echo "$new_cron"
    echo "${path_line} ${CRON_TAG}"
    echo "* * * * * ${SCRIPT_PATH} check >> ${LOG_FILE} 2>&1 ${CRON_TAG}"
  } | crontab -

  print_ok "定时任务已添加（每分钟检查一次）"

  # macOS cron 权限提示
  if [ "$OS_TYPE" = "Darwin" ]; then
    echo ""
    print_warn "macOS 提示：首次运行 cron 时，系统可能弹窗请求「完全磁盘访问权限」"
    echo "  如果弹出，请点「允许」，否则 cron 无法正常工作。"
  fi

  # ---- 完成 ----
  echo ""
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}  🎉 安装完成！${NC}"
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo "  看门狗每分钟检查一次 OpenClaw 运行状态。"
  echo "  发现问题时，「${NOTIFY_CHAT_NAME}」飞书群会收到通知。"
  echo ""
  echo "  常用命令："
  echo "    查看状态:   ${SCRIPT_PATH} status"
  echo "    发测试通知: ${SCRIPT_PATH} test"
  echo "    查看日志:   tail -50 ${LOG_FILE}"
  echo "    卸载:       ${SCRIPT_PATH} uninstall"
  echo ""
}

# ============================================================
#  uninstall - 卸载
# ============================================================
do_uninstall() {
  print_banner
  echo "  正在卸载看门狗..."
  echo ""

  # 移除 cron
  local existing_cron
  existing_cron=$(crontab -l 2>/dev/null || true)
  local new_cron
  new_cron=$(echo "$existing_cron" | grep -v "$CRON_TAG" || true)
  echo "$new_cron" | crontab - 2>/dev/null || true
  print_ok "定时任务已移除"

  # 删除文件
  if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    print_ok "安装目录已清理 ($INSTALL_DIR)"
  fi

  echo ""
  echo "  ✅ 卸载完成。飞书群将不再收到监控通知。"
  echo ""
}

# ============================================================
#  check - 执行一次健康检查（cron 每分钟调用）
# ============================================================
do_check() {
  load_config

  if [ -z "$FEISHU_WEBHOOK" ]; then
    echo "[$(date '+%H:%M:%S')] 未配置 Webhook，跳过"
    exit 0
  fi

  local health_url="http://127.0.0.1:${GATEWAY_PORT}"

  # ---- 检查1: Gateway 是否存活 ----
  if ! curl -sf -m 5 "$health_url/healthz" > /dev/null 2>&1; then
    # 第一次失败，等 15 秒重试，避免误报
    sleep 15
    if ! curl -sf -m 5 "$health_url/healthz" > /dev/null 2>&1; then
      echo "[$(date '+%H:%M:%S')] Gateway 不可达，尝试重启"

      if restart_gateway; then
        # 等待重启完成
        sleep 30
        if curl -sf -m 5 "$health_url/healthz" > /dev/null 2>&1; then
          # 重启后跑 doctor 清理残留状态（session 锁、配置迁移等）
          run_doctor_fix
          alert_once "down" \
            "🔄 机器人已自动重启" \
            "机器人服务刚才短暂中断，**已自动恢复**。\n\n请等待 1-2 分钟后再试。如果仍然不能用，请联系管理员。" \
            "green"
          echo "[$(date '+%H:%M:%S')] 重启成功"
        else
          alert_once "down" \
            "🚨 机器人服务中断" \
            "机器人服务出了问题，自动重启**未能恢复**。\n\n**请联系管理员检查服务器。**\n\n可以把这条消息截图发给负责运维的同事。"
          echo "[$(date '+%H:%M:%S')] 重启后仍不可达"
        fi
      else
        alert_once "down" \
          "🚨 机器人服务中断" \
          "机器人服务无法访问，且自动重启失败。\n\n**请联系管理员检查服务器。**"
        echo "[$(date '+%H:%M:%S')] 重启命令失败"
      fi
      return
    fi
  fi

  # Gateway 恢复后清除 down 告警
  clear_alert "down"

  # ---- 检查2: 通道是否就绪 ----
  local readyz_resp
  readyz_resp=$(curl -sf -m 5 "$health_url/readyz" 2>/dev/null || echo "")

  if echo "$readyz_resp" | grep -q '"ready":false'; then
    # 先尝试 doctor 修复（可能是 session 锁残留或配置不一致）
    run_doctor_fix
    sleep 10
    # 修复后再检查一次
    readyz_resp=$(curl -sf -m 5 "$health_url/readyz" 2>/dev/null || echo "")
    if echo "$readyz_resp" | grep -q '"ready":false'; then
      alert_once "channel" \
        "⚠️ 机器人通道异常" \
        "飞书通道连接可能断开了。\n\n系统已尝试自动修复但未恢复。如果超过 5 分钟仍不能用，请联系管理员。" \
        "orange"
      echo "[$(date '+%H:%M:%S')] 通道不就绪（doctor 修复后仍异常）"
    else
      echo "[$(date '+%H:%M:%S')] 通道异常已通过 doctor 自动修复"
      clear_alert "channel"
    fi
  else
    clear_alert "channel"
  fi

  # ---- 检查3: 扫描最近日志 ----
  # 收集所有最近有更新的日志文件，合并最后 200 行进行匹配
  local recent=""
  local log_files
  log_files=$(collect_recent_log_files)

  if [ -z "$log_files" ]; then
    echo "[$(date '+%H:%M:%S')] 检查完成"
    return
  fi

  while IFS= read -r log_file; do
    local chunk
    chunk=$(tail -200 "$log_file" 2>/dev/null || true)
    if [ -n "$chunk" ]; then
      recent="${recent}${chunk}"$'\n'
    fi
  done <<< "$log_files"

  if [ -z "$recent" ]; then
    echo "[$(date '+%H:%M:%S')] 检查完成"
    return
  fi

  # 3a: API 余额不足 / 账单问题
  if echo "$recent" | grep -qi \
    'billing\|insufficient.*credit\|insufficient.*balance\|quota.*exceeded\|exceeded.*quota'; then
    alert_once "billing" \
      "⚠️ AI 服务额度不足" \
      "机器人使用的 AI 服务**余额不足**，暂时无法回复消息。\n\n**请联系管理员操作：**\n1. 登录 AI 服务商后台（如 OpenAI、DeepSeek 等）\n2. 查看 API Key 的余额\n3. 充值后机器人会自动恢复\n\n不知道找谁？请把这条消息截图发给领导。"
    echo "[$(date '+%H:%M:%S')] 检测到 billing 错误"
  fi

  # 3b: API 限流
  if echo "$recent" | grep -qi 'rate.limit\|too many requests'; then
    alert_once "ratelimit" \
      "⏳ 机器人暂时繁忙" \
      "AI 服务请求量过大，触发了限流保护。\n\n**不需要任何操作**，通常几分钟后会自动恢复。\n\n如果超过 10 分钟仍然不能用，请联系管理员。" \
      "orange"
    echo "[$(date '+%H:%M:%S')] 检测到 rate limit"
  fi

  # 3c: 内存溢出
  if echo "$recent" | grep -qi \
    'heap.*out.*memory\|FATAL ERROR.*allocation\|JavaScript heap\|process out of memory'; then
    echo "[$(date '+%H:%M:%S')] 检测到内存溢出，尝试重启"
    restart_gateway || true
    sleep 15
    # OOM 可能导致状态文件写到一半损坏，用 doctor 清理
    run_doctor_fix
    alert_once "oom" \
      "🔄 机器人内存不足，已自动重启" \
      "机器人因内存不足已自动重启。\n\n如果这个问题**经常出现**，请联系管理员：\n- 增加服务器内存\n- 或减少同时使用的人数"
    echo "[$(date '+%H:%M:%S')] OOM 重启及 doctor 修复完成"
  fi

  # 3d: 飞书授权 / 凭证问题
  if echo "$recent" | grep -qi \
    'app_ticket.*invalid\|token.*expired\|credential.*invalid\|99991672\|tenant_access_token.*fail'; then
    alert_once "auth" \
      "🔑 飞书应用授权异常" \
      "机器人的飞书应用凭证可能有问题。\n\n**请管理员操作：**\n1. 打开[飞书开放平台](https://open.feishu.cn)\n2. 找到机器人对应的应用\n3. 检查 App ID 和 App Secret 是否正确\n4. 确认应用已发布并启用\n\n不确定怎么操作？把这条消息截图发给技术同事。"
    echo "[$(date '+%H:%M:%S')] 检测到飞书授权问题"
  fi

  # 3e: API Key 无效 / 认证失败
  if echo "$recent" | grep -qi \
    'invalid.*api.key\|api.key.*invalid\|Incorrect API key\|authentication.*failed\|401.*unauthorized'; then
    alert_once "apikey" \
      "🔑 AI 服务 API Key 无效" \
      "机器人使用的 AI 服务 API Key **已失效或被删除**。\n\n**请联系管理员：**\n1. 登录 AI 服务商后台\n2. 检查 API Key 是否仍然有效\n3. 如果 Key 被删除，需要重新创建并更新配置\n\n使用命令更新：\n\`openclaw config set ai.apiKey 新的Key\`"
    echo "[$(date '+%H:%M:%S')] 检测到 API Key 无效"
  fi

  # 3f: 模型服务不可用
  if echo "$recent" | grep -qi \
    'overloaded_error\|service.*unavailable\|503.*service\|model.*overloaded'; then
    alert_once "overloaded" \
      "⏳ AI 服务暂时不可用" \
      "AI 服务商的服务器当前过载或维护中。\n\n**不需要任何操作**，通常会在几分钟到几小时内恢复。\n\n如果持续超过 1 小时，可以联系管理员考虑切换其他 AI 服务。" \
      "orange"
    echo "[$(date '+%H:%M:%S')] 检测到模型服务不可用"
  fi

  # 3g: 上下文溢出（对话太长，模型无法处理）
  if echo "$recent" | grep -qi \
    'context.overflow\|context_length_exceeded\|prompt.*too.*large\|request_too_large\|上下文过长\|上下文超出\|上下文长度超\|exceeds.*model.*context\|maximum context length'; then
    alert_once "context" \
      "📏 对话内容过长" \
      "有用户的对话内容太长，超出了 AI 模型的处理限制，导致无法回复。\n\n**用户可以这样解决：**\n发送 \`/reset\` 命令清理对话历史，然后重新开始对话。\n\n如果这个问题频繁出现，可以联系管理员切换到支持更长上下文的模型。" \
      "orange"
    echo "[$(date '+%H:%M:%S')] 检测到上下文溢出"
  fi

  # 3h: 网络连接问题（调用模型 API 失败）
  if echo "$recent" | grep -qi \
    'ECONNRESET\|ECONNREFUSED\|ETIMEDOUT\|socket hang up\|fetch failed\|network error\|network request failed'; then
    alert_once "network" \
      "🌐 网络连接异常" \
      "机器人无法连接到 AI 服务，可能是**网络问题**。\n\n通常会自动恢复。如果超过 10 分钟仍然不能用，请联系管理员检查：\n- 服务器的网络连接是否正常\n- 是否需要配置代理\n- AI 服务商是否有区域性故障" \
      "orange"
    echo "[$(date '+%H:%M:%S')] 检测到网络连接问题"
  fi

  # 3i: 模型不存在 / 不可用
  if echo "$recent" | grep -qi \
    'model.*not.*found\|model_not_available\|model.*does not exist\|does not exist.*model\|model.*not.*available\|model.*decommissioned'; then
    alert_once "model" \
      "🤖 AI 模型不可用" \
      "配置的 AI 模型**不存在或已下线**，机器人暂时无法回复。\n\n**请联系管理员：**\n1. 检查当前配置的模型名称是否正确\n2. 在 AI 服务商后台确认模型是否仍可用\n3. 如需更换模型，使用命令：\n\`openclaw config set ai.model 新模型名\`"
    echo "[$(date '+%H:%M:%S')] 检测到模型不可用"
  fi

  echo "[$(date '+%H:%M:%S')] 检查完成"
}

# ============================================================
#  status - 查看当前状态
# ============================================================
do_status() {
  print_banner
  load_config

  if [ ! -f "$CONF_FILE" ]; then
    print_err "看门狗未安装"
    echo ""
    echo "  请先运行: bash $0 install"
    echo ""
    return
  fi

  echo "  配置信息："
  echo "    通知群:     ${NOTIFY_CHAT_NAME:-未设置}"
  if [ -n "$FEISHU_WEBHOOK" ]; then
    echo "    Webhook:    ${FEISHU_WEBHOOK:0:55}..."
  else
    echo "    Webhook:    未设置"
  fi
  echo "    Gateway端口: ${GATEWAY_PORT:-$DEFAULT_PORT}"
  echo "    日志目录:    ${OPENCLAW_LOG_DIR:-未设置}"
  echo ""

  echo "  运行状态："

  # 检查 cron
  if crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
    print_ok "定时任务: 运行中（每分钟检查）"
  else
    print_err "定时任务: 未配置"
  fi

  # 检查 Gateway
  local port="${GATEWAY_PORT:-$DEFAULT_PORT}"
  if curl -sf -m 3 "http://127.0.0.1:$port/healthz" > /dev/null 2>&1; then
    print_ok "Gateway:  正常运行"
  else
    print_err "Gateway:  不可达"
  fi

  # 检查通道就绪
  local readyz_resp
  readyz_resp=$(curl -sf -m 3 "http://127.0.0.1:$port/readyz" 2>/dev/null || echo "")
  if echo "$readyz_resp" | grep -q '"ready":true'; then
    print_ok "通道:     就绪"
  elif echo "$readyz_resp" | grep -q '"ready":false'; then
    print_err "通道:     异常"
  else
    print_warn "通道:    无法检测"
  fi

  # 看门狗日志
  if [ -f "$LOG_FILE" ]; then
    local log_size
    log_size=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')
    echo ""
    echo "  看门狗日志: ${LOG_FILE} (${log_size} bytes)"
  fi

  # 最近告警
  echo ""
  echo "  最近告警："
  local has_alert=false
  if [ -d "$STATE_DIR" ]; then
    for f in "$STATE_DIR"/alert-*; do
      [ -f "$f" ] || continue
      has_alert=true
      local key last now ago label
      key=$(basename "$f" | sed 's/alert-//')
      last=$(cat "$f")
      now=$(date +%s)
      ago=$((now - last))

      # 告警类型翻译
      case "$key" in
        down)       label="服务中断" ;;
        channel)    label="通道异常" ;;
        billing)    label="余额不足" ;;
        ratelimit)  label="API限流" ;;
        oom)        label="内存溢出" ;;
        auth)       label="飞书授权" ;;
        apikey)     label="API Key" ;;
        overloaded) label="服务过载" ;;
        context)    label="上下文溢出" ;;
        network)    label="网络异常" ;;
        model)      label="模型不可用" ;;
        *)          label="$key" ;;
      esac

      if [ $ago -lt 60 ]; then
        echo "    ⚡ ${label}: ${ago} 秒前"
      elif [ $ago -lt 3600 ]; then
        echo "    ⚡ ${label}: $((ago / 60)) 分钟前"
      elif [ $ago -lt 86400 ]; then
        echo "    ⚡ ${label}: $((ago / 3600)) 小时前"
      else
        echo "    ⚡ ${label}: $((ago / 86400)) 天前"
      fi
    done
  fi
  if [ "$has_alert" = "false" ]; then
    echo "    （无告警，一切正常 ✨）"
  fi
  echo ""
}

# ============================================================
#  test - 发送测试通知
# ============================================================
do_test() {
  load_config

  if [ -z "$FEISHU_WEBHOOK" ]; then
    print_err "看门狗未安装或未配置 Webhook"
    echo ""
    echo "  请先运行: bash $0 install"
    exit 1
  fi

  echo "  正在发送测试通知到「${NOTIFY_CHAT_NAME:-通知群}」..."

  if send_feishu_card \
    "🔔 看门狗测试通知" \
    "这是一条测试消息，说明看门狗运行正常。\n\n当前时间: $(date '+%Y-%m-%d %H:%M:%S')\n系统: ${OS_TYPE}" \
    "blue"; then
    print_ok "测试消息已发送，请查看飞书群"
  else
    print_err "发送失败，请检查网络连接和 Webhook 地址"
  fi
}

# ============================================================
#  主入口
# ============================================================
case "${1:-}" in
  install)
    do_install
    ;;
  uninstall)
    do_uninstall
    ;;
  check)
    do_check
    ;;
  status)
    do_status
    ;;
  test)
    do_test
    ;;
  version|-v|--version)
    echo "openclaw-watchdog v${WATCHDOG_VERSION}"
    ;;
  *)
    echo ""
    echo "🤖 OpenClaw 看门狗 v${WATCHDOG_VERSION}"
    echo ""
    echo "用法: bash $0 <命令>"
    echo ""
    echo "命令:"
    echo "  install      交互式安装（首次使用运行这个）"
    echo "  uninstall    卸载看门狗"
    echo "  status       查看运行状态和最近告警"
    echo "  test         发送一条测试通知到飞书群"
    echo "  check        执行一次健康检查（通常由 cron 自动调用）"
    echo "  version      显示版本号"
    echo ""
    echo "首次使用请运行:"
    echo "  bash $0 install"
    echo ""
    ;;
esac
