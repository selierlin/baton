#!/bin/sh
# 长跑内存采样：默认每 300 秒记一条 Baton 的 phys_footprint / RSS / OCR 子进程数。
# 用法：Scripts/soak-sample.sh [间隔秒] [日志路径]
# 24h 泄漏验收看：末条与首条 footprint 差值是否在 ±3 MB 内且无单向爬升。

INTERVAL=${1:-300}
OUT=${2:-"$HOME/Projects/my_projects/baton/soak.log"}
LAST_PID=""

while true; do
  TS=$(date '+%F %T')
  PID=$(pgrep -f "Baton.app/Contents/MacOS/Baton" | head -1)
  if [ -z "$PID" ]; then
    echo "$TS app=down" >>"$OUT"
    LAST_PID=""
  else
    # 重启会换 pid：记一行分隔，事后按进程分段看趋势，别把新进程的低基线当成「回落」
    if [ -n "$LAST_PID" ] && [ "$PID" != "$LAST_PID" ]; then
      echo "$TS --- pid $LAST_PID -> $PID（重启，基线重算）---" >>"$OUT"
    fi
    LAST_PID="$PID"
    FP=$(/usr/bin/footprint -p "$PID" 2>/dev/null | sed -n 's/.*Footprint: \([0-9.]* [KMG]*B\).*/\1/p' | head -1)
    RSS=$(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ')
    OCR=$(pgrep -f "Baton.app/Contents/MacOS/BatonOCR" | wc -l | tr -d ' ')
    echo "$TS pid=$PID rss=${RSS}KB footprint=${FP:-?} ocr=$OCR" >>"$OUT"
  fi
  sleep "$INTERVAL"
done
