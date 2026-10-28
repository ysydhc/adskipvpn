#!/bin/sh
# HarmonyOS NEXT 开屏广告自动跳过守护服务

CTRL_STATE_FILE="/data/local/tmp/adskip_ctrl_state.txt"
DUMP_JSON="/data/local/tmp/skip_v3.json"
PID_FILE="/data/local/tmp/adskip_daemon.pid"
HISTORY_LOG="/data/local/tmp/adskip_history.log"

# 单实例互斥保护：清理旧守护进程后再写入当前 PID
if [ -f "$PID_FILE" ]; then
  OLD_PID=$(/bin/cat "$PID_FILE" 2>/dev/null)
  if [ -n "$OLD_PID" ] && [ "$OLD_PID" != "$$" ]; then
    /bin/kill -9 "$OLD_PID" >/dev/null 2>&1 || true
  fi
fi
OTHER_PIDS=$(/bin/ps -ef | /bin/grep "adskip_daemon.sh" | /bin/grep -v grep | /bin/sed -E 's/^[^0-9]*([0-9]+).*/\1/')
for P in $OTHER_PIDS; do
  if [ "$P" != "$$" ] && [ "$P" != "$PPID" ]; then
    /bin/kill -9 "$P" >/dev/null 2>&1 || true
  fi
done
echo "$$" > "$PID_FILE"
if [ ! -f "$CTRL_STATE_FILE" ]; then
  echo "ENABLED" > "$CTRL_STATE_FILE"
fi

SKIP_COUNT=0
if [ -f "/data/local/tmp/adskip_status.json" ]; then
  SAVED_CNT=$(/bin/sed -n 's/.*"skippedCount":\([0-9]*\).*/\1/p' "/data/local/tmp/adskip_status.json" 2>/dev/null | /bin/head -n 1)
  if [ -n "$SAVED_CNT" ]; then
    SKIP_COUNT="$SAVED_CNT"
  fi
fi
LAST_BUNDLE=""
IN_APP_TICKS=0
ENABLED="true"
LAST_SKIP_TIME=""
LAST_SKIP_BUNDLE=""
LAST_SKIP_COORD=""
LAST_SKIP_BOUNDS=""
IN_CLICK_STREAK=0
NO_BTN_TICKS=0

# 当本应用在前台时，异步同步开关状态与跳过记录 (通过 127.0.0.1:18688 响应码 250 ENABLED / 550 PAUSED 实时同步，不阻塞主循环)
sync_foreground_app_async() {
  echo "{\"running\":true,\"enabled\":$ENABLED,\"skippedCount\":$SKIP_COUNT,\"pid\":$$}" > "/data/local/tmp/adskip_status.json" 2>/dev/null || true
  (
    RESP=$(/bin/toybox timeout 1 /bin/toybox ftpget -p 18688 -d 127.0.0.1 "STATUS|$ENABLED|$SKIP_COUNT|$$|$LAST_SKIP_TIME|$LAST_SKIP_BUNDLE|$LAST_SKIP_COORD|$LAST_SKIP_BOUNDS" 2>&1)
    case "$RESP" in
      *550*PAUSED*)
        echo "PAUSED" > "$CTRL_STATE_FILE"
        ;;
      *connect*|*refused*|*timeout*)
        ;;
      *)
        echo "ENABLED" > "$CTRL_STATE_FILE"
        ;;
    esac
  ) &
}

notify_ready_async() {
  echo "{\"running\":true,\"enabled\":$ENABLED,\"skippedCount\":$SKIP_COUNT,\"pid\":$$}" > "/data/local/tmp/adskip_status.json" 2>/dev/null || true
  (
    RESP=$(/bin/toybox timeout 1 /bin/toybox ftpget -p 18688 -d 127.0.0.1 "READY|$ENABLED|$SKIP_COUNT|$$" 2>&1)
    case "$RESP" in
      *550*PAUSED*)
        echo "PAUSED" > "$CTRL_STATE_FILE"
        ;;
      *connect*|*refused*|*timeout*)
        ;;
      *)
        echo "ENABLED" > "$CTRL_STATE_FILE"
        ;;
    esac
  ) &
}

