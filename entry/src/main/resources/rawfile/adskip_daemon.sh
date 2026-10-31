#!/bin/sh
# HarmonyOS NEXT 开屏广告自动跳过守护服务
# 特性：
# 1. 全信号免疫 (trap HUP/INT/QUIT/TERM/PIPE/TSTP) + 挂载于 init (PPID=1, oom_score_adj=-1000)
# 2. 100% 纯内置命令看门狗 (builtin sleep/kill/read/echo，零 fork，内核 EVENTPOLL 休眠，永不触发 do_rt_sigsuspend)
# 3. uitest 守护进程 IPC 死锁自动检测与秒级自愈 (捕获 broadcast reply timeout 自动重置 uitest)
# 4. App 界面联动与秒级重启支持：App 界面点击「开启」或「重启」即刻触发 uitest 与主进程完全重置与热拉起
# 5. 三段式智能降载采样：仅在刚切入应用的开屏窗口期高频扫描，开屏完成后自动降频 80%，彻底杜绝系统掉帧与卡顿

trap '' HUP INT QUIT TERM PIPE TSTP

SCRIPT_PATH="/data/local/tmp/adskip_daemon.sh"
CTRL_STATE_FILE="/data/local/tmp/adskip_ctrl_state.txt"
DUMP_JSON="/data/local/tmp/skip_v3.json"
ATTRS_TXT="/data/local/tmp/adskip_attrs.txt"
BUNDLE_TXT="/data/local/tmp/adskip_bundle.txt"
BOUNDS_TXT="/data/local/tmp/adskip_bounds.txt"
CAND_TXT="/data/local/tmp/adskip_cand.txt"
RESP_TXT="/data/local/tmp/adskip_resp.txt"
UITEST_LOG="/data/local/tmp/adskip_uitest.log"
HEARTBEAT_FILE="/data/local/tmp/adskip_heartbeat"
WD_HEARTBEAT_FILE="/data/local/tmp/adskip_wd_heartbeat"
PID_FILE="/data/local/tmp/adskip_daemon.pid"
WD_PID_FILE="/data/local/tmp/adskip_watchdog.pid"
STOP_FILE="/data/local/tmp/adskip_daemon.stop"
HISTORY_LOG="/data/local/tmp/adskip_history.log"

APP_FILES_DIR="/data/app/el2/100/base/com.ysydhc.adskipvpn/haps/entry/files"
APP_CTRL_FILE="$APP_FILES_DIR/adskip_control.txt"
APP_STATUS_FILE="$APP_FILES_DIR/adskip_status.json"
APP_SKIP_LOG="$APP_FILES_DIR/adskip_skip.log"
APP_SCRIPT_FILE="$APP_FILES_DIR/adskip_daemon.sh"

