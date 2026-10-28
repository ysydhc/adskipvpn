#!/bin/sh
# HarmonyOS NEXT 开屏广告自动跳过守护服务 (零管道 / 零子Shell / 自愈看门狗版)

CTRL_STATE_FILE="/data/local/tmp/adskip_ctrl_state.txt"
DUMP_JSON="/data/local/tmp/skip_v3.json"
ATTRS_TXT="/data/local/tmp/adskip_attrs.txt"
BUNDLE_TXT="/data/local/tmp/adskip_bundle.txt"
BOUNDS_TXT="/data/local/tmp/adskip_bounds.txt"
RESP_TXT="/data/local/tmp/adskip_resp.txt"
HEARTBEAT_FILE="/data/local/tmp/adskip_heartbeat"
PID_FILE="/data/local/tmp/adskip_daemon.pid"
HISTORY_LOG="/data/local/tmp/adskip_history.log"

# 单实例互斥保护：清理旧守护进程后再写入当前 PID
if [ -f "$PID_FILE" ]; then
  read -r OLD_PID < "$PID_FILE" 2>/dev/null || OLD_PID=""
  if [ -n "$OLD_PID" ] && [ "$OLD_PID" != "$$" ]; then
    /bin/kill -9 "$OLD_PID" >/dev/null 2>&1 || true
  fi
fi

/bin/ps -ef > "$RESP_TXT" 2>/dev/null
/bin/sed -E -n '/adskip_daemon\.sh/{/grep/d;s/^[^0-9]*([0-9]+).*/\1/p;}' "$RESP_TXT" > "$BOUNDS_TXT" 2>/dev/null
while read -r P; do
  if [ -n "$P" ] && [ "$P" != "$$" ] && [ "$P" != "$PPID" ]; then
    /bin/kill -9 "$P" >/dev/null 2>&1 || true
  fi
done < "$BOUNDS_TXT"

echo "$$" > "$PID_FILE"
if [ ! -f "$CTRL_STATE_FILE" ]; then
  echo "ENABLED" > "$CTRL_STATE_FILE"
fi

# 启动独立看门狗协程：每 2 秒发送一次 SIGCHLD (17) 防止 mksh 陷入 do_rt_sigsuspend 信号等待死锁
MAIN_PID="$$"
(
  while /bin/kill -0 "$MAIN_PID" 2>/dev/null; do
    /bin/sleep 2
    if [ -f "$PID_FILE" ]; then
      read -r CUR_P < "$PID_FILE" 2>/dev/null || CUR_P=""
      if [ -n "$CUR_P" ] && [ "$CUR_P" != "$MAIN_PID" ]; then
        exit 0
      fi
    fi
    /bin/kill -17 "$MAIN_PID" 2>/dev/null || true
  done
) >/dev/null 2>&1 </dev/null &

SKIP_COUNT=0
if [ -f "/data/local/tmp/adskip_status.json" ]; then
  /bin/sed -n 's/.*"skippedCount":\([0-9]*\).*/\1/p' "/data/local/tmp/adskip_status.json" > "$RESP_TXT" 2>/dev/null
  read -r SAVED_CNT < "$RESP_TXT" 2>/dev/null || SAVED_CNT=""
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

write_status_file() {
  echo "{\"running\":true,\"enabled\":$ENABLED,\"skippedCount\":$SKIP_COUNT,\"pid\":$$}" > "/data/local/tmp/adskip_status.json" 2>/dev/null || true
}

# 仅当本应用 TCP 桥接端口 18688 (十六进制 :4900) 处于监听状态时同步，零阻塞、零后台子进程
sync_bridge_if_listening() {
  MSG_TYPE="$1"
  write_status_file
  if /bin/grep -q ":4900 " /proc/net/tcp 2>/dev/null; then
    /bin/toybox timeout 1 /bin/toybox ftpget -p 18688 -d 127.0.0.1 "${MSG_TYPE}|$ENABLED|$SKIP_COUNT|$$|$LAST_SKIP_TIME|$LAST_SKIP_BUNDLE|$LAST_SKIP_COORD|$LAST_SKIP_BOUNDS" > "$RESP_TXT" 2>&1 || true
    if /bin/grep -q "550 PAUSED" "$RESP_TXT" 2>/dev/null; then
      ENABLED="false"
      echo "PAUSED" > "$CTRL_STATE_FILE"
    elif /bin/grep -q "250 ENABLED" "$RESP_TXT" 2>/dev/null; then
      ENABLED="true"
      echo "ENABLED" > "$CTRL_STATE_FILE"
    fi
    write_status_file
  fi
}