notify_skip_async() {
  BUNDLE_ARG="$1"
  COORD_ARG="$2"
  BOUNDS_ARG="$3"
  TIME_STR=$(/bin/date '+%H:%M:%S')
  LAST_SKIP_TIME="$TIME_STR"
  LAST_SKIP_BUNDLE="$BUNDLE_ARG"
  LAST_SKIP_COORD="$COORD_ARG"
  LAST_SKIP_BOUNDS="$BOUNDS_ARG"
  echo "$TIME_STR [SKIP] bundle=$BUNDLE_ARG coord=($COORD_ARG) bounds=$BOUNDS_ARG" >> "$HISTORY_LOG" 2>/dev/null || true
  echo "{\"running\":true,\"enabled\":$ENABLED,\"skippedCount\":$SKIP_COUNT,\"pid\":$$}" > "/data/local/tmp/adskip_status.json" 2>/dev/null || true
  /bin/toybox timeout 1 /bin/toybox ftpget -p 18688 -d 127.0.0.1 "SKIP|$ENABLED|$SKIP_COUNT|$$|$BUNDLE_ARG|$COORD_ARG|$BOUNDS_ARG" >/dev/null 2>&1 &
}

notify_ready_async

while true; do
  # 0. 单实例校验：若已有更新的守护进程接管，立即退出避免并发冲突
  if [ -f "$PID_FILE" ]; then
    ACTIVE_PID=$(/bin/cat "$PID_FILE" 2>/dev/null)
    if [ -n "$ACTIVE_PID" ] && [ "$ACTIVE_PID" != "$$" ]; then
      exit 0
    fi
  fi

  # 1. 读取本机控制状态 (ENABLED / PAUSED)
  if [ -f "$CTRL_STATE_FILE" ]; then
    CTRL=$(/bin/cat "$CTRL_STATE_FILE" 2>/dev/null)
    case "$CTRL" in
      *PAUSED*|*DISABLED*)
        ENABLED="false"
        ;;
      *)
        ENABLED="true"
        ;;
    esac
  fi

  # 2. 抓取当前屏幕无障碍节点树
  /bin/rm -f "$DUMP_JSON" 2>/dev/null
  /bin/uitest dumpLayout -i -p "$DUMP_JSON" >/dev/null 2>&1

  if [ ! -s "$DUMP_JSON" ]; then
    # 息屏或锁屏状态，深度省电休眠 1.5s
    /bin/sleep 1.5
    continue
  fi

  # 3. 提取除系统桌面(sceneboard/systemui)外的当前前台应用包名
  CUR_BUNDLE=$(/bin/grep -o '"bundleName":"[^"]*"' "$DUMP_JSON" | /bin/egrep -v 'sceneboard|systemui' | /bin/head -n 1 | /bin/sed 's/"bundleName":"//;s/"//')

  if [ -z "$CUR_BUNDLE" ]; then
    # 当前在手机系统桌面，重置应用内计时器，0.1s 极速待命以便捕捉点击图标瞬间
    LAST_BUNDLE=""
    IN_CLICK_STREAK=0
    NO_BTN_TICKS=0
    IN_APP_TICKS=0
    /bin/sleep 0.1
    continue
  fi

  case "$CUR_BUNDLE" in
    com.ysydhc.adskipvpn)
      # 当用户在前台打开本应用时，异步同步最新状态、跳过记录与开关指令，切出应用时零阻塞
      LAST_BUNDLE="$CUR_BUNDLE"
      IN_CLICK_STREAK=0
      NO_BTN_TICKS=0
      IN_APP_TICKS=0
      sync_foreground_app_async
      /bin/sleep 0.15
      continue
      ;;
    com.huawei.hmos.settings)
      LAST_BUNDLE="$CUR_BUNDLE"
      IN_CLICK_STREAK=0
      NO_BTN_TICKS=0
      IN_APP_TICKS=0
      /bin/sleep 0.4
      continue
      ;;
  esac

  # 若当前处于暂停状态，不执行任何自动点击
  if [ "$ENABLED" != "true" ]; then
    /bin/sleep 0.5
    continue
  fi

  if [ "$CUR_BUNDLE" != "$LAST_BUNDLE" ]; then
    LAST_BUNDLE="$CUR_BUNDLE"
    IN_CLICK_STREAK=0
    NO_BTN_TICKS=0
    IN_APP_TICKS=0
  else
    IN_APP_TICKS=$((IN_APP_TICKS + 1))
  fi

  # 4. 直接在管道内提取所有可见“跳过 / 跳过广告”按钮的 x1:y1:x2:y2
  BOUNDS_LIST=$(/bin/grep -o '"attributes":{[^}]*}' "$DUMP_JSON" \
    | /bin/grep '"visible":"true"' \
    | /bin/egrep '"(text|originalText|description)":"[^"]{0,15}(跳过|跳过广告|关闭广告|Skip|SKIP)[^"]{0,15}"|"(id|key)":"[^"]*(skip|splash_skip|ad_skip|tv_skip|btn_skip)[^"]*"' \
    | /bin/egrep -v 'QuickBackText|AdSkip|adskip|跳过&VPN|控制台|跳过片头|跳过片尾|跳过前奏|跳过空白|跳过静音|自动跳过|无障碍|已自动跳过|点击跳过' \
    | /bin/sed -n 's/.*"bounds":"\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1:\2:\3:\4/p')

  if [ -n "$BOUNDS_LIST" ]; then
    NO_BTN_TICKS=0
    CLICKED=0
    for B in $BOUNDS_LIST; do
      OLD_IFS="$IFS"
      IFS=":"
      set -- $B
      IFS="$OLD_IFS"
      x1=$1
      y1=$2
      x2=$3
      y2=$4

      if [ -n "$x1" ] && [ -n "$y2" ]; then
        w=$((x2 - x1))
        h=$((y2 - y1))
        if [ "$w" -ge 20 ] && [ "$w" -le 800 ] && [ "$h" -ge 16 ] && [ "$h" -le 300 ] && [ "$x1" -ge 450 ] && [ "$y1" -ge 115 ] && [ "$y2" -le 2650 ]; then
          cx=$(( (x1 + x2) / 2 ))
          cy=$(( (y1 + y2) / 2 ))
          /bin/uinput -T -d "$cx" "$cy" -i 55 -u "$cx" "$cy" >/dev/null 2>&1
          if [ "$IN_CLICK_STREAK" -eq 0 ]; then
            SKIP_COUNT=$((SKIP_COUNT + 1))
            IN_CLICK_STREAK=1
            notify_skip_async "$CUR_BUNDLE" "${cx},${cy}" "[${x1},${y1}][${x2},${y2}]"
          fi
          CLICKED=1
          break
        fi
      fi
    done

    if [ "$CLICKED" -eq 1 ]; then
      # 点击后重置应用内计时器并仅等待 0.1s 立即复检：若首次点击时广告刚淡入尚未响应，下一轮会立即补点；若已跳过则不会误点主页
      IN_APP_TICKS=0
      /bin/sleep 0.1
      continue
    fi
  else
    NO_BTN_TICKS=$((NO_BTN_TICKS + 1))
    if [ "$NO_BTN_TICKS" -ge 2 ]; then
      IN_CLICK_STREAK=0
    fi
  fi

  # 5. 智能省电休眠：刚打开新应用的前 30 轮零延迟连续扫描，之后保持 0.2s 轻量巡检，确保快速切出重进同一应用也绝不漏检
  if [ "$IN_APP_TICKS" -le 30 ]; then
    :
  else
    /bin/sleep 0.2
  fi
done