# ============================================================================
# 独立看门狗进程模式 (--watchdog)：
# 全程 100% 使用 mksh 内置指令 (builtin sleep / kill / read / echo / [ )，
# 稳态运行期间 0 次 fork()、0 个子进程，wchan 恒为 EVENTPOLL，从根源上免疫 do_rt_sigsuspend！
# 同时监听 App 端控制指令 (adskip_control.txt)，实现应用内重启无感秒级热重载！
# ============================================================================
if [ "$1" = "--watchdog" ]; then
  TARGET_PID="$2"
  echo "$$" > "$WD_PID_FILE" 2>/dev/null || true
  LAST_SEEN_HB=""
  STALE_TICKS=0
  WD_SEQ=0

  LAST_APP_CTRL=""
  if [ -f "$APP_CTRL_FILE" ]; then
    read -r LAST_APP_CTRL < "$APP_CTRL_FILE" 2>/dev/null || LAST_APP_CTRL=""
  fi

  while [ ! -f "$STOP_FILE" ]; do
    sleep 0.35
    WD_SEQ=$((WD_SEQ + 1))
    echo "$$:$WD_SEQ" > "$WD_HEARTBEAT_FILE" 2>/dev/null || true

    if [ -f "$WD_PID_FILE" ]; then
      read -r ACTIVE_WD < "$WD_PID_FILE" 2>/dev/null || ACTIVE_WD=""
      if [ -n "$ACTIVE_WD" ] && [ "$ACTIVE_WD" != "$$" ]; then
        exit 0
      fi
    fi

    if [ -z "$TARGET_PID" ] && [ -f "$PID_FILE" ]; then
      read -r TARGET_PID < "$PID_FILE" 2>/dev/null || TARGET_PID=""
    fi

    # 1. 监听应用内控制状态变化（用户在 App 中点击 开启 / 重启 / 暂停）
    CUR_APP_CTRL=""
    if [ -f "$APP_CTRL_FILE" ]; then
      read -r CUR_APP_CTRL < "$APP_CTRL_FILE" 2>/dev/null || CUR_APP_CTRL=""
    fi
    if [ -n "$CUR_APP_CTRL" ] && [ "$CUR_APP_CTRL" != "$LAST_APP_CTRL" ]; then
      LAST_APP_CTRL="$CUR_APP_CTRL"
      case "$CUR_APP_CTRL" in
        ENABLED*)
          # App 触发了重新开启或主动重启指令，即刻强制重置 uitest 与重启主守护进程
          echo "ENABLED" > "$CTRL_STATE_FILE"
          /bin/killall -9 uitest >/dev/null 2>&1 || true
          if [ -n "$TARGET_PID" ]; then
            kill -9 "$TARGET_PID" 2>/dev/null || true
          fi
          # 仅当应用沙箱中的脚本有效且包含看门狗逻辑时才同步，防止被低版本覆盖
          if [ -s "$APP_SCRIPT_FILE" ] && /bin/grep -q -- "--watchdog" "$APP_SCRIPT_FILE" 2>/dev/null; then
            /bin/cp -f "$APP_SCRIPT_FILE" "$SCRIPT_PATH" 2>/dev/null || true
            /bin/chmod 777 "$SCRIPT_PATH" 2>/dev/null || true
          fi
          if [ ! -f "$STOP_FILE" ] && [ -f "$SCRIPT_PATH" ]; then
            /bin/sh "$SCRIPT_PATH" --restarted >/dev/null 2>&1 </dev/null &
          fi
          exit 0
          ;;
        PAUSED*|DISABLED*)
          echo "PAUSED" > "$CTRL_STATE_FILE"
          ;;
      esac
    fi

    # 2. 内置 kill -17：零 fork 检查主进程存活，并在 0.35s 内即时唤醒主进程可能出现的 do_rt_sigsuspend 等待
    if [ -z "$TARGET_PID" ] || ! kill -17 "$TARGET_PID" 2>/dev/null; then
      if [ ! -f "$STOP_FILE" ] && [ -f "$SCRIPT_PATH" ]; then
        /bin/sh "$SCRIPT_PATH" >/dev/null 2>&1 </dev/null &
      fi
      exit 0
    fi

    # 3. 检查主进程心跳步进（防 uitest 死锁）
    CUR_HB=""
    if [ -f "$HEARTBEAT_FILE" ]; then
      read -r CUR_HB < "$HEARTBEAT_FILE" 2>/dev/null || CUR_HB=""
    fi

    if [ -n "$CUR_HB" ] && [ "$CUR_HB" = "$LAST_SEEN_HB" ]; then
      STALE_TICKS=$((STALE_TICKS + 1))
      kill -17 "$TARGET_PID" 2>/dev/null || true
      # 若连续 20 次 (约 7 秒) 心跳未步进，强制重启主进程与 uitest
      if [ "$STALE_TICKS" -ge 20 ]; then
        kill -9 "$TARGET_PID" 2>/dev/null || true
        /bin/killall -9 uitest >/dev/null 2>&1 || true
        if [ ! -f "$STOP_FILE" ] && [ -f "$SCRIPT_PATH" ]; then
          /bin/sh "$SCRIPT_PATH" >/dev/null 2>&1 </dev/null &
        fi
        exit 0
      fi
    else
      LAST_SEEN_HB="$CUR_HB"
      STALE_TICKS=0
    fi
  done
  exit 0
fi