record_skip_event() {
  BUNDLE_ARG="$1"
  COORD_ARG="$2"
  BOUNDS_ARG="$3"
  /bin/date '+%H:%M:%S' > "$RESP_TXT" 2>/dev/null
  read -r TIME_STR < "$RESP_TXT" 2>/dev/null || TIME_STR="00:00:00"
  LAST_SKIP_TIME="$TIME_STR"
  LAST_SKIP_BUNDLE="$BUNDLE_ARG"
  LAST_SKIP_COORD="$COORD_ARG"
  LAST_SKIP_BOUNDS="$BOUNDS_ARG"
  echo "$TIME_STR [SKIP] bundle=$BUNDLE_ARG coord=($COORD_ARG) bounds=$BOUNDS_ARG" >> "$HISTORY_LOG" 2>/dev/null || true
  write_status_file
}

sync_bridge_if_listening "READY"

while true; do
  # 0. 单实例校验与心跳更新 (纯内置 read/重定向，不派生子进程)
  if [ -f "$PID_FILE" ]; then
    read -r ACTIVE_PID < "$PID_FILE" 2>/dev/null || ACTIVE_PID=""
    if [ -n "$ACTIVE_PID" ] && [ "$ACTIVE_PID" != "$$" ]; then
      exit 0
    fi
  fi
  echo "$$" > "$HEARTBEAT_FILE" 2>/dev/null || true

  # 1. 读取本机控制状态 (ENABLED / PAUSED)
  if [ -f "$CTRL_STATE_FILE" ]; then
    read -r CTRL < "$CTRL_STATE_FILE" 2>/dev/null || CTRL="ENABLED"
    case "$CTRL" in
      *PAUSED*|*DISABLED*)
        ENABLED="false"
        ;;
      *)
        ENABLED="true"
        ;;
    esac
  fi

  # 2. 抓取当前屏幕无障碍节点树 (带 2s 超时保护防止 IPC 卡死)
  /bin/rm -f "$DUMP_JSON" 2>/dev/null
  /bin/toybox timeout 2 /bin/uitest dumpLayout -i -p "$DUMP_JSON" >/dev/null 2>&1 || true

  if [ ! -s "$DUMP_JSON" ]; then
    # 息屏或锁屏状态，深度省电休眠 1.2s
    /bin/sleep 1.2
    continue
  fi

  # 3. 单进程提取所有节点属性行，并提取当前前台应用包名 (全程零管道 '|', 零 '$(...)')
  /bin/grep -o '"attributes":{[^}]*}' "$DUMP_JSON" > "$ATTRS_TXT" 2>/dev/null || true
  /bin/sed -n '/"bundleName":"/{/sceneboard/d;/systemui/d;s/.*"bundleName":"\([^"]*\)".*/\1/p;q;}' "$ATTRS_TXT" > "$BUNDLE_TXT" 2>/dev/null || true
  read -r CUR_BUNDLE < "$BUNDLE_TXT" 2>/dev/null || CUR_BUNDLE=""

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
      LAST_BUNDLE="$CUR_BUNDLE"
      IN_CLICK_STREAK=0
      NO_BTN_TICKS=0
      IN_APP_TICKS=0
      sync_bridge_if_listening "STATUS"
      /bin/sleep 0.2
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

  # 4. 单进程提取所有可见“跳过 / 跳过广告”按钮的 x1:y1:x2:y2 到文件，纯内置 read 解析坐标
  : > "$BOUNDS_TXT"
  if /bin/egrep -q '跳过|Skip|SKIP|skip' "$ATTRS_TXT" 2>/dev/null; then
    /bin/sed -E -n '/"visible":"true"/!d; /QuickBackText|AdSkip|adskip|跳过&VPN|控制台|跳过片头|跳过片尾|跳过前奏|跳过空白|跳过静音|自动跳过|无障碍|已自动跳过|点击跳过/d; /"(text|originalText|description)":"[^"]{0,15}(跳过|跳过广告|关闭广告|Skip|SKIP)[^"]{0,15}"|"(id|key)":"[^"]*(skip|splash_skip|ad_skip|tv_skip|btn_skip)[^"]*"/s/.*"bounds":"\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]".*/\1:\2:\3:\4/p' "$ATTRS_TXT" > "$BOUNDS_TXT" 2>/dev/null || true
  fi

  if [ -s "$BOUNDS_TXT" ]; then
    NO_BTN_TICKS=0
    CLICKED=0
    while IFS=":" read -r x1 y1 x2 y2; do
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
            record_skip_event "$CUR_BUNDLE" "${cx},${cy}" "[${x1},${y1}][${x2},${y2}]"
          fi
          CLICKED=1
          break
        fi
      fi
    done < "$BOUNDS_TXT"

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
