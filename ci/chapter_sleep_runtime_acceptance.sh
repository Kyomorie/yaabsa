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

# Keep the emulator in the same workflow step as the runtime scenario. Recent
# hosted-runner attempts lost the emulator process after the setup step had
# already completed, without any guest/QEMU crash evidence. Restarting it here
# removes that cross-step lifecycle dependency and caps resource usage.
emulator="${RUNTIME_SDK_ROOT}/emulator/emulator"
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
  -gpu swiftshader_indirect \
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
    "$adb" shell uiautomator dump /sdcard/u.xml >"${out}.uiautomator.log" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
      "$adb" exec-out cat /sdcard/u.xml > "$tmp" 2>/dev/null
      rc=$?
      if [ "$rc" -eq 0 ] && python3 -c 'import sys,xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$out"
        return 0
      fi
    fi
    rm -f "$tmp"
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
  "$adb" shell wm size | tr -d '\r' | grep -Eo '[0-9]+x[0-9]+' | tail -n 1
}

tap_norm() {
  x_milli="$1"
  y_milli="$2"
  size="$(screen_size)"
  if [ -z "$size" ]; then return 1; fi
  w="${size%x*}"
  h="${size#*x}"
  if [ "$w" -lt 800 ] || [ "$h" -lt 1800 ]; then return 1; fi
  x=$((w * x_milli / 1000))
  y=$((h * y_milli / 1000))
  echo "TAP_NORM=${x_milli},${y_milli} actual=${x},${y} size=${w}x${h}"
  "$adb" shell input tap "$x" "$y"
}

media_position_ms() {
  python3 - "$1" <<'PY'
import re,sys
s=open(sys.argv[1],errors='ignore').read()
m=re.search(r'package=de\.vito0912\.yaabsa\.dev.*?state=PlaybackState \{state=[^,]+, position=(\d+)',s,re.S)
print(m.group(1) if m else '')
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

  db_rel="$("$adb" shell run-as "$package" find . -type f -name app_db.sqlite -print -quit 2>/dev/null | tr -d '\r' | head -n 1)"
  if [ -z "$db_rel" ]; then
    return 1
  fi

  "$adb" exec-out run-as "$package" cat "$db_rel" > "$out_dir/app_db.sqlite" 2>/dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then return 1; fi

  for suffix in -wal -shm; do
    if "$adb" shell run-as "$package" ls "${db_rel}${suffix}" >/dev/null 2>&1; then
      "$adb" exec-out run-as "$package" cat "${db_rel}${suffix}" > "$out_dir/app_db.sqlite${suffix}" 2>/dev/null || rm -f "$out_dir/app_db.sqlite${suffix}"
    fi
  done

  printf '%s\n' "$out_dir/app_db.sqlite"
}

wait_for_authenticated_db() {
  attempt=0
  while [ "$attempt" -lt 60 ]; do
    db_path="$(copy_app_db_snapshot auth 2>/dev/null)"
    if [ -n "$db_path" ]; then
      python3 - "$db_path" <<'PY' >/dev/null 2>&1
import sqlite3,sys
p=sys.argv[1]
try:
    c=sqlite3.connect(f'file:{p}?mode=ro',uri=True)
    c.execute('PRAGMA query_only=ON')
    users=c.execute('SELECT COUNT(*) FROM stored_users').fetchone()[0]
    row=c.execute("SELECT value FROM global_settings WHERE key='activeUserId'").fetchone()
    c.close()
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if users >= 1 and row and row[0] else 1)
PY
      rc=$?
      if [ "$rc" -eq 0 ]; then
        echo 'AUTHENTICATED_DB=1'
        return 0
      fi
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

