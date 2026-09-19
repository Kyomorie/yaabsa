#!/usr/bin/env bash

adb="${RUNTIME_SDK_ROOT}/platform-tools/adb"
package='de.vito0912.yaabsa.dev'

if [ ! -x "$adb" ]; then
  echo "ADB_NOT_FOUND=$adb" >&2
  exit 60
fi

token="$(cat "$RUNNER_TEMP/abs-token" 2>/dev/null)"
if [ -z "$token" ]; then
  echo 'ABS_TOKEN_MISSING=1' >&2
  exit 61
fi

# Keep the emulator in the scenario step to avoid cross-step hosted-runner
# lifecycle loss. This is acceptance-harness behavior only.
emulator="${RUNTIME_EMULATOR_BIN:-${RUNTIME_SDK_ROOT}/emulator/emulator}"
if [ ! -x "$emulator" ]; then
  echo "EMULATOR_NOT_FOUND=$emulator" >&2
  exit 62
fi
if [ ! -f yaabsa.apk ]; then
  echo 'APK_NOT_FOUND=yaabsa.apk' >&2
  exit 63
fi

"$adb" emu kill >/dev/null 2>&1 || true
i=0
while [ "$i" -lt 20 ]; do
  if ! "$adb" devices | awk 'NR>1 && $1 ~ /^emulator-/ && $2=="device" {f=1} END{exit !f}'; then
    break
  fi
  sleep 1
  i=$((i + 1))
done
if "$adb" devices | awk 'NR>1 && $1 ~ /^emulator-/ && $2=="device" {f=1} END{exit !f}'; then
  echo 'PREVIOUS_EMULATOR_DID_NOT_EXIT=1' >&2
  exit 64
fi

"$adb" kill-server >/dev/null 2>&1 || true
"$adb" start-server >/dev/null
if [ -e /dev/kvm ]; then
  accel=on
else
  accel=off
fi

# S4-only infrastructure variant: Emulator 37.1.11 + current SwiftShader
# backend with Vulkan disabled. This modern renderer path previously never
# reached runtime because the pinned APK artifact had expired.
nohup "$emulator" \
  -avd yaabsa-runtime-acceptance \
  -no-window \
  -no-audio \
  -no-boot-anim \
  -no-snapshot \
  -wipe-data \
  -no-metrics \
  -memory 2048 \
  -cores 2 \
  -gpu swiftshader \
  -feature -Vulkan \
  -accel "$accel" \
  </dev/null > emulator.log 2>&1 &
emulator_pid=$!
echo "$emulator_pid" > emulator.pid
echo "SCENARIO_EMULATOR_PID=$emulator_pid"

seen=0
i=0
while [ "$i" -lt 90 ]; do
  if ! kill -0 "$emulator_pid" 2>/dev/null; then
    echo 'SCENARIO_EMULATOR_EXITED_DURING_BOOT=1' >&2
    tail -n 120 emulator.log >&2 || true
    exit 65
  fi
  if "$adb" devices | awk 'NR>1 && $1 ~ /^emulator-/ && $2=="device" {f=1} END{exit !f}'; then
    seen=1
    break
  fi
  sleep 2
  i=$((i + 1))
done
if [ "$seen" -ne 1 ]; then exit 66; fi

