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

# Acceptance pins Emulator 36.3.10. Keep Vulkan disabled and use its
# pre-36.4.9 SwiftShader indirect GLES path to avoid the recurrent 37.1.11
# hosted-runner gfxstream host segfault.
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

wait_media() {
  expected_description="$1"
  out="$2"
  tries="$3"
  i=0
  while [ "$i" -lt "$tries" ]; do
    sleep 1
    "$adb" shell dumpsys media_session > "$out"
    if grep -q 'package=de.vito0912.yaabsa.dev' "$out" \
      && grep -q 'state=PlaybackState {state=PLAYING(3)' "$out" \
      && grep -q "description=$expected_description" "$out"; then
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
if [ "$rc" -ne 0 ]; then exit 74; fi

curl -fsS "$ABS_URL/api/libraries" -H "Authorization: Bearer $token" -o abs-libraries-s4.json
rc=$?
if [ "$rc" -ne 0 ]; then exit 75; fi
library_id="$(jq -r '.libraries[0].id // .[0].id // empty' abs-libraries-s4.json)"
if [ -z "$library_id" ]; then exit 76; fi

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

if ! wait_for_authenticated_db; then exit 89; fi
sleep 2
"$adb" exec-out screencap -p > home.png

# Post-login coordinates are inputs only. MediaSession, app logs, ABS and
# read-only DB snapshots are the acceptance oracles.
tap_norm 113 927 || exit 90
shelf_ready=0
adb_read_failures=0
i=0
while [ "$i" -lt 45 ]; do
  if ! kill -0 "$emulator_pid" 2>/dev/null; then
    echo 'SCENARIO_EMULATOR_EXITED_DURING_SHELF_LOAD=1' >&2
    exit 91
  fi

  if ! "$adb" logcat -d > shelf-ready.tmp.txt 2>shelf-ready.adb.err.txt; then
    adb_read_failures=$((adb_read_failures + 1))
    echo "SHELF_LOGCAT_TRANSIENT_FAILURE=$adb_read_failures" >&2
    "$adb" devices -l > shelf-ready.adb.devices.txt 2>&1 || true
    if [ "$adb_read_failures" -ge 5 ]; then
      echo 'SHELF_LOGCAT_PERSISTENT_FAILURE=1' >&2
      exit 92
    fi
    timeout 8 "$adb" wait-for-device >/dev/null 2>&1 || true
    sleep 1
    i=$((i + 1))
    continue
  fi

  adb_read_failures=0
  if grep -qE '\[CacheInterceptor\].*Caching: http://127\.0\.0\.1:13378/api/libraries/[^? ]+\?include=filterdata' shelf-ready.tmp.txt; then
    shelf_ready=1
    echo 'SHELF_DATA_READY=1'
    break
  fi
  sleep 1
  i=$((i + 1))
done
if [ "$shelf_ready" -ne 1 ]; then
  cp shelf-ready.tmp.txt final.logcat.txt 2>/dev/null || true
  echo 'SHELF_DATA_READY_TIMEOUT=1' >&2
  exit 93
fi
sleep 1

# Start A from its validated Recently Added play overlay.
tap_norm 846 201 || exit 94
if ! wait_media 'Chapter Test A' media-playing.txt 45; then exit 95; fi
"$adb" exec-out screencap -p > player-before-more.png

# Queue B manually while A remains current.
tap_norm 248 283 || exit 96
sleep 2
"$adb" exec-out screencap -p > detail.png
tap_norm 497 483 || exit 97
sleep 1
if ! queue_intent_snapshot before retarget.logcat.txt; then exit 98; fi

"$adb" shell input keyevent 4 >/dev/null 2>&1 || true
sleep 2
if ! wait_media 'Chapter Test A' media-before-seek.txt 5; then exit 99; fi

# Seek A into final chapter S2, then arm End of chapter.
tap_norm 880 942 || exit 100
seek_ok=0
i=0
while [ "$i" -lt 20 ]; do
  sleep 1
  "$adb" shell dumpsys media_session > media-retarget.txt
  landed_ms="$(media_position_ms media-retarget.txt)"
  if [ -n "$landed_ms" ] \
    && [ "$landed_ms" -gt 310000 ] \
    && [ "$landed_ms" -lt 340000 ] \
    && grep -q 'state=PlaybackState {state=PLAYING(3)' media-retarget.txt \
    && grep -q 'description=Chapter Test A' media-retarget.txt; then
    seek_ok=1
    break
  fi
  i=$((i + 1))
done
landed_ms="$(media_position_ms media-retarget.txt)"
echo "SCENARIO4_FINAL_CHAPTER_POSITION_MS=$landed_ms" | tee retarget-position.txt
if [ "$seek_ok" -ne 1 ]; then exit 101; fi
"$adb" exec-out screencap -p > retarget-after-seek.png

tap_norm 927 897 || exit 102
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
  "$adb" logcat -d > armed.logcat.txt
  if grep -q 'Chapter sleep timer armed for S2 at 360s' armed.logcat.txt; then
    armed=1
    break
  fi
  i=$((i + 1))
done
if [ "$armed" -ne 1 ]; then exit 105; fi
"$adb" shell dumpsys media_session > media-armed.txt
if ! grep -q 'state=PlaybackState {state=PLAYING(3)' media-armed.txt \
  || ! grep -q 'description=Chapter Test A' media-armed.txt; then
  exit 106
fi
armed_position_ms="$(media_position_ms media-armed.txt)"
echo "ARMED_MEDIA_SESSION_POSITION_MS=$armed_position_ms" | tee armed-position.txt
# S4 intentionally exercises Next while A is still armed, not an already
# expiring end-of-chapter race. Keep a meaningful margin before 360s.
if [ -z "$armed_position_ms" ] || [ "$armed_position_ms" -le 310000 ] || [ "$armed_position_ms" -ge 335000 ]; then exit 107; fi

# Make the Android command causal: preserve the arm evidence above, then clear
# logcat and issue an external Android media-button NEXT command. On the pinned
# audio_service this reaches BGAudioHandler.skipToNext() -> skipToNextInApp().
"$adb" logcat -c
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
# and make B the currently playing MediaSession item.
if ! wait_media 'Chapter Test B' media-b-after-next.tmp.txt 30; then
  "$adb" logcat -d > final.logcat.txt || true
  cp media-b-after-next.tmp.txt media-after.txt 2>/dev/null || true
  exit 109
fi
b_start_ms="$(media_position_ms media-b-after-next.tmp.txt)"
cp media-b-after-next.tmp.txt media-after.txt
"$adb" logcat -d > final.logcat.txt

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

# Observe B through and beyond A's original 360s boundary. This is an
# observation window, not proof that a stale A callback actually ran: chapter
# expiry is driven by position/completion events, not a separate wallclock timer.
remaining_ms=$((360000 - armed_position_ms))
if [ "$remaining_ms" -le 0 ]; then exit 117; fi
wait_seconds=$(((remaining_ms + 999) / 1000 + 8))
if [ "$wait_seconds" -lt 20 ] || [ "$wait_seconds" -gt 60 ]; then exit 118; fi
echo "WAIT_PAST_OLD_A_EXPIRY_SECONDS=$wait_seconds"

: > final-position.txt
elapsed=0
sample_index=0
previous_sample_ms="$b_start_ms"
while [ "$elapsed" -lt "$wait_seconds" ]; do
  step=5
  remaining=$((wait_seconds - elapsed))
  if [ "$remaining" -lt "$step" ]; then step="$remaining"; fi
  sleep "$step"
  elapsed=$((elapsed + step))
  sample_index=$((sample_index + 1))

  "$adb" shell dumpsys media_session > media-sample.tmp.txt || exit 135
  sample_state="$(media_state_name media-sample.tmp.txt)"
  sample_desc="$(media_description media-sample.tmp.txt)"
  sample_ms="$(media_position_ms media-sample.tmp.txt)"
  echo "B_SAMPLE_${sample_index}=elapsed:${elapsed}s,state:${sample_state},description:${sample_desc},position_ms:${sample_ms}" | tee -a final-position.txt

  if [ "$sample_state" != 'PLAYING' ]; then exit 136; fi
  if [ "$sample_desc" != 'Chapter Test B' ]; then exit 137; fi
  if [ -z "$sample_ms" ]; then exit 138; fi
  if [ "$sample_ms" -lt $((previous_sample_ms - 1500)) ]; then exit 139; fi
  previous_sample_ms="$sample_ms"
done

"$adb" shell dumpsys media_session > media-after.txt
b_final_state="$(media_state_name media-after.txt)"
b_final_desc="$(media_description media-after.txt)"
b_final_ms="$(media_position_ms media-after.txt)"
echo "B_FINAL_STATE=$b_final_state"
echo "B_FINAL_DESCRIPTION=$b_final_desc"
echo "B_FINAL_POSITION_MS=$b_final_ms" | tee -a final-position.txt

if [ "$b_final_state" != 'PLAYING' ]; then exit 119; fi
if [ "$b_final_desc" != 'Chapter Test B' ]; then exit 120; fi
if [ -z "$b_final_ms" ]; then exit 121; fi

min_advance_ms=$(((wait_seconds - 10) * 1000))
if [ "$min_advance_ms" -lt 10000 ]; then min_advance_ms=10000; fi
if [ "$b_final_ms" -le $((b_start_ms + min_advance_ms)) ]; then exit 122; fi
if [ "$b_final_ms" -ge 85000 ]; then exit 123; fi

"$adb" logcat -d > final.logcat.txt
if grep -q 'Chapter sleep timer reached chapter end; pausing playback first' final.logcat.txt; then exit 124; fi
completion_claim_count="$(grep -c 'Playback completion claimed by chapter sleep timer' final.logcat.txt || true)"
echo "COMPLETION_CLAIM_LOG_COUNT=$completion_claim_count" | tee -a final-position.txt
if grep -q 'Chapter sleep timer expiry failed' final.logcat.txt; then exit 126; fi
if grep -q 'FATAL EXCEPTION' final.logcat.txt; then exit 127; fi
if ! grep -q 'Chapter sleep timer disabled fail-closed: playback media changed' final.logcat.txt; then exit 128; fi

# ABS is a secondary oracle: A must not have been falsely completed by the stale
# timer and B must still be unfinished after continuing past A's old deadline.
curl -fsS "$ABS_URL/api/me/progress/$ABS_ITEM_ID" -H "Authorization: Bearer $token" -o abs-a-progress-s4.json
rc=$?
if [ "$rc" -ne 0 ]; then exit 129; fi
curl -fsS "$ABS_URL/api/me/progress/$b_id" -H "Authorization: Bearer $token" -o abs-b-progress-s4.json
rc=$?
if [ "$rc" -ne 0 ]; then exit 130; fi
jq -n --slurpfile a abs-a-progress-s4.json --slurpfile b abs-b-progress-s4.json '{a:$a[0],b:$b[0]}' > abs-progress-after.json

a_finished="$(jq -r '.isFinished // false' abs-a-progress-s4.json)"
a_current="$(jq -r '.currentTime // 0' abs-a-progress-s4.json)"
b_finished="$(jq -r '.isFinished // false' abs-b-progress-s4.json)"
b_current="$(jq -r '.currentTime // 0' abs-b-progress-s4.json)"
if [ "$a_finished" != 'false' ]; then exit 131; fi
if ! awk "BEGIN {exit !($a_current >= 300 && $a_current < 355)}"; then exit 132; fi
if [ "$b_finished" != 'false' ]; then exit 133; fi
if ! awk "BEGIN {exit !($b_current > 10 && $b_current < 85)}"; then exit 134; fi

"$adb" exec-out screencap -p > after-boundary.png

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