wait_media_a_playing() {
  out="$1"
  tries="$2"
  i=0
  while [ "$i" -lt "$tries" ]; do
    sleep 1
    "$adb" shell dumpsys media_session > "$out"
    if grep -q 'package=de.vito0912.yaabsa.dev' "$out" \
      && grep -q 'state=PlaybackState {state=PLAYING(3)' "$out" \
      && grep -q 'description=Chapter Test A' "$out"; then
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# Add a second, distinct audiobook to the isolated ABS fixture.
mkdir -p 'runtime/abs/audiobooks/Chapter Test B'
ffmpeg -hide_banner -loglevel error -f lavfi -i 'sine=frequency=660:duration=90:sample_rate=44100' \
  -metadata title='Chapter Test B' -metadata artist='Runtime Bot B' -metadata album='Chapter Test B' \
  -c:a aac -b:a 96k -movflags +faststart \
  'runtime/abs/audiobooks/Chapter Test B/Chapter Test B.m4b'
rc=$?
if [ "$rc" -ne 0 ]; then exit 62; fi

curl -fsS "$ABS_URL/api/libraries" -H "Authorization: Bearer $token" -o abs-libraries-s3.json
rc=$?
if [ "$rc" -ne 0 ]; then exit 63; fi
library_id="$(jq -r '.libraries[0].id // .[0].id // empty' abs-libraries-s3.json)"
if [ -z "$library_id" ]; then exit 64; fi

curl -fsS -X POST "$ABS_URL/api/libraries/$library_id/scan?force=1" \
  -H "Authorization: Bearer $token" -o abs-scan-s3.json
rc=$?
if [ "$rc" -ne 0 ]; then exit 65; fi

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
if [ "$scanned" -ne 1 ]; then exit 66; fi
b_id="$(jq -r '.results[] | select(.media.metadata.title == "Chapter Test B") | .id' abs-items.json | head -n 1)"
if [ -z "$b_id" ]; then exit 67; fi
echo "SCENARIO3_B_ITEM_ID=$b_id"

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
if [ "$ready" -ne 1 ]; then exit 68; fi

p="$(python3 ui.py edit 0 login.xml)" || exit 69
"$adb" shell input tap $p
sleep 1
"$adb" shell input text h
sleep 1
"$adb" shell input text 'ttp://127.0.0.1:13378'
sleep 1
dump_prelogin login-server.xml || exit 70
server="$(python3 ui.py value 0 login-server.xml)"
if [ "$server" != 'http://127.0.0.1:13378' ]; then exit 71; fi

p="$(python3 ui.py edit 1 login-server.xml)" || exit 72
"$adb" shell input tap $p
sleep 1
"$adb" shell input text "$ABS_USER"
sleep 1
dump_prelogin login-user.xml || exit 73

p="$(python3 ui.py edit 2 login-user.xml)" || exit 74
"$adb" shell input tap $p
sleep 1
"$adb" shell input text "$ABS_PASSWORD"
sleep 1
"$adb" shell input keyevent 4
sleep 1
dump_prelogin submit.xml || exit 75
tap_semantic desc 'Sign In' submit.xml || exit 76

if ! wait_for_authenticated_db; then exit 77; fi
sleep 2
"$adb" exec-out screencap -p > home.png

# Post-login Flutter semantics/uiautomator is flaky on hosted API35. From here,
# coordinates are inputs only. State is proven through MediaSession, logs and
# read-only queue_intent_v2 snapshots.
# Select Shelf, then start A from its validated Recently Added play overlay.
tap_norm 113 927 || exit 78
sleep 2
tap_norm 846 201 || exit 79
if ! wait_media_a_playing media-playing.txt 45; then exit 80; fi
"$adb" exec-out screencap -p > player-before-more.png

# B is the left Recently Added card. Open it, then hit the validated queue action.
tap_norm 248 283 || exit 81
sleep 2
"$adb" exec-out screencap -p > detail.png
tap_norm 497 483 || exit 82
sleep 1
if ! queue_intent_snapshot before queue-intent-before.txt; then exit 83; fi
cp queue-intent-before.txt retarget.logcat.txt
"$adb" exec-out screencap -p > retarget-before-seek.png

# Return to the shelf. Starting B is forbidden; A must still be current/playing.
"$adb" shell input keyevent 4 >/dev/null 2>&1 || true
sleep 2
if ! wait_media_a_playing media-before-seek.txt 5; then exit 84; fi

# Seek A into final chapter S2. Coordinate is input; MediaSession is the oracle.
tap_norm 880 942 || exit 85
seek_ok=0
i=0
while [ "$i" -lt 20 ]; do
  sleep 1
  "$adb" shell dumpsys media_session > media-retarget.txt
  landed_ms="$(media_position_ms media-retarget.txt)"
  if [ -n "$landed_ms" ] \
    && [ "$landed_ms" -gt 280000 ] \
    && [ "$landed_ms" -lt 350000 ] \
    && grep -q 'state=PlaybackState {state=PLAYING(3)' media-retarget.txt \
    && grep -q 'description=Chapter Test A' media-retarget.txt; then
    seek_ok=1
    break
  fi
  i=$((i + 1))
done
landed_ms="$(media_position_ms media-retarget.txt)"
echo "SCENARIO3_FINAL_CHAPTER_POSITION_MS=$landed_ms" | tee retarget-position.txt
if [ "$seek_ok" -ne 1 ]; then exit 86; fi
"$adb" exec-out screencap -p > retarget-after-seek.png

# Open player actions, Sleep timer, then End of chapter. Coordinates are from
# independently successful scenario-2 evidence and normalized to screen size.
tap_norm 927 897 || exit 87
sleep 1
"$adb" exec-out screencap -p > actions.png
tap_norm 611 873 || exit 88
sleep 1
"$adb" exec-out screencap -p > sleep.png
tap_norm 426 869 || exit 89

armed=0
i=0
while [ "$i" -lt 12 ]; do
  sleep 1
  "$adb" logcat -d > armed.logcat.txt
  if grep -q 'Chapter sleep timer armed for S2 at 360s' armed.logcat.txt; then
    armed=1
    break
  fi
  i=$((i + 1))
done
if [ "$armed" -ne 1 ]; then exit 90; fi
"$adb" shell dumpsys media_session > media-armed.txt
if ! grep -q 'state=PlaybackState {state=PLAYING(3)' media-armed.txt \
  || ! grep -q 'description=Chapter Test A' media-armed.txt; then
  exit 91
fi
position_ms="$(media_position_ms media-armed.txt)"
echo "ARMED_MEDIA_SESSION_POSITION_MS=$position_ms" | tee armed-position.txt
if [ -z "$position_ms" ] || [ "$position_ms" -le 180000 ] || [ "$position_ms" -ge 360000 ]; then exit 92; fi

expired=0
i=0
while [ "$i" -lt 55 ]; do
  sleep 5
  "$adb" logcat -d > final.logcat.txt
  if grep -q 'Chapter sleep timer reached chapter end; pausing playback first' final.logcat.txt; then
    expired=1
    break
  fi
  i=$((i + 1))
done
if [ "$expired" -ne 1 ]; then exit 93; fi

if ! grep -q 'Playback completion claimed by chapter sleep timer; suppressing queue/loop auto-advance.' final.logcat.txt; then exit 94; fi
if grep -q 'Chapter sleep timer expiry failed' final.logcat.txt; then exit 95; fi
if grep -q 'Chapter sleep timer expiry aborted' final.logcat.txt; then exit 96; fi
if grep -q 'Chapter sleep timer disabled fail-closed' final.logcat.txt; then exit 97; fi
if grep -q 'FATAL EXCEPTION' final.logcat.txt; then exit 98; fi

# A completed player may be exposed by audio_service as Android CONNECTING even
# though YAABSA has already reached playing=false + ProcessingState.completed.
# Accept CONNECTING only with that exact runtime completion evidence. Otherwise
# require an explicit PAUSED/STOPPED terminal MediaSession state. Never accept
# B becoming current or PLAYING after the chapter-expiry claim.
terminal_oracle=''
i=0
while [ "$i" -lt 12 ]; do
  "$adb" shell dumpsys media_session > media-after.txt
  media_state="$(media_state_name media-after.txt)"
  media_desc="$(media_description media-after.txt)"
  final_position_ms="$(media_position_ms media-after.txt)"
  echo "POST_EXPIRY_SAMPLE=${i} state=${media_state} description=${media_desc} position_ms=${final_position_ms}"

  if [ "$media_desc" != 'Chapter Test A' ]; then exit 99; fi
  if [ "$media_state" = 'PLAYING' ]; then exit 100; fi

  if [ "$media_state" = 'PAUSED' ] || [ "$media_state" = 'STOPPED' ]; then
    terminal_oracle="MEDIASESSION_${media_state}"
    break
  fi

  if [ "$media_state" = 'CONNECTING' ] \
    && grep -q 'playing=false,processingState=ProcessingState.completed' final.logcat.txt; then
    terminal_oracle='APP_COMPLETED_MEDIASESSION_CONNECTING'
    break
  fi

  sleep 1
  i=$((i + 1))
done
if [ -z "$terminal_oracle" ]; then exit 101; fi

"$adb" exec-out screencap -p > after-boundary.png
echo "TERMINAL_ORACLE=$terminal_oracle" | tee terminal-oracle.txt
echo "FINAL_POSITION_MS=$final_position_ms" | tee final-position.txt
if [ -z "$final_position_ms" ] || [ "$final_position_ms" -lt 355000 ] || [ "$final_position_ms" -gt 365000 ]; then exit 102; fi

sleep 1
if ! queue_intent_snapshot after queue-intent-after.txt; then exit 103; fi
cp queue-intent-after.txt final.xml
before_b_matches="$(awk -F= '$1=="B_MATCH_COUNT" {print $2}' queue-intent-before.txt)"
after_b_matches="$(awk -F= '$1=="B_MATCH_COUNT" {print $2}' queue-intent-after.txt)"
before_anchor="$(awk -F= '$1=="ANCHOR_MATCH_A" {print $2}' queue-intent-before.txt)"
after_anchor="$(awk -F= '$1=="ANCHOR_MATCH_A" {print $2}' queue-intent-after.txt)"

curl -fsS "$ABS_URL/api/me/progress/$ABS_ITEM_ID" -H "Authorization: Bearer $token" -o abs-progress-after.json
rc=$?
if [ "$rc" -ne 0 ]; then exit 104; fi
abs_current_time="$(jq -r '.currentTime // empty' abs-progress-after.json)"
abs_finished="$(jq -r '.isFinished // false' abs-progress-after.json)"
if [ -z "$abs_current_time" ] || ! awk "BEGIN {exit !($abs_current_time >= 355 && $abs_current_time <= 365)}"; then exit 105; fi
if [ "$abs_finished" != 'true' ]; then exit 106; fi

cat > scenario-result.txt <<EOF2
SCENARIO=3
A_FINAL_CHAPTER_EXPIRY=PASS
B_QUEUED_BEFORE_DB=$before_b_matches
B_QUEUED_AFTER_DB=$after_b_matches
ANCHOR_A_BEFORE_DB=$before_anchor
ANCHOR_A_AFTER_DB=$after_anchor
B_BECAME_CURRENT=NO
SEEK_LANDED_MS=$landed_ms
FINAL_MS=$final_position_ms
TERMINAL_ORACLE=$terminal_oracle
ABS_CURRENT_TIME=$abs_current_time
ABS_FINISHED=$abs_finished
EOF2

cat scenario-result.txt
echo 'CHAPTER_SLEEP_SCENARIO3_EVIDENCE_COMPLETE=1'