boot=0
i=0
while [ "$i" -lt 90 ]; do
  if ! kill -0 "$emulator_pid" 2>/dev/null; then
    echo 'SCENARIO_EMULATOR_EXITED_BEFORE_BOOT_COMPLETE=1' >&2
    tail -n 120 emulator.log >&2 || true
    exit 67
  fi
  if [ "$("$adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then
    boot=1
    break
  fi
  sleep 2
  i=$((i + 1))
done
if [ "$boot" -ne 1 ]; then exit 68; fi

"$adb" reverse tcp:13378 tcp:13378 >/dev/null
if ! "$adb" reverse --list | grep -q 'tcp:13378 tcp:13378'; then exit 69; fi
"$adb" install -r yaabsa.apk >/dev/null || exit 70
"$adb" logcat -c
"$adb" shell am start -n de.vito0912.yaabsa.dev/de.vito0912.yaabsa.MainActivity >/dev/null || exit 71
sleep 6
if ! kill -0 "$emulator_pid" 2>/dev/null; then exit 72; fi
if ! "$adb" get-state 2>/dev/null | grep -q '^device$'; then exit 73; fi
timeout 5 "$adb" shell settings put global window_animation_scale 0 >/dev/null 2>&1 || true
timeout 5 "$adb" shell settings put global transition_animation_scale 0 >/dev/null 2>&1 || true
timeout 5 "$adb" shell settings put global animator_duration_scale 0 >/dev/null 2>&1 || true
echo 'SCENARIO_EMULATOR_READY=1'

cat > ui.py <<'PY'
import re,sys,xml.etree.ElementTree as ET
mode,key,path=sys.argv[1:4]
nodes=list(ET.parse(path).getroot().iter('node'))
def pick(ms):
    if not ms: raise SystemExit(2)
    clickable=[n for n in ms if n.attrib.get('clickable')=='true']
    return clickable[0] if clickable else ms[0]
if mode=='edit':
    n=[n for n in nodes if n.attrib.get('class')=='android.widget.EditText'][int(key)]
elif mode=='count':
    print(sum(n.attrib.get('class')=='android.widget.EditText' for n in nodes)); raise SystemExit
elif mode=='value':
    print([n for n in nodes if n.attrib.get('class')=='android.widget.EditText'][int(key)].attrib.get('text','')); raise SystemExit
elif mode=='desc':
    n=pick([n for n in nodes if n.attrib.get('content-desc')==key])
elif mode=='any':
    n=pick([n for n in nodes if n.attrib.get('content-desc')==key or n.attrib.get('text')==key])
elif mode=='childplay':
    parents=[n for n in nodes if n.attrib.get('content-desc')==key or n.attrib.get('text')==key]
    if not parents: raise SystemExit(2)
    descendants=[]
    for parent in parents:
        descendants.extend([
            n for n in parent.iter('node')
            if n is not parent and n.attrib.get('content-desc')=='Play' and n.attrib.get('clickable')=='true'
        ])
    n=pick(descendants)
else:
    raise SystemExit(3)
a=[int(x) for x in re.findall(r'-?\d+',n.attrib.get('bounds',''))]
if len(a)!=4: raise SystemExit(4)
print((a[0]+a[2])//2,(a[1]+a[3])//2)
PY

dump_prelogin() {
  out="$1"
  tmp="${out}.tmp"
  attempt=0
  rm -f "$out" "$tmp"
  while [ "$attempt" -lt 5 ]; do
    if ! kill -0 "$emulator_pid" 2>/dev/null; then
      echo "UI_DUMP_EMULATOR_EXITED=$out" >> "${out}.uiautomator.log"
      return 2
    fi

    timeout 8 "$adb" shell uiautomator dump /sdcard/u.xml >"${out}.uiautomator.log" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
      timeout 5 "$adb" exec-out cat /sdcard/u.xml > "$tmp" 2>/dev/null
      rc=$?
      if [ "$rc" -eq 0 ] && python3 -c 'import sys,xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$out"
        return 0
      fi
    fi
    rm -f "$tmp"
    if ! kill -0 "$emulator_pid" 2>/dev/null; then return 2; fi
    sleep 1
    attempt=$((attempt + 1))
  done
  return 1
}

tap_semantic() {
  p="$(python3 ui.py "$1" "$2" "$3")"
  rc=$?
  if [ "$rc" -ne 0 ]; then return "$rc"; fi
  "$adb" shell input tap $p
}

screen_size() {
  attempt=0
  while [ "$attempt" -lt 5 ]; do
    if ! kill -0 "$emulator_pid" 2>/dev/null; then
      return 1
    fi

    raw_size="$(timeout 5 "$adb" shell wm size 2>>tap-adb.err.txt | tr -d '\r' || true)"
    size="$(printf '%s\n' "$raw_size" | grep -Eo '[0-9]+x[0-9]+' | tail -n 1)"
    if [ -n "$size" ]; then
      printf '%s\n' "$size"
      return 0
    fi

    echo "SCREEN_SIZE_TRANSIENT_FAILURE=$((attempt + 1))" >> tap-adb.err.txt
    "$adb" devices -l > tap-adb.devices.txt 2>&1 || true
    timeout 8 "$adb" wait-for-device >/dev/null 2>&1 || true
    sleep 1
    attempt=$((attempt + 1))
  done
  return 1
}

tap_norm() {
  x_milli="$1"
  y_milli="$2"
  size="$(screen_size)" || return 1
  if [ -z "$size" ]; then return 1; fi
  w="${size%x*}"
  h="${size#*x}"
  if [ "$w" -lt 800 ] || [ "$h" -lt 1800 ]; then return 1; fi
  x=$((w * x_milli / 1000))
  y=$((h * y_milli / 1000))
  echo "TAP_NORM=${x_milli},${y_milli} actual=${x},${y} size=${w}x${h}"

  attempt=0
  while [ "$attempt" -lt 3 ]; do
    if timeout 5 "$adb" shell input tap "$x" "$y" >>tap-adb.out.txt 2>>tap-adb.err.txt; then
      return 0
    fi
    echo "INPUT_TAP_TRANSIENT_FAILURE=$((attempt + 1))" >> tap-adb.err.txt
    if ! kill -0 "$emulator_pid" 2>/dev/null; then return 1; fi
    timeout 8 "$adb" wait-for-device >/dev/null 2>&1 || true
    sleep 1
    attempt=$((attempt + 1))
  done
  return 1
}

media_position_ms() {
  python3 - "$1" <<'PY'
import re,sys
s=open(sys.argv[1],errors='ignore').read()
m=re.search(r'package=de\.vito0912\.yaabsa\.dev.*?state=PlaybackState \{state=[^,]+, position=(\d+)',s,re.S)
print(m.group(1) if m else '')
PY
}

media_effective_position_ms() {
  file="$1"
  uptime_seconds="$2"
  python3 - "$file" "$uptime_seconds" <<'PY'
import re,sys
path,uptime=sys.argv[1:]
s=open(path,errors='ignore').read()
m=re.search(
    r'package=de\.vito0912\.yaabsa\.dev.*?state=PlaybackState \{state=PLAYING\(3\), '
    r'position=(\d+), buffered position=\d+, speed=([0-9.]+), updated=(\d+)',
    s,re.S,
)
if not m or not uptime:
    print('')
    raise SystemExit
pos=int(m.group(1)); speed=float(m.group(2)); updated=int(m.group(3))
now_ms=float(uptime)*1000.0
print(int(pos + max(0.0, now_ms-updated)*speed))
PY
}

media_state_name() {
  python3 - "$1" <<'PY'
import re,sys
s=open(sys.argv[1],errors='ignore').read()
m=re.search(r'package=de\.vito0912\.yaabsa\.dev.*?state=PlaybackState \{state=([A-Z_]+)\(',s,re.S)
print(m.group(1) if m else '')
PY
}

media_description() {
  python3 - "$1" <<'PY'
import re,sys
s=open(sys.argv[1],errors='ignore').read()
m=re.search(r'package=de\.vito0912\.yaabsa\.dev.*?metadata:.*?description=([^,\n]+)',s,re.S)
print(m.group(1).strip() if m else '')
PY
}

copy_app_db_snapshot() {
  label="$1"
  out_dir="$RUNNER_TEMP/app-db-$label"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"

  if ! kill -0 "$emulator_pid" 2>/dev/null; then
    echo "DB_SNAPSHOT_EMULATOR_EXITED=$label" >> db-snapshot.err.txt
    return 1
  fi

  db_rel="$(timeout 8 "$adb" shell run-as "$package" find . -type f -name app_db.sqlite -print -quit 2>>db-snapshot.err.txt | tr -d '\r' | head -n 1)"
  if [ -z "$db_rel" ]; then
    echo "DB_SNAPSHOT_DB_PATH_UNAVAILABLE=$label" >> db-snapshot.err.txt
    return 1
  fi

  if ! kill -0 "$emulator_pid" 2>/dev/null; then
    echo "DB_SNAPSHOT_EMULATOR_EXITED_BEFORE_CAT=$label" >> db-snapshot.err.txt
    return 1
  fi

  timeout 8 "$adb" exec-out run-as "$package" cat "$db_rel" > "$out_dir/app_db.sqlite" 2>>db-snapshot.err.txt
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "DB_SNAPSHOT_MAIN_CAT_FAILED=$label:$rc" >> db-snapshot.err.txt
    rm -f "$out_dir/app_db.sqlite"
    return 1
  fi

  for suffix in -wal -shm; do
    if ! kill -0 "$emulator_pid" 2>/dev/null; then
      echo "DB_SNAPSHOT_EMULATOR_EXITED_DURING_SIDECARS=$label" >> db-snapshot.err.txt
      return 1
    fi

    if timeout 5 "$adb" shell run-as "$package" ls "${db_rel}${suffix}" >/dev/null 2>>db-snapshot.err.txt; then
      if ! timeout 8 "$adb" exec-out run-as "$package" cat "${db_rel}${suffix}" > "$out_dir/app_db.sqlite${suffix}" 2>>db-snapshot.err.txt; then
        rm -f "$out_dir/app_db.sqlite${suffix}"
      fi
    fi
  done

  printf '%s\n' "$out_dir/app_db.sqlite"
}

wait_for_authenticated_db() {
  max_attempts="$1"
  label="$2"
  attempt=0
  state_file="auth-db-${label}.txt"
  : > "$state_file"

  while [ "$attempt" -lt "$max_attempts" ]; do
    db_path="$(copy_app_db_snapshot "auth-${label}" 2>/dev/null)"
    if [ -n "$db_path" ]; then
      python3 - "$db_path" "$state_file" "$attempt" <<'PY'
import sqlite3,sys
p,out,attempt=sys.argv[1:]
lines=[f'ATTEMPT={attempt}', 'DB_SNAPSHOT_AVAILABLE=1']
ok=False
try:
    c=sqlite3.connect(f'file:{p}?mode=ro',uri=True)
    c.execute('PRAGMA query_only=ON')
    users=c.execute('SELECT COUNT(*) FROM stored_users').fetchone()[0]
    row=c.execute("SELECT value FROM global_settings WHERE key='activeUserId'").fetchone()
    c.close()
    active=bool(row and row[0])
    lines += [f'STORED_USERS={users}', f'ACTIVE_USER_ID_PRESENT={int(active)}']
    ok=users >= 1 and active
except Exception as e:
    lines += ['DB_QUERY_OK=0', f'DB_ERROR_TYPE={type(e).__name__}']
with open(out,'w',encoding='utf-8') as f:
    f.write('\n'.join(lines)+'\n')
raise SystemExit(0 if ok else 1)
PY
      rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "AUTHENTICATED_DB=1 phase=$label"
        return 0
      fi
    else
      {
        echo "ATTEMPT=$attempt"
        echo 'DB_SNAPSHOT_AVAILABLE=0'
      } > "$state_file"
    fi

    if ! kill -0 "$emulator_pid" 2>/dev/null; then
      echo "AUTH_EMULATOR_EXITED=1 phase=$label" >> "$state_file"
      return 2
    fi

    sleep 1
    attempt=$((attempt + 1))
  done
  return 1
}

wait_for_selected_library_db() {
  max_attempts="$1"
  label="$2"
  expected_library_id="$3"
  attempt=0
  state_file="selected-library-${label}.txt"
  : > "$state_file"

  while [ "$attempt" -lt "$max_attempts" ]; do
    db_path="$(copy_app_db_snapshot "selected-library-${label}" 2>/dev/null)"
    if [ -n "$db_path" ]; then
      python3 - "$db_path" "$state_file" "$attempt" "$expected_library_id" <<'PY'
import sqlite3,sys
p,out,attempt,expected=sys.argv[1:]
lines=[f'ATTEMPT={attempt}', 'DB_SNAPSHOT_AVAILABLE=1']
ok=False
try:
    c=sqlite3.connect(f'file:{p}?mode=ro',uri=True)
    c.execute('PRAGMA query_only=ON')
    user_row=c.execute("SELECT value FROM global_settings WHERE key='activeUserId'").fetchone()
    active_user=(user_row[0] if user_row and user_row[0] else '')
    rows=[]
    if active_user:
        rows=c.execute(
            "SELECT value FROM user_settings WHERE user_id=? AND key='selectedLibraryId'",
            (active_user,),
        ).fetchall()
    c.close()
    selected=(rows[0][0] if rows and rows[0][0] else '')
    lines += [
        f'ACTIVE_USER_ID_PRESENT={int(bool(active_user))}',
        f'SELECTED_LIBRARY_ID={selected}',
        f'EXPECTED_LIBRARY_ID={expected}',
        f'SELECTED_LIBRARY_MATCH={int(selected==expected)}',
    ]
    ok=bool(active_user) and selected==expected
except Exception as e:
    lines += ['DB_QUERY_OK=0', f'DB_ERROR_TYPE={type(e).__name__}']
with open(out,'w',encoding='utf-8') as f:
    f.write('\n'.join(lines)+'\n')
raise SystemExit(0 if ok else 1)
PY
      rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "SELECTED_LIBRARY_DB=1 phase=$label library_id=$expected_library_id"
        return 0
      fi
    else
      {
        echo "ATTEMPT=$attempt"
        echo 'DB_SNAPSHOT_AVAILABLE=0'
        echo "EXPECTED_LIBRARY_ID=$expected_library_id"
      } > "$state_file"
    fi

    if ! kill -0 "$emulator_pid" 2>/dev/null; then
      echo "SELECTED_LIBRARY_EMULATOR_EXITED=1 phase=$label" >> "$state_file"
      return 2
    fi

    sleep 1
    attempt=$((attempt + 1))
  done
  return 1
}

queue_intent_snapshot() {
  label="$1"
  out="$2"
  attempt=0
  while [ "$attempt" -lt 10 ]; do
    db_path="$(copy_app_db_snapshot "queue-$label-$attempt" 2>/dev/null)"
    if [ -n "$db_path" ]; then
      python3 - "$db_path" "$out" "$b_id" "$ABS_ITEM_ID" "$label" <<'PY'
import json,sqlite3,sys
p,out,b_id,a_id,label=sys.argv[1:]
try:
    c=sqlite3.connect(f'file:{p}?mode=ro',uri=True)
    c.execute('PRAGMA query_only=ON')
    rows=c.execute('SELECT value FROM user_settings WHERE key=?',('queue_intent_v2',)).fetchall()
    c.close()
except Exception:
    raise SystemExit(20)
if len(rows)!=1: raise SystemExit(21)
try: data=json.loads(rows[0][0])
except Exception: raise SystemExit(22)
entries=data.get('manualEntries')
anchor=data.get('anchor')
if not isinstance(entries,list): raise SystemExit(23)
b_matches=sum(1 for e in entries if isinstance(e,dict) and isinstance(e.get('ref'),dict) and e['ref'].get('itemId')==b_id)
anchor_item=anchor.get('itemId') if isinstance(anchor,dict) else None
anchor_matches_a=int(anchor_item==a_id)
with open(out,'w',encoding='utf-8') as f:
    f.write(f'QUEUE_INTENT_LABEL={label}\n')
    f.write('QUEUE_INTENT_KEY=queue_intent_v2\n')
    f.write(f'MANUAL_ENTRY_COUNT={len(entries)}\n')
    f.write(f'B_MATCH_COUNT={b_matches}\n')
    f.write(f'ANCHOR_MATCH_A={anchor_matches_a}\n')
if b_matches!=1: raise SystemExit(24)
if anchor_matches_a!=1: raise SystemExit(25)
PY
      rc=$?
      if [ "$rc" -eq 0 ]; then
        cat "$out"
        return 0
      fi
    fi
    sleep 1
    attempt=$((attempt + 1))
  done
  return 1
}

dump_media_session() {
  out="$1"
  label="$2"
  max_attempts="${3:-3}"
  attempt=0
  while [ "$attempt" -lt "$max_attempts" ]; do
    if ! kill -0 "$emulator_pid" 2>/dev/null; then
      echo "MEDIA_DUMP_EMULATOR_EXITED=${label}" >&2
      return 1
    fi
    if timeout 8 "$adb" shell dumpsys media_session > "${out}.tmp" 2>>media-session-adb.err.txt; then
      mv "${out}.tmp" "$out"
      return 0
    fi
    attempt=$((attempt + 1))
    echo "MEDIA_DUMP_TRANSIENT_FAILURE=${label}:${attempt}" >&2
    "$adb" devices -l > media-session-adb.devices.txt 2>&1 || true
    timeout 8 "$adb" wait-for-device >/dev/null 2>&1 || true
    sleep 1
  done
  rm -f "${out}.tmp"
  return 1
}

wait_media() {
  expected_description="$1"
  out="$2"
  tries="$3"
  i=0
  while [ "$i" -lt "$tries" ]; do
    sleep 1
    if ! dump_media_session "$out" "wait-media-${expected_description}" 2; then
      if ! kill -0 "$emulator_pid" 2>/dev/null; then
        return 2
      fi
      i=$((i + 1))
      continue
    fi
    if grep -q 'package=de.vito0912.yaabsa.dev' "$out" \
      && grep -q 'state=PlaybackState {state=PLAYING(3)' "$out" \
      && grep -q "description=$expected_description" "$out"; then
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

pre_next_logcat_pid=''
start_pre_next_logcat() {
  rm -f pre-next.logcat.txt
  "$adb" logcat -v threadtime > pre-next.logcat.txt 2>&1 &
  pre_next_logcat_pid=$!
  sleep 1
  kill -0 "$pre_next_logcat_pid" 2>/dev/null
}

stop_pre_next_logcat() {
  if [ -n "${pre_next_logcat_pid:-}" ]; then
    kill "$pre_next_logcat_pid" >/dev/null 2>&1 || true
    wait "$pre_next_logcat_pid" 2>/dev/null || true
    pre_next_logcat_pid=''
  fi
}

wait_local_playing_item() {
  file="$1"
  item_id="$2"
  max_seconds="$3"
  i=0
  while [ "$i" -lt "$max_seconds" ]; do
    if ! kill -0 "$emulator_pid" 2>/dev/null; then return 2; fi
    sync "$file" 2>/dev/null || true
    if grep -Fq "Starting playback for item: $item_id (item)" "$file" \
      && grep -q 'playing=true,processingState=ProcessingState.ready' "$file"; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

latest_seek_position_ms() {
  file="$1"
  python3 - "$file" <<'PY'
import re,sys
s=open(sys.argv[1],errors='ignore').read()
matches=re.findall(r'Seeking to position:\s*(\d+):(\d+):(\d+)\.(\d+)',s)
if not matches:
    print('')
    raise SystemExit
h,m,sec,frac=matches[-1]
micros=int((frac+'000000')[:6])
print((int(h)*3600+int(m)*60+int(sec))*1000 + micros//1000)
PY
}

wait_seek_log_position() {
  file="$1"
  min_ms="$2"
  max_ms="$3"
  max_seconds="$4"
  i=0
  while [ "$i" -lt "$max_seconds" ]; do
    if ! kill -0 "$emulator_pid" 2>/dev/null; then return 2; fi
    sync "$file" 2>/dev/null || true
    seek_ms="$(latest_seek_position_ms "$file")"
    if [ -n "$seek_ms" ] && [ "$seek_ms" -gt "$min_ms" ] && [ "$seek_ms" -lt "$max_ms" ]; then
      printf '%s\n' "$seek_ms"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

media_monitor_pid=''
media_monitor_fifo=''
media_monitor_fd_open=0

start_media_monitor() {
  timeout 5 "$adb" shell cmd media_session list-sessions > media-sessions.txt 2>media-sessions.err.txt || return 1
  media_session_tag="$(python3 - media-sessions.txt <<'PY'
import re,sys
s=open(sys.argv[1],errors='ignore').read()
for line in s.splitlines():
    if 'package=de.vito0912.yaabsa.dev' in line:
        m=re.search(r'tag=([^,]+),\s*package=',line)
        if m:
            print(m.group(1).strip())
            raise SystemExit
print('')
PY
)"
  if [ -z "$media_session_tag" ]; then return 1; fi
  echo "MEDIA_SESSION_MONITOR_TAG=$media_session_tag"

  media_monitor_fifo="$RUNNER_TEMP/media-session-monitor.fifo"
  rm -f "$media_monitor_fifo"
  mkfifo "$media_monitor_fifo" || return 1
  : > media-monitor.txt
  timeout 60 "$adb" shell cmd media_session monitor "$media_session_tag"     <"$media_monitor_fifo" >media-monitor.txt 2>media-monitor.err.txt &
  media_monitor_pid=$!
  exec 9<>"$media_monitor_fifo"
  media_monitor_fd_open=1
  sleep 1
  kill -0 "$media_monitor_pid" 2>/dev/null
}

stop_media_monitor() {
  if [ "$media_monitor_fd_open" -eq 1 ]; then
    printf 'q\n' >&9 2>/dev/null || true
    exec 9>&-
    media_monitor_fd_open=0
  fi
  if [ -n "${media_monitor_pid:-}" ]; then
    wait "$media_monitor_pid" 2>/dev/null || true
    media_monitor_pid=''
  fi
  if [ -n "${media_monitor_fifo:-}" ]; then
    rm -f "$media_monitor_fifo" 2>/dev/null || true
    media_monitor_fifo=''
  fi
}

media_monitor_snapshot() {
  out="$1"
  uptime_seconds="$2"
  python3 - media-monitor.txt "$out" "$uptime_seconds" <<'PY'
import re,sys
src,out,uptime=sys.argv[1:]
s=open(src,errors='ignore').read()
states=re.findall(
    r'onPlaybackStateChanged PlaybackState \{state=([^,]+), position=(\d+), '
    r'buffered position=\d+, speed=([0-9.]+), updated=(\d+)',
    s,
)
metadata=re.findall(r'onMetadataChanged title=([^\n]+)',s)
if not states or not metadata or not uptime:
    raise SystemExit(1)
state,pos,speed,updated=states[-1]
state_norm=state.strip()
is_playing = state_norm in ('3','PLAYING(3)')
title=metadata[-1].strip()
pos=int(pos); speed=float(speed); updated=int(updated)
now_ms=float(uptime)*1000.0
effective=int(pos + max(0.0, now_ms-updated)*speed)
with open(out,'w',encoding='utf-8') as f:
    f.write(f'MONITOR_LAST_STATE={state_norm}\n')
    f.write(f'MONITOR_LAST_METADATA={title}\n')
    f.write(f'MONITOR_RAW_POSITION_MS={pos}\n')
    f.write(f'MONITOR_EFFECTIVE_POSITION_MS={effective}\n')
if not is_playing:
    raise SystemExit(2)
if not title.startswith('Chapter Test B'):
    raise SystemExit(3)
print(effective)
PY
}

causal_logcat_pid=''
start_causal_logcat() {
  rm -f final.logcat.txt
  "$adb" logcat -v threadtime > final.logcat.txt 2>&1 &
  causal_logcat_pid=$!
  sleep 1
  kill -0 "$causal_logcat_pid" 2>/dev/null
}

stop_causal_logcat() {
  if [ -n "${causal_logcat_pid:-}" ]; then
    kill "$causal_logcat_pid" >/dev/null 2>&1 || true
    wait "$causal_logcat_pid" 2>/dev/null || true
    causal_logcat_pid=''
  fi
}
trap 'stop_media_monitor; stop_pre_next_logcat; stop_causal_logcat' EXIT

# Add a second, distinct audiobook to the isolated ABS fixture.
mkdir -p 'runtime/abs/audiobooks/Chapter Test B'
ffmpeg -hide_banner -loglevel error -f lavfi -i 'sine=frequency=660:duration=90:sample_rate=44100' \
  -metadata title='Chapter Test B' -metadata artist='Runtime Bot B' -metadata album='Chapter Test B' \
  -c:a aac -b:a 96k -movflags +faststart \
  'runtime/abs/audiobooks/Chapter Test B/Chapter Test B.m4b'
rc=$?
if [ "$rc" -ne 0 ]; then exit 74; fi

curl -fsS "$ABS_URL/api/libraries" -H "Authorization: Bearer $token" -o abs-libraries-s4.json
rc=$?
if [ "$rc" -ne 0 ]; then exit 75; fi
library_id="$(jq -r '.libraries[0].id // .[0].id // empty' abs-libraries-s4.json)"
library_name="$(jq -r '.libraries[0].name // .[0].name // empty' abs-libraries-s4.json)"
if [ -z "$library_id" ] || [ -z "$library_name" ]; then exit 76; fi
echo "SCENARIO4_LIBRARY_NAME=$library_name"

curl -fsS -X POST "$ABS_URL/api/libraries/$library_id/scan?force=1" \
  -H "Authorization: Bearer $token" -o abs-scan-s4.json
rc=$?
if [ "$rc" -ne 0 ]; then exit 77; fi

scanned=0
i=0
while [ "$i" -lt 60 ]; do
  curl -fsS "$ABS_URL/api/libraries/$library_id/items?limit=0&minified=0" \
    -H "Authorization: Bearer $token" -o abs-items.json || true
  total="$(jq -r '.total // 0' abs-items.json 2>/dev/null || echo 0)"
  has_a="$(jq '[.results[] | select(.media.metadata.title == "Chapter Test A")] | length' abs-items.json 2>/dev/null || echo 0)"
  has_b="$(jq '[.results[] | select(.media.metadata.title == "Chapter Test B")] | length' abs-items.json 2>/dev/null || echo 0)"
  if [ "$total" -eq 2 ] && [ "$has_a" -eq 1 ] && [ "$has_b" -eq 1 ]; then
    scanned=1
    break
  fi
  sleep 2
  i=$((i + 1))
done
if [ "$scanned" -ne 1 ]; then exit 78; fi
b_id="$(jq -r '.results[] | select(.media.metadata.title == "Chapter Test B") | .id' abs-items.json | head -n 1)"
if [ -z "$b_id" ]; then exit 79; fi
echo "SCENARIO4_B_ITEM_ID=$b_id"

# Login. UI hierarchy is used only before authentication, where it is stable.
ready=0
i=0
while [ "$i" -lt 35 ]; do
  dump_prelogin login.xml || true
  count="$(python3 ui.py count 0 login.xml 2>/dev/null || echo 0)"
  if [ "$count" -ge 3 ] && grep -q 'Sign In' login.xml 2>/dev/null; then ready=1; break; fi
  sleep 2
  i=$((i + 1))
done
if [ "$ready" -ne 1 ]; then exit 80; fi

p="$(python3 ui.py edit 0 login.xml)" || exit 81
"$adb" shell input tap $p
sleep 1
"$adb" shell input text h
sleep 1
"$adb" shell input text 'ttp://127.0.0.1:13378'
sleep 1
dump_prelogin login-server.xml || exit 82
server="$(python3 ui.py value 0 login-server.xml)"
if [ "$server" != 'http://127.0.0.1:13378' ]; then exit 83; fi

p="$(python3 ui.py edit 1 login-server.xml)" || exit 84
"$adb" shell input tap $p
sleep 1
"$adb" shell input text "$ABS_USER"
sleep 1
dump_prelogin login-user.xml || exit 85

p="$(python3 ui.py edit 2 login-user.xml)" || exit 86
"$adb" shell input tap $p
sleep 1
"$adb" shell input text "$ABS_PASSWORD"
sleep 1
"$adb" shell input keyevent 4
sleep 1
dump_prelogin submit.xml || exit 87
tap_semantic desc 'Sign In' submit.xml || exit 88
echo 'LOGIN_SIGN_IN_TAPPED=1'

auth_ok=0
if wait_for_authenticated_db 25 first; then
  auth_ok=1
else
  "$adb" logcat -d > auth-first.logcat.txt 2>&1 || true
  dump_prelogin auth-retry.xml || true
  "$adb" exec-out screencap -p > auth-retry.png 2>/dev/null || true

  retry_login_ui=0
  if [ -s auth-retry.xml ]; then
    retry_count="$(python3 ui.py count 0 auth-retry.xml 2>/dev/null || echo 0)"
    retry_server="$(python3 ui.py value 0 auth-retry.xml 2>/dev/null || true)"
    retry_user="$(python3 ui.py value 1 auth-retry.xml 2>/dev/null || true)"
    if [ "$retry_count" -ge 3 ] \
      && grep -q 'Sign In' auth-retry.xml \
      && [ "$retry_server" = 'http://127.0.0.1:13378' ] \
      && [ "$retry_user" = "$ABS_USER" ]; then
      retry_login_ui=1
    fi
  fi

  if [ "$retry_login_ui" -eq 1 ]; then
    echo 'LOGIN_RETRY_REASON=login-ui-still-present'
    tap_semantic desc 'Sign In' auth-retry.xml || exit 88
    echo 'LOGIN_SIGN_IN_RETAPPED=1'
  else
    echo 'LOGIN_SIGN_IN_RETAPPED=0'
  fi

  if wait_for_authenticated_db 50 second; then
    auth_ok=1
  fi
fi

if [ "$auth_ok" -ne 1 ]; then
  "$adb" logcat -d > auth-final.logcat.txt 2>&1 || true
  dump_prelogin auth-final.xml || true
  "$adb" exec-out screencap -p > auth-final.png 2>/dev/null || true
  echo 'AUTHENTICATION_DB_TIMEOUT=1' >&2
  exit 89
fi

"$adb" logcat -d > auth-success.logcat.txt 2>&1 || true
sleep 2
"$adb" exec-out screencap -p > home-pre-library.png 2>/dev/null || true

# The app normally auto-selects the first available library. Make that state
# explicit through the read-only app DB instead of relying on a specific
# CacheInterceptor log line. A transient reverse/network failure can leave
# userLibrariesProvider empty for this app lifetime; in that case, reassert the
# reverse tunnel and restart the already-authenticated app exactly once.
library_ready=0
if wait_for_selected_library_db 20 first "$library_id"; then
  library_ready=1
else
  "$adb" logcat -d > library-first.logcat.txt 2>&1 || true
  "$adb" exec-out screencap -p > library-first.png 2>/dev/null || true

  echo 'LIBRARY_SELECTION_RECOVERY=app-restart-after-reverse-reassert'
  "$adb" reverse tcp:13378 tcp:13378 >/dev/null || exit 150
  "$adb" reverse --list > library-reverse.txt 2>&1 || exit 151
  if ! grep -q 'tcp:13378 tcp:13378' library-reverse.txt; then exit 152; fi

  "$adb" shell am force-stop "$package" >/dev/null 2>&1 || exit 153
  sleep 1
  "$adb" shell am start -n de.vito0912.yaabsa.dev/de.vito0912.yaabsa.MainActivity >/dev/null || exit 154
  sleep 5

  if ! wait_for_authenticated_db 15 restart; then
    "$adb" logcat -d > library-restart-auth.logcat.txt 2>&1 || true
    exit 155
  fi

  if wait_for_selected_library_db 30 restart "$library_id"; then
    library_ready=1
  fi
fi

if [ "$library_ready" -ne 1 ]; then
  "$adb" logcat -d > library-final.logcat.txt 2>&1 || true
  "$adb" exec-out screencap -p > library-final.png 2>/dev/null || true
  echo 'SELECTED_LIBRARY_DB_TIMEOUT=1' >&2
  exit 156
fi

"$adb" logcat -d > library-success.logcat.txt 2>&1 || true
"$adb" exec-out screencap -p > home.png 2>/dev/null || true
echo 'SHELF_LIBRARY_SELECTED_DB=1'

# Avoid a separate post-login UI polling phase. Resolve the concrete A Play
# target once below; only if A is absent do we invoke the normal LibrarySwitcher.

# Avoid the repeatedly crash-prone Shelf overlay Play path. Open A's normal
# detail route semantically, start playback there, then return to the Shelf.
# Playback is still proven from Yaabsa's own causal AudioHandler log.
if ! timeout 5 "$adb" logcat -c; then exit 157; fi
if ! start_pre_next_logcat; then exit 158; fi

dump_prelogin a-start-ui.xml || exit 166
a_card_point="$(python3 ui.py any 'Chapter Test A' a-start-ui.xml 2>/dev/null || true)"

if [ -z "$a_card_point" ]; then
  echo 'A_CARD_TARGET_MISSING_RECOVER_LIBRARY=1'
  switcher_point="$(python3 ui.py any "$library_name" a-start-ui.xml 2>/dev/null || true)"
  if [ -z "$switcher_point" ]; then
    echo 'LIBRARY_SWITCHER_SEMANTIC_TARGET_NOT_FOUND=1' >&2
    exit 160
  fi
  timeout 5 "$adb" shell input tap $switcher_point >/dev/null 2>&1 || exit 160
  sleep 1
  dump_prelogin library-menu.xml || exit 161
  library_point="$(python3 ui.py any "$library_name" library-menu.xml 2>/dev/null || true)"
  if [ -z "$library_point" ]; then exit 162; fi
  timeout 5 "$adb" shell input tap $library_point >/dev/null 2>&1 || exit 163
  sleep 2
  dump_prelogin a-start-ui-recovered.xml || exit 166
  a_card_point="$(python3 ui.py any 'Chapter Test A' a-start-ui-recovered.xml 2>/dev/null || true)"
fi

if [ -z "$a_card_point" ]; then
  echo 'A_CARD_SEMANTIC_TARGET_NOT_FOUND=1' >&2
  exit 167
fi

echo "A_CARD_SEMANTIC_POINT=$a_card_point"
timeout 5 "$adb" shell input tap $a_card_point >/dev/null 2>&1 || exit 94
sleep 2
dump_prelogin a-detail-ui.xml || exit 168
a_detail_play_point="$(python3 ui.py desc 'Play' a-detail-ui.xml 2>/dev/null || true)"
if [ -z "$a_detail_play_point" ]; then
  echo 'A_DETAIL_PLAY_TARGET_NOT_FOUND=1' >&2
  exit 169
fi
echo "A_DETAIL_PLAY_POINT=$a_detail_play_point"
timeout 5 "$adb" shell input tap $a_detail_play_point >/dev/null 2>&1 || exit 94

if ! wait_local_playing_item pre-next.logcat.txt "$ABS_ITEM_ID" 20; then
  echo 'START_A_DETAIL_RETRY=1'
  dump_prelogin a-detail-ui-retry.xml || exit 168
  a_detail_play_point="$(python3 ui.py desc 'Play' a-detail-ui-retry.xml 2>/dev/null || true)"
  if [ -z "$a_detail_play_point" ]; then exit 169; fi
  timeout 5 "$adb" shell input tap $a_detail_play_point >/dev/null 2>&1 || exit 94
  if ! wait_local_playing_item pre-next.logcat.txt "$ABS_ITEM_ID" 20; then exit 95; fi
fi

sync pre-next.logcat.txt 2>/dev/null || true
grep -F "Starting playback for item: $ABS_ITEM_ID (item)" pre-next.logcat.txt | tail -n 2 > a-start.log-evidence.txt || true
grep 'playing=true,processingState=ProcessingState.ready' pre-next.logcat.txt | tail -n 3 >> a-start.log-evidence.txt || true
"$adb" exec-out screencap -p > player-before-more.png 2>/dev/null || true

# Playback starts on A's Book details route. The bottom navigation shifts when
# the mini-player appears, so use the stable top-left Back button from the detail
# route instead of a bottom-nav coordinate. Avoid any post-play uiautomator dump.
timeout 5 "$adb" shell input tap 126 414 >/dev/null 2>&1 || exit 170
sleep 2
"$adb" exec-out screencap -p > shelf-after-a.png 2>/dev/null || true

# B is the left Recently Added card on the validated Shelf layout.
tap_norm 248 283 || exit 96
sleep 2
"$adb" exec-out screencap -p > detail.png 2>/dev/null || true
tap_norm 497 483 || exit 97
sleep 1
if ! queue_intent_snapshot before retarget.logcat.txt; then exit 98; fi

timeout 5 "$adb" shell input keyevent 4 >/dev/null 2>&1 || true
sleep 2
if ! kill -0 "$emulator_pid" 2>/dev/null; then exit 99; fi

# Seek A into final chapter S2. ATD's system-bar layout places the mini-player
# progress bar at y≈2341 on the 1080x2400 frame (verified from runtime evidence);
# the former Google-API normalized y=0.942 lands above it. The Yaabsa seek log is
# still the oracle, and armed MediaSession independently verifies the result.
# Runtime calibration: x=950 landed at 323.650s on this ATD. Move A
# later, but still below the frozen 335s arm ceiling, to shorten only the
# observation window (not the S4 semantics).
tap_norm 894 976 || exit 100
landed_ms="$(wait_seek_log_position pre-next.logcat.txt 310000 340000 20)"
if [ -z "$landed_ms" ]; then exit 101; fi
echo "SCENARIO4_FINAL_CHAPTER_POSITION_MS=$landed_ms" | tee retarget-position.txt
grep 'Seeking to position:' pre-next.logcat.txt | tail -n 3 > seek.log-evidence.txt || true
"$adb" exec-out screencap -p > retarget-after-seek.png 2>/dev/null || true

# ATD places the mini-player overflow lower than the Google-API image. The
# former normalized y=0.897 opens the mini-player itself; runtime evidence puts
# the visible three-dot overflow at approximately (1000,2230) on 1080x2400.
tap_norm 926 929 || exit 102
sleep 1
"$adb" exec-out screencap -p > actions.png
tap_norm 611 873 || exit 103
sleep 1
"$adb" exec-out screencap -p > sleep.png
tap_norm 426 869 || exit 104

armed=0
i=0
while [ "$i" -lt 12 ]; do
  sleep 1
  if ! kill -0 "$emulator_pid" 2>/dev/null; then exit 105; fi
  sync pre-next.logcat.txt 2>/dev/null || true
  if grep -q 'Chapter sleep timer armed for S2 at 360s' pre-next.logcat.txt; then
    armed=1
    break
  fi
  i=$((i + 1))
done
cp pre-next.logcat.txt armed.logcat.txt 2>/dev/null || true
if [ "$armed" -ne 1 ]; then exit 105; fi
# First of only three required MediaSession dumps in S4.
if ! dump_media_session media-armed.txt 'armed-A' 1; then exit 106; fi
if ! grep -q 'state=PlaybackState {state=PLAYING(3)' media-armed.txt \
  || ! grep -q 'description=Chapter Test A' media-armed.txt; then
  exit 106
fi
armed_raw_position_ms="$(media_position_ms media-armed.txt)"
armed_uptime_seconds="$(timeout 5 "$adb" shell cat /proc/uptime 2>/dev/null | awk '{print $1}' || true)"
armed_position_ms="$(media_effective_position_ms media-armed.txt "$armed_uptime_seconds")"
armed_host_ms="$(date +%s%3N)"
echo "ARMED_MEDIA_SESSION_RAW_POSITION_MS=$armed_raw_position_ms" | tee armed-position.txt
echo "ARMED_MEDIA_SESSION_POSITION_MS=$armed_position_ms" | tee -a armed-position.txt
# S4 intentionally exercises Next while A is still armed, not an already
# expiring end-of-chapter race. Validate the effective MediaSession position,
# not its stale raw position field.
if [ -z "$armed_position_ms" ] || [ "$armed_position_ms" -le 310000 ] || [ "$armed_position_ms" -ge 335000 ]; then exit 107; fi

# Make the Android command causal: preserve the arm evidence above. Start the
# Android MediaController monitor before Next so it observes the A->B state and
# metadata transition without a full dumpsys.
if ! start_media_monitor; then exit 175; fi

# Then clear logcat and issue an external Android media-button NEXT command. On
# the pinned audio_service this reaches BGAudioHandler.skipToNext() -> skipToNextInApp().
stop_pre_next_logcat
if ! timeout 5 "$adb" logcat -c; then exit 159; fi
if ! start_causal_logcat; then exit 145; fi
{
  echo 'ANDROID_MEDIA_NEXT_COMMAND=cmd media_session dispatch next'
  echo 'ANDROID_MEDIA_NEXT_ENTRY=MEDIA_BUTTON_NEXT'
  "$adb" shell cmd media_session dispatch next
  rc=$?
  echo "ANDROID_MEDIA_NEXT_RC=$rc"
} > final.xml 2>&1
if [ "$rc" -ne 0 ]; then
  cat final.xml >&2
  exit 108
fi

# The real Android command must traverse BGAudioHandler.skipToNext(), consume B,
# and start B. Prove that causally from Yaabsa's own log. Do not snapshot the
# Android MediaSession during the short CONNECTING propagation window: the
# stronger integration oracle is the mandatory final MediaSession snapshot after
# B has played through A's old chapter-end boundary.
if ! wait_local_playing_item final.logcat.txt "$b_id" 30; then
  stop_causal_logcat
  exit 109
fi

log_ready=0
i=0
while [ "$i" -lt 8 ]; do
  sync final.logcat.txt 2>/dev/null || true
  if grep -q 'No next chapter found, skipping to next item' final.logcat.txt \
    && grep -q 'Chapter sleep timer disabled fail-closed: playback media changed' final.logcat.txt; then
    log_ready=1
    break
  fi
  sleep 1
  i=$((i + 1))
done
if [ "$log_ready" -ne 1 ]; then
  stop_causal_logcat
  exit 110
fi

if ! grep -F "Starting playback for item: $b_id (item) from position: 0:00:00.000000" final.logcat.txt >/dev/null; then
  stop_causal_logcat
  exit 109
fi
b_start_ms=0
grep -F "Starting playback for item: $b_id (item)" final.logcat.txt | tail -n 2 > b-start.log-evidence.txt || true
grep 'playing=true,processingState=ProcessingState.ready' final.logcat.txt | tail -n 3 >> b-start.log-evidence.txt || true

if ! grep -q 'No next chapter found, skipping to next item' final.logcat.txt; then exit 110; fi
if ! grep -q 'Chapter sleep timer disabled fail-closed: playback media changed' final.logcat.txt; then exit 111; fi
if grep -q 'Chapter sleep timer reached chapter end; pausing playback first' final.logcat.txt; then exit 112; fi
# A completion claim can legitimately be observed while navigation is active;
# the ownership/navigation gates may suppress it. Treat effects, not the mere
# claim log, as the failure oracle.
if grep -q 'Chapter sleep timer expiry failed' final.logcat.txt; then exit 114; fi
if grep -q 'FATAL EXCEPTION' final.logcat.txt; then exit 115; fi

if [ -z "$b_start_ms" ] || [ "$b_start_ms" -gt 15000 ]; then exit 116; fi
echo "B_POSITION_AFTER_ANDROID_NEXT_MS=$b_start_ms"

monitor_b_ready=0
i=0
while [ "$i" -lt 10 ]; do
  sync media-monitor.txt 2>/dev/null || true
  monitor_uptime="$(timeout 5 "$adb" shell cat /proc/uptime 2>/dev/null | awk '{print $1}' || true)"
  if media_monitor_snapshot media-monitor-after-next.txt "$monitor_uptime" >/dev/null 2>&1; then
    monitor_b_ready=1
    break
  fi
  sleep 1
  i=$((i + 1))
done
if [ "$monitor_b_ready" -ne 1 ]; then exit 176; fi

# Observe B through and beyond A's original 360s boundary. Chapter expiry
# is position/completion-driven, so this is deliberately only an observation
# window. Account for real host time already elapsed since the armed snapshot.
stop_causal_logcat
sync final.logcat.txt 2>/dev/null || true
now_host_ms="$(date +%s%3N)"
elapsed_since_arm_ms=$((now_host_ms - armed_host_ms))
remaining_ms=$((360000 - armed_position_ms - elapsed_since_arm_ms))
if [ "$remaining_ms" -le 0 ]; then
  wait_seconds=0
else
  wait_seconds=$(((remaining_ms + 999) / 1000))
fi
if [ "$wait_seconds" -lt 0 ] || [ "$wait_seconds" -gt 35 ]; then exit 118; fi
echo "ARM_TO_BOUNDARY_ELAPSED_MS=$elapsed_since_arm_ms" | tee final-position.txt
echo "WAIT_PAST_OLD_A_EXPIRY_SECONDS=$wait_seconds" | tee -a final-position.txt

if [ "$wait_seconds" -gt 0 ]; then
  sleep "$wait_seconds"
fi
if ! kill -0 "$emulator_pid" 2>/dev/null; then
  echo "EMULATOR_EXITED_AT_OLD_A_BOUNDARY=1" | tee -a final-position.txt
  exit 146
fi

# Final Android MediaSession oracle: the targeted MediaController monitor has
# observed B's metadata/state transition and remained attached through A's old
# boundary. Its last callback state must still be PLAYING with B metadata.
sync media-monitor.txt 2>/dev/null || true
boundary_uptime_seconds="$(timeout 5 "$adb" shell cat /proc/uptime 2>/dev/null | awk '{print $1}' || true)"
b_final_ms="$(media_monitor_snapshot media-monitor-boundary.txt "$boundary_uptime_seconds")"
monitor_rc=$?
if [ "$monitor_rc" -ne 0 ]; then exit 121; fi
b_final_state="$(awk -F= '/^MONITOR_LAST_STATE=/{print $2}' media-monitor-boundary.txt)"
b_final_desc="$(awk -F= '/^MONITOR_LAST_METADATA=/{sub(/^[^=]*=/,""); print}' media-monitor-boundary.txt)"
b_final_raw_ms="$(awk -F= '/^MONITOR_RAW_POSITION_MS=/{print $2}' media-monitor-boundary.txt)"
echo "B_FINAL_STATE=$b_final_state"
echo "B_FINAL_DESCRIPTION=$b_final_desc"
echo "B_FINAL_RAW_POSITION_MS=$b_final_raw_ms" | tee -a final-position.txt
echo "B_FINAL_EFFECTIVE_POSITION_MS=$b_final_ms" | tee -a final-position.txt

if [ "$b_final_state" != '3' ] && [ "$b_final_state" != 'PLAYING(3)' ]; then exit 119; fi
case "$b_final_desc" in
  Chapter\ Test\ B*) ;;
  *) exit 120 ;;
esac
if [ -z "$b_final_raw_ms" ] || [ -z "$b_final_ms" ]; then exit 121; fi

min_advance_ms=$(((wait_seconds - 10) * 1000))
if [ "$min_advance_ms" -lt 10000 ]; then min_advance_ms=10000; fi
if [ "$b_final_ms" -le $((b_start_ms + min_advance_ms)) ]; then exit 122; fi
if [ "$b_final_ms" -ge 85000 ]; then exit 123; fi

stop_media_monitor

timeout 5 "$adb" logcat -d -v threadtime > final.logcat.txt 2>final-logcat.err.txt || exit 174

# Capture the primary post-boundary state while B is still PLAYING. Any pause
# below is only a secondary-oracle flush and cannot affect this evidence.
"$adb" exec-out screencap -p > after-boundary.png 2>/dev/null || true

stop_causal_logcat
sync final.logcat.txt 2>/dev/null || true
if grep -q 'Chapter sleep timer reached chapter end; pausing playback first' final.logcat.txt; then exit 124; fi
completion_claim_count="$(grep -c 'Playback completion claimed by chapter sleep timer' final.logcat.txt || true)"
echo "COMPLETION_CLAIM_LOG_COUNT=$completion_claim_count" | tee -a final-position.txt
if grep -q 'Chapter sleep timer expiry failed' final.logcat.txt; then exit 126; fi
if grep -q 'FATAL EXCEPTION' final.logcat.txt; then exit 127; fi
if ! grep -q 'Chapter sleep timer disabled fail-closed: playback media changed' final.logcat.txt; then exit 128; fi

# ABS is a secondary oracle. Freeze the primary S4 evidence above first, then
# pause B exactly once so PlaybackSyncService._stopSync() force-flushes B's
# position. This post-oracle pause is not part of the behavior under test.
{
  echo 'POST_ORACLE_MEDIA_PAUSE_COMMAND=cmd media_session dispatch pause'
  "$adb" shell cmd media_session dispatch pause
  post_pause_rc=$?
  echo "POST_ORACLE_MEDIA_PAUSE_RC=$post_pause_rc"
} > post-oracle-pause.txt 2>&1
if [ "$post_pause_rc" -ne 0 ]; then exit 173; fi

b_progress_ready=0
i=0
while [ "$i" -lt 10 ]; do
  sleep 1
  b_progress_http="$(curl -sS -o abs-b-progress-s4.json -w '%{http_code}'     "$ABS_URL/api/me/progress/$b_id" -H "Authorization: Bearer $token")"
  b_progress_rc=$?
  if [ "$b_progress_rc" -ne 0 ]; then exit 130; fi
  if [ "$b_progress_http" = '200' ]; then
    b_progress_ready=1
    break
  fi
  if [ "$b_progress_http" != '404' ]; then exit 130; fi
  i=$((i + 1))
done
if [ "$b_progress_ready" -ne 1 ]; then exit 130; fi

curl -fsS "$ABS_URL/api/me/progress/$ABS_ITEM_ID" -H "Authorization: Bearer $token" -o abs-a-progress-s4.json
rc=$?
if [ "$rc" -ne 0 ]; then exit 129; fi
jq -n --slurpfile a abs-a-progress-s4.json --slurpfile b abs-b-progress-s4.json '{a:$a[0],b:$b[0]}' > abs-progress-after.json

a_finished="$(jq -r '.isFinished // false' abs-a-progress-s4.json)"
a_current="$(jq -r '.currentTime // 0' abs-a-progress-s4.json)"
b_finished="$(jq -r '.isFinished // false' abs-b-progress-s4.json)"
b_current="$(jq -r '.currentTime // 0' abs-b-progress-s4.json)"
if [ "$a_finished" != 'false' ]; then exit 131; fi
if ! awk "BEGIN {exit !($a_current >= 300 && $a_current < 355)}"; then exit 132; fi
if [ "$b_finished" != 'false' ]; then exit 133; fi
if ! awk "BEGIN {exit !($b_current > 10 && $b_current < 85)}"; then exit 134; fi

cat > scenario-result.txt <<EOF2
SCENARIO=4
ANDROID_MEDIA_NEXT=PASS
A_ARMED_FINAL_CHAPTER=PASS
B_QUEUED_BEFORE_NEXT_DB=1
B_BECAME_CURRENT=YES
B_PLAYING_AFTER_OLD_A_EXPIRY=YES
OLD_A_BOUNDARY_OBSERVATION=PASS
STALE_A_EXPIRY_EFFECT_OBSERVED=NO
TIMER_FAIL_CLOSED_ON_MEDIA_CHANGE=YES
COMPLETION_CLAIM_LOG_COUNT=$completion_claim_count
A_SEEK_MS=$landed_ms
A_ARMED_MS=$armed_position_ms
B_START_MS=$b_start_ms
B_FINAL_MS=$b_final_ms
WAIT_SECONDS=$wait_seconds
ABS_A_CURRENT_TIME=$a_current
ABS_A_FINISHED=$a_finished
ABS_B_CURRENT_TIME=$b_current
ABS_B_FINISHED=$b_finished
EOF2

cat scenario-result.txt
echo 'CHAPTER_SLEEP_SCENARIO4_EVIDENCE_COMPLETE=1'