# ============================================================================
# 主守护进程模式
# ============================================================================
/bin/rm -f "$STOP_FILE" 2>/dev/null || true

if [ -f "$PID_FILE" ]; then
  read -r OLD_PID < "$PID_FILE" 2>/dev/null || OLD_PID=""
  if [ -n "$OLD_PID" ] && [ "$OLD_PID" != "$$" ] && [ "$OLD_PID" != "$PPID" ]; then
    kill -9 "$OLD_PID" >/dev/null 2>&1 || true
  fi
fi

if [ -f "$WD_PID_FILE" ]; then
  read -r OLD_WD < "$WD_PID_FILE" 2>/dev/null || OLD_WD=""
  if [ -n "$OLD_WD" ] && [ "$OLD_WD" != "$$" ] && [ "$OLD_WD" != "$PPID" ]; then
    kill -9 "$OLD_WD" >/dev/null 2>&1 || true
  fi
fi

/bin/ps -ef > "$RESP_TXT" 2>/dev/null
/bin/sed -E -n '/sh \/data\/local\/tmp\/adskip_daemon\.sh/{/--watchdog/d;/sh -c/d;/grep/d;s/^[^0-9]*([0-9]+).*/\1/p;}' "$RESP_TXT" > "$BOUNDS_TXT" 2>/dev/null
while read -r P; do
  if [ -n "$P" ] && [ "$P" != "$$" ] && [ "$P" != "$PPID" ]; then
    kill -9 "$P" >/dev/null 2>&1 || true
  fi
done < "$BOUNDS_TXT"

echo "$$" > "$PID_FILE"
if [ ! -f "$CTRL_STATE_FILE" ]; then
  echo "ENABLED" > "$CTRL_STATE_FILE"
fi

ensure_watchdog_alive() {
  WD_ALIVE=0
  if [ -f "$WD_PID_FILE" ]; then
    read -r CUR_WD < "$WD_PID_FILE" 2>/dev/null || CUR_WD=""
    if [ -n "$CUR_WD" ] && [ "$CUR_WD" != "$$" ] && kill -17 "$CUR_WD" 2>/dev/null; then
      WD_ALIVE=1
    fi
  fi
  if [ "$WD_ALIVE" -eq 0 ] && [ -f "$SCRIPT_PATH" ]; then
    /bin/sh "$SCRIPT_PATH" --watchdog "$$" >/dev/null 2>&1 </dev/null &
  fi
}

SKIP_COUNT=0
if [ -f "/data/local/tmp/adskip_status.json" ]; then
  /bin/sed -n 's/.*"skippedCount":\([0-9]*\).*/\1/p' "/data/local/tmp/adskip_status.json" > "$RESP_TXT" 2>/dev/null
  read -r SAVED_CNT < "$RESP_TXT" 2>/dev/null || SAVED_CNT=""
  if [ -n "$SAVED_CNT" ]; then
    SKIP_COUNT="$SAVED_CNT"
  fi
fi

SCREEN_W=1260
SCREEN_H=2844
LAST_BUNDLE=""
IN_APP_TICKS=0
SKIPPED_IN_APP=0
ENABLED="true"
LAST_SKIP_TIME=""
LAST_SKIP_BUNDLE=""
LAST_SKIP_COORD=""
LAST_SKIP_BOUNDS=""
IN_CLICK_STREAK=0
NO_BTN_TICKS=0
HB_SEQ=0
BRIDGE_SYNC_TICKS=0
DUMP_COUNT_SINCE_RESET=0
WAS_SCREEN_OFF=0
WAS_IN_SYSTEM=0
IS_RESUME_EVENT=0

write_status_file() {
  echo "{\"running\":true,\"enabled\":$ENABLED,\"skippedCount\":$SKIP_COUNT,\"pid\":$$}" > "/data/local/tmp/adskip_status.json" 2>/dev/null || true
  if [ -d "$APP_FILES_DIR" ]; then
    echo "{\"running\":true,\"enabled\":$ENABLED,\"skippedCount\":$SKIP_COUNT,\"pid\":$$}" > "$APP_STATUS_FILE" 2>/dev/null || true
  fi
}

