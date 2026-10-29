#!/usr/bin/env bash
# 一键推送并激活手机本机常驻开屏跳过守护服务（激活后可断开数据线独立运行）
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HDC="${HDC:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc}"

"$HDC" file send "$SCRIPT_DIR/entry/src/main/resources/rawfile/adskip_daemon.sh" /data/local/tmp/adskip_daemon.sh
"$HDC" shell '
  OLD_PIDS=$(/bin/ps -ef | /bin/grep "adskip_daemon.sh" | /bin/grep -v grep | /bin/sed -E "s/^[^0-9]*([0-9]+).*/\1/")
  for P in $OLD_PIDS; do
    /bin/kill -9 "$P" >/dev/null 2>&1 || true
  done
  echo "ENABLED" > /data/local/tmp/adskip_ctrl_state.txt
  /bin/chmod 666 /data/local/tmp/adskip_ctrl_state.txt
  /bin/chmod 755 /data/local/tmp/adskip_daemon.sh
  /bin/cp -f /data/local/tmp/adskip_daemon.sh /data/app/el2/100/base/com.ysydhc.adskipvpn/haps/entry/files/adskip_daemon.sh 2>/dev/null || true
  aa start -a EntryAbility -b com.ysydhc.adskipvpn >/dev/null 2>&1 || true
  /bin/sleep 1
  /bin/nohup /bin/sh /data/local/tmp/adskip_daemon.sh >/dev/null 2>&1 </dev/null &
  /bin/sleep 1
  /bin/cat /data/local/tmp/adskip_status.json 2>/dev/null || true
  echo ""
'
echo "✅ 开屏自动跳过守护服务已激活！"