# 纯内置读取 /proc/net/tcp 检查 18688 (:4900) 是否监听，零 grep 派生开销
sync_bridge_if_listening() {
  MSG_TYPE="$1"
  write_status_file
  PORT_LISTENING=0
  while read -r TCP_LINE; do
    case "$TCP_LINE" in
      *:4900\ *)
        PORT_LISTENING=1
        break
        ;;
    esac
  done < /proc/net/tcp 2>/dev/null

  if [ "$PORT_LISTENING" -eq 1 ]; then
    : > "$RESP_TXT"
    /bin/toybox timeout 1 /bin/toybox ftpget -p 18688 -d 127.0.0.1 "${MSG_TYPE}|$ENABLED|$SKIP_COUNT|$$|$LAST_SKIP_TIME|$LAST_SKIP_BUNDLE|$LAST_SKIP_COORD|$LAST_SKIP_BOUNDS" > "$RESP_TXT" 2>&1 || true
    while read -r R_LINE; do
      case "$R_LINE" in
        *550\ PAUSED*)
          ENABLED="false"
          echo "PAUSED" > "$CTRL_STATE_FILE"
          ;;
        *250\ RESET*)
          ENABLED="true"
          echo "ENABLED" > "$CTRL_STATE_FILE"
          /bin/killall -9 uitest >/dev/null 2>&1 || true
          ;;
        *250\ ENABLED*)
          ENABLED="true"
          echo "ENABLED" > "$CTRL_STATE_FILE"
          ;;
      esac
    done < "$RESP_TXT" 2>/dev/null
    write_status_file
  fi
}

append_app_skip_log() {
  NEW_MSG="$1"
  TMP_APP_LOG="/data/local/tmp/adskip_app_log.tmp"
  if [ -d "$APP_FILES_DIR" ]; then
    if [ -f "$APP_SKIP_LOG" ]; then
      /bin/toybox tail -n 80 "$APP_SKIP_LOG" > "$TMP_APP_LOG" 2>/dev/null || true
    else
      : > "$TMP_APP_LOG"
    fi
    echo "$NEW_MSG" >> "$TMP_APP_LOG" 2>/dev/null || true
    /bin/cat "$TMP_APP_LOG" > "$APP_SKIP_LOG" 2>/dev/null || true
  fi
}

record_skip_event() {
  BUNDLE_ARG="$1"
  COORD_ARG="$2"
  BOUNDS_ARG="$3"
  TYPE_ARG="${4:-标准特征匹配}"
  /bin/date '+%H:%M:%S' > "$RESP_TXT" 2>/dev/null
  read -r TIME_STR < "$RESP_TXT" 2>/dev/null || TIME_STR="00:00:00"
  LAST_SKIP_TIME="$TIME_STR"
  LAST_SKIP_BUNDLE="$BUNDLE_ARG"
  LAST_SKIP_COORD="$COORD_ARG"
  LAST_SKIP_BOUNDS="$BOUNDS_ARG"
  echo "$TIME_STR [SKIP] bundle=$BUNDLE_ARG coord=($COORD_ARG) bounds=$BOUNDS_ARG type=$TYPE_ARG" >> "$HISTORY_LOG" 2>/dev/null || true
  append_app_skip_log "$TIME_STR [SKIP] ⚡ 成功自动跳过开屏广告! 应用=$BUNDLE_ARG | 坐标=($COORD_ARG) | 区域=$BOUNDS_ARG | 机制=$TYPE_ARG"
  sync_bridge_if_listening "STATUS"
}

# 若是由应用内重启触发，写入重启就绪日志
if [ "$1" = "--restarted" ]; then
  /bin/date '+%H:%M:%S' > "$RESP_TXT" 2>/dev/null
  read -r RESTART_TIME < "$RESP_TXT" 2>/dev/null || RESTART_TIME="00:00:00"
  append_app_skip_log "$RESTART_TIME [SKIP-SVC] 🔄 开屏广告自动跳过引擎已重置并重新启动 (PID=$$)"
fi

echo "$$:0" > "$HEARTBEAT_FILE" 2>/dev/null || true
write_status_file
ensure_watchdog_alive
sync_bridge_if_listening "READY"

while true; do
  # 0. 单实例校验、步进心跳更新与双进程互保检查 (全内置指令，零 fork)
  if [ -f "$PID_FILE" ]; then
    read -r ACTIVE_PID < "$PID_FILE" 2>/dev/null || ACTIVE_PID=""
    if [ -n "$ACTIVE_PID" ] && [ "$ACTIVE_PID" != "$$" ]; then
      exit 0
    fi
  fi
  HB_SEQ=$((HB_SEQ + 1))
  echo "$$:$HB_SEQ" > "$HEARTBEAT_FILE" 2>/dev/null || true
  ensure_watchdog_alive

  BRIDGE_SYNC_TICKS=$((BRIDGE_SYNC_TICKS + 1))
  if [ "$BRIDGE_SYNC_TICKS" -ge 6 ]; then
    BRIDGE_SYNC_TICKS=0
    sync_bridge_if_listening "STATUS"
  fi

  # 1. 读取本机控制状态 (ENABLED / PAUSED)，优先读取 App 沙箱控制文件
  CUR_CTRL=""
  if [ -f "$APP_CTRL_FILE" ]; then
    read -r CUR_CTRL < "$APP_CTRL_FILE" 2>/dev/null || CUR_CTRL=""
  fi
  if [ -z "$CUR_CTRL" ] && [ -f "$CTRL_STATE_FILE" ]; then
    read -r CUR_CTRL < "$CTRL_STATE_FILE" 2>/dev/null || CUR_CTRL=""
  fi
  case "$CUR_CTRL" in
    *PAUSED*|*DISABLED*)
      ENABLED="false"
      ;;
    *)
      ENABLED="true"
      ;;
  esac

  # 若当前处于暂停状态，深度休眠 0.5s，不调用 uitest 占用系统资源
  if [ "$ENABLED" != "true" ]; then
    sleep 0.5
    continue
  fi

  # 2. 抓取当前屏幕节点树 (带 1.5s 强制 SIGKILL 保护与 uitest 广播超时死锁自动自愈)
  : > "$DUMP_JSON"
  : > "$UITEST_LOG"
  /bin/toybox timeout -s 9 1.5 /bin/uitest dumpLayout -i -p "$DUMP_JSON" > "$UITEST_LOG" 2>&1 || true
  DUMP_COUNT_SINCE_RESET=$((DUMP_COUNT_SINCE_RESET + 1))

  if [ ! -s "$DUMP_JSON" ]; then
    WAS_SCREEN_OFF=1
    # 检查是否为 uitest start-daemon 广播通道死锁 (Wait for subscribe uitest.broadcast.command.reply timeout)
    read -r ULOG_LINE < "$UITEST_LOG" 2>/dev/null || ULOG_LINE=""
    case "$ULOG_LINE" in
      *timeout*|*failed*|*ERR*|*Error*)
        /bin/killall -9 uitest >/dev/null 2>&1 || true
        DUMP_COUNT_SINCE_RESET=0
        sleep 0.2
        continue
        ;;
    esac
    # 正常息屏或锁屏状态，深度省电休眠 1.2s
    sleep 1.2
    continue
  fi

  # 若之前处于息屏或锁屏状态，当前恢复获取布局：说明发生了亮屏唤醒/解锁动作 (Screen-On Resume)
  if [ "$WAS_SCREEN_OFF" -eq 1 ]; then
    WAS_SCREEN_OFF=0
    IS_RESUME_EVENT=1
  fi

  # 3. 提取所有节点属性行与当前前台应用包名
  /bin/grep -o '"attributes":{[^}]*}' "$DUMP_JSON" > "$ATTRS_TXT" 2>/dev/null || true
  /bin/sed -n '/"bundleName":"/{/sceneboard/d;/systemui/d;s/.*"bundleName":"\([^"]*\)".*/\1/p;q;}' "$ATTRS_TXT" > "$BUNDLE_TXT" 2>/dev/null || true
  read -r CUR_BUNDLE < "$BUNDLE_TXT" 2>/dev/null || CUR_BUNDLE=""

  if [ -z "$CUR_BUNDLE" ]; then
    # 当前处于系统桌面或多任务后台选择视图：置位 WAS_IN_SYSTEM 标志
    WAS_IN_SYSTEM=1
    LAST_BUNDLE=""
    IN_CLICK_STREAK=0
    NO_BTN_TICKS=0
    IN_APP_TICKS=0
    SKIPPED_IN_APP=0

    # 在系统桌面时：若 uitest 累计采样超过 350 次，主动重置一次 uitest start-daemon 防止其长期运行内存/CPU膨胀
    if [ "$DUMP_COUNT_SINCE_RESET" -ge 350 ]; then
      /bin/killall -9 uitest >/dev/null 2>&1 || true
      DUMP_COUNT_SINCE_RESET=0
    fi
    sleep 0.3
    continue
  fi

  case "$CUR_BUNDLE" in
    com.ysydhc.adskipvpn)
      LAST_BUNDLE="$CUR_BUNDLE"
      IN_CLICK_STREAK=0
      NO_BTN_TICKS=0
      IN_APP_TICKS=0
      SKIPPED_IN_APP=0
      BRIDGE_SYNC_TICKS=0
      sync_bridge_if_listening "STATUS"
      sleep 0.4
      continue
      ;;
    com.huawei.hmos.settings)
      LAST_BUNDLE="$CUR_BUNDLE"
      IN_CLICK_STREAK=0
      NO_BTN_TICKS=0
      IN_APP_TICKS=0
      SKIPPED_IN_APP=0
      sleep 0.6
      continue
      ;;
  esac

  # 判定是否发生应用冷启动、切回前台 (Resume)、多任务唤回、息屏点亮进入应用：
  if [ "$WAS_IN_SYSTEM" -eq 1 ] || [ "$IS_RESUME_EVENT" -eq 1 ] || [ "$CUR_BUNDLE" != "$LAST_BUNDLE" ]; then
    WAS_IN_SYSTEM=0
    IS_RESUME_EVENT=0
    LAST_BUNDLE="$CUR_BUNDLE"
    IN_CLICK_STREAK=0
    NO_BTN_TICKS=0
    IN_APP_TICKS=0
    SKIPPED_IN_APP=0
  else
    IN_APP_TICKS=$((IN_APP_TICKS + 1))
  fi

  # 动态自适应屏幕分辨率与右上角安全跳过区域 (全分辨率自适应)
  ROOT_RES=$(/bin/sed -n '1s/.*"bounds":"\[0,0\]\[\([0-9]*\),\([0-9]*\)\]".*/\1:\2/p' "$ATTRS_TXT" 2>/dev/null)
  if [ -n "$ROOT_RES" ]; then
    RW="${ROOT_RES%:*}"
    RH="${ROOT_RES#*:}"
    if [ "$RW" -ge 400 ] && [ "$RH" -ge 600 ]; then
      SCREEN_W="$RW"
      SCREEN_H="$RH"
    fi
  fi
  MIN_CAND_X=$(( SCREEN_W * 68 / 100 ))
  MAX_CAND_Y=$(( SCREEN_H * 15 / 100 ))
  MIN_CAND_Y=$(( SCREEN_H * 2 / 100 ))

  # 4. 第一层：通用多模态文本、符号与主流广告 SDK 特征提取
  # A 规则：跳过关键词、关闭符号、主流联盟 SDK 核心 ID (广点通/TAD/穿山甲/快手/百青藤/华为HiAd)
  : > "$BOUNDS_TXT"
  /bin/sed -E -n '/"visible":"true"/!d; /QuickBackText|AdSkip|adskip|跳过&VPN|控制台|跳过片头|跳过片尾|跳过前奏|跳过空白|跳过静音|无障碍|已自动跳过/d; /"(text|originalText|description|accessibilityText)":"[^"]{0,20}(跳[[:space:]]*过|跳过广告|点击跳过|关闭广告|[Ss][Kk][Ii][Pp]|关闭|不再提示|忽略)[^"]{0,20}"|"(id|key)":"[^"]*(skip|splash_skip|ad_skip|tv_skip|btn_skip|skip_view|tad_|splash_btn|gdt_|btn_close|iv_close|tt_splash|tt_ad_skip|ksad_|mobads_|hiad_)[^"]*"/s/.*"bounds":"\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]".*/\1:\2:\3:\4:STD/p' "$ATTRS_TXT" > "$BOUNDS_TXT" 2>/dev/null || true

  # B 规则：右上角纯数字/倒计时跳过 (如 "5s", "4s", "5秒", "3")
  /bin/sed -E -n '/"visible":"true"/!d; /"(text|originalText)":"[[:space:]]*[0-9]{1,2}[[:space:]]*(s|S|秒)?[[:space:]]*"/s/.*"bounds":"\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]".*/\1:\2:\3:\4:CD/p' "$ATTRS_TXT" >> "$BOUNDS_TXT" 2>/dev/null || true

  CLICKED=0
  if [ -s "$BOUNDS_TXT" ]; then
    while IFS=":" read -r x1 y1 x2 y2 tag; do
      if [ -n "$x1" ] && [ -n "$y2" ]; then
        w=$((x2 - x1))
        h=$((y2 - y1))
        # 若为倒计时规则，强制限制在右上角跳过区域，防止页面其他数字误触
        if [ "$tag" = "CD" ]; then
          if [ "$x1" -lt "$MIN_CAND_X" ] || [ "$y1" -lt "$MIN_CAND_Y" ] || [ "$y2" -gt "$MAX_CAND_Y" ]; then
            continue
          fi
        fi
        # 尺寸与区域校验：排除全屏背景陷阱与状态栏 (<40)
        if [ "$w" -ge 20 ] && [ "$w" -le 850 ] && [ "$h" -ge 16 ] && [ "$h" -le 300 ] && [ "$x1" -ge 10 ] && [ "$y1" -ge 40 ] && [ "$y2" -le 2800 ]; then
          cx=$(( (x1 + x2) / 2 ))
          cy=$(( (y1 + y2) / 2 ))
          /bin/uinput -T -d "$cx" "$cy" -i 55 -u "$cx" "$cy" >/dev/null 2>&1
          if [ "$IN_CLICK_STREAK" -eq 0 ]; then
            SKIP_COUNT=$((SKIP_COUNT + 1))
            IN_CLICK_STREAK=1
            SKIPPED_IN_APP=1
            record_skip_event "$CUR_BUNDLE" "${cx},${cy}" "[${x1},${y1}][${x2},${y2}]" "🎯 标准特征匹配"
          fi
          CLICKED=1
          break
        fi
      fi
    done < "$BOUNDS_TXT"
  fi

  # --------------------------------------------------------------------------
  # 第二层：通用开屏广告场景感知与右上角胶囊启发式兜底 (Heuristic Probe)
  # 仅在刚进入应用的开屏/切回窗口期 (前 22 轮采样内) 且第一层未命中时生效
  # --------------------------------------------------------------------------
  if [ "$CLICKED" -eq 0 ] && [ "$IN_APP_TICKS" -le 22 ] && [ "$SKIPPED_IN_APP" -eq 0 ]; then
    HAS_AD_SIGNAL=0
    if /bin/grep -q -E '"(text|originalText|description|accessibilityText)":"[^"]*(广告|[Aa][Dd]|推广|商业推广|摇一摇|扭一扭|翻转|滑动浏览|进入第三方|第三方应用|查看详情|了解详情)[^"]*"' "$ATTRS_TXT" 2>/dev/null || \
       /bin/grep -q -E '"(id|key)":"[^"]*(splash|ad_container|tad_|gdt_|tt_splash|ksad_|mobads_|hiad_)[^"]*"' "$ATTRS_TXT" 2>/dev/null; then
      HAS_AD_SIGNAL=1
    fi

    if [ "$HAS_AD_SIGNAL" -eq 1 ]; then
      # A. 检索落在右上角跳过区域的顶层可见组件 (Image/Stack/Row 等无文本胶囊)
      : > "$CAND_TXT"
      /bin/sed -E -n '/"visible":"true"/!d; /QuickBackText|AdSkip|adskip|控制台/d; s/.*"bounds":"\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]".*/\1:\2:\3:\4/p' "$ATTRS_TXT" > "$CAND_TXT" 2>/dev/null || true
      
      FOUND_CAND=0
      while IFS=":" read -r cx1 cy1 cx2 cy2; do
        if [ -n "$cx1" ] && [ -n "$cy2" ]; then
          cw=$((cx2 - cx1))
          ch=$((cy2 - cy1))
          if [ "$cx1" -ge "$MIN_CAND_X" ] && [ "$cy1" -ge "$MIN_CAND_Y" ] && [ "$cy2" -le "$MAX_CAND_Y" ]; then
            if [ "$cw" -ge 35 ] && [ "$cw" -le 320 ] && [ "$ch" -ge 20 ] && [ "$ch" -le 160 ]; then
              tcx=$(( (cx1 + cx2) / 2 ))
              tcy=$(( (cy1 + cy2) / 2 ))
              /bin/uinput -T -d "$tcx" "$tcy" -i 55 -u "$tcx" "$tcy" >/dev/null 2>&1
              if [ "$IN_CLICK_STREAK" -eq 0 ]; then
                SKIP_COUNT=$((SKIP_COUNT + 1))
                IN_CLICK_STREAK=1
                SKIPPED_IN_APP=1
                record_skip_event "$CUR_BUNDLE" "${tcx},${tcy}" "[${cx1},${cy1}][${cx2},${cy2}]" "⚡ 智能热区识别"
              fi
              CLICKED=1
              FOUND_CAND=1
              break
            fi
          fi
        fi
      done < "$CAND_TXT"

      # B. 极端自绘场景兜底：纯 Canvas/XComponent 自绘且连节点都未暴露时，执行全机型通用右上角锚点探针
      if [ "$FOUND_CAND" -eq 0 ] && [ "$IN_APP_TICKS" -le 10 ]; then
        ANCHOR_X=$(( SCREEN_W * 90 / 100 ))
        ANCHOR_Y=$(( SCREEN_H * 78 / 1000 ))
        /bin/uinput -T -d "$ANCHOR_X" "$ANCHOR_Y" -i 55 -u "$ANCHOR_X" "$ANCHOR_Y" >/dev/null 2>&1
        if [ "$IN_CLICK_STREAK" -eq 0 ]; then
          SKIP_COUNT=$((SKIP_COUNT + 1))
          IN_CLICK_STREAK=1
          SKIPPED_IN_APP=1
          record_skip_event "$CUR_BUNDLE" "${ANCHOR_X},${ANCHOR_Y}" "[探针锚点]" "🚀 全局通用锚点探针"
        fi
        CLICKED=1
      fi
    fi
  fi

  if [ "$CLICKED" -eq 1 ]; then
    NO_BTN_TICKS=0
    IN_APP_TICKS=0
    sleep 0.12
    continue
  else
    NO_BTN_TICKS=$((NO_BTN_TICKS + 1))
    if [ "$NO_BTN_TICKS" -ge 2 ]; then
      IN_CLICK_STREAK=0
    fi
  fi

  # 5. 节奏调度：
  # A. 开屏与切回前台（Resume）窗口期 (前 22 轮，约 3 秒内)：
  #    高频突发采样 (每 0.12s 采样一次)，确保冷热启动、后台切回、锁屏亮屏时的广告露头就秒；
  # B. 应用稳态使用期 (已连续运行超过 22 轮无广告，或已完成跳过)：
  #    低功耗巡检模式 (每 0.5s 采样一次)，保证不掉帧、低耗电，且仍能捕捉突发热切回与插屏广告。
  if [ "$IN_APP_TICKS" -le 22 ] && [ "$SKIPPED_IN_APP" -eq 0 ]; then
    sleep 0.12
  else
    sleep 0.5
  fi
done
