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
elif mode=='contains':
    n=pick([n for n in nodes if key in n.attrib.get('content-desc','')])
elif mode=='above':
    n=pick([n for n in nodes if n.attrib.get('content-desc')==key])
else:
    raise SystemExit(3)
a=[int(x) for x in re.findall(r'-?\d+',n.attrib.get('bounds',''))]
if len(a)!=4: raise SystemExit(4)
x=(a[0]+a[2])//2
y=(a[1]+a[3])//2
if mode=='above': y-=42
print(x,y)
PY

dump() {
  out="$1"
  tmp="${out}.tmp"
  attempt=0
  rm -f "$out" "$tmp"
  while [ "$attempt" -lt 5 ]; do
    if "$adb" shell uiautomator dump /sdcard/u.xml >/dev/null 2>&1 \
      && "$adb" exec-out cat /sdcard/u.xml > "$tmp" 2>/dev/null \
      && python3 -c 'import sys,xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$tmp" >/dev/null 2>&1; then
      mv "$tmp" "$out"
      return 0
    fi
    rm -f "$tmp"
    sleep 1
    attempt=$((attempt + 1))
  done
  return 1
}

tap() {
  p="$(python3 ui.py "$1" "$2" "$3")"
  rc=$?
  if [ "$rc" -ne 0 ]; then return "$rc"; fi
  "$adb" shell input tap $p
}

tap_player_more_fallback() {
  size="$("$adb" shell wm size | tr -d '\r' | grep -Eo '[0-9]+x[0-9]+' | tail -n 1)"
  if [ -z "$size" ]; then return 1; fi
  w="${size%x*}"
  h="${size#*x}"
  x=$((w * 927 / 1000))
  y=$((h * 897 / 1000))
  echo "PLAYER_MORE_FALLBACK=${x},${y} size=${w}x${h}"
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

queue_intent_snapshot() {
  label="$1"
  out="$2"
  attempt=0
  db_rel="$("$adb" shell run-as "$package" find . -type f -name app_db.sqlite -print -quit 2>/dev/null | tr -d '\r' | head -n 1)"
  if [ -z "$db_rel" ]; then
    echo "QUEUE_DB_NOT_FOUND label=$label" >&2
    return 1
  fi

  while [ "$attempt" -lt 3 ]; do
    snap_dir="$RUNNER_TEMP/queue-db-${label}-${attempt}"
    rm -rf "$snap_dir"
    mkdir -p "$snap_dir"

    if ! "$adb" exec-out run-as "$package" cat "$db_rel" > "$snap_dir/app_db.sqlite" 2>/dev/null; then
      attempt=$((attempt + 1))
      sleep 1
      continue
    fi

    for suffix in -wal -shm; do
      if "$adb" shell run-as "$package" ls "${db_rel}${suffix}" >/dev/null 2>&1; then
        if ! "$adb" exec-out run-as "$package" cat "${db_rel}${suffix}" > "$snap_dir/app_db.sqlite${suffix}" 2>/dev/null; then
          rm -f "$snap_dir/app_db.sqlite${suffix}"
        fi
      fi
    done

    python3 - "$snap_dir/app_db.sqlite" "$out" "$b_id" "$ABS_ITEM_ID" "$label" <<'PY'
import json
import sqlite3
import sys

db_path, out_path, b_id, a_id, label = sys.argv[1:]
try:
    con = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True)
    con.execute('PRAGMA query_only=ON')
    rows = con.execute(
        'SELECT value FROM user_settings WHERE key = ?',
        ('queue_intent_v2',),
    ).fetchall()
    con.close()
except Exception as exc:
    print(f'QUEUE_DB_READ_FAILED label={label} error={type(exc).__name__}', file=sys.stderr)
    raise SystemExit(20)

if len(rows) != 1:
    print(f'QUEUE_INTENT_ROW_COUNT={len(rows)} label={label}', file=sys.stderr)
    raise SystemExit(21)

try:
    data = json.loads(rows[0][0])
except Exception as exc:
    print(f'QUEUE_INTENT_JSON_FAILED label={label} error={type(exc).__name__}', file=sys.stderr)
    raise SystemExit(22)

entries = data.get('manualEntries')
anchor = data.get('anchor')
if not isinstance(entries, list):
    print(f'QUEUE_MANUAL_ENTRIES_INVALID label={label}', file=sys.stderr)
    raise SystemExit(23)

b_matches = 0
for entry in entries:
    if not isinstance(entry, dict):
        continue
    ref = entry.get('ref')
    if isinstance(ref, dict) and ref.get('itemId') == b_id:
        b_matches += 1

anchor_item = anchor.get('itemId') if isinstance(anchor, dict) else None
anchor_matches_a = int(anchor_item == a_id)
with open(out_path, 'w', encoding='utf-8') as handle:
    handle.write(f'QUEUE_INTENT_LABEL={label}\n')
    handle.write('QUEUE_INTENT_KEY=queue_intent_v2\n')
    handle.write(f'MANUAL_ENTRY_COUNT={len(entries)}\n')
    handle.write(f'B_MATCH_COUNT={b_matches}\n')
    handle.write(f'ANCHOR_MATCH_A={anchor_matches_a}\n')

if b_matches != 1:
    raise SystemExit(24)
if anchor_matches_a != 1:
    raise SystemExit(25)
PY
    rc=$?
    if [ "$rc" -eq 0 ]; then
      cat "$out"
      return 0
    fi

    attempt=$((attempt + 1))
    sleep 1
  done

  return 1
}

wait_for_home() {
  out="$1"
  tries="$2"
  i=0
  while [ "$i" -lt "$tries" ]; do
    dump "$out" || true
    if grep -q 'Recently Added' "$out" \
      && grep -q 'Chapter Test A' "$out" \
      && grep -q 'Chapter Test B' "$out"; then
      return 0
    fi
    "$adb" shell input keyevent 4 >/dev/null 2>&1 || true
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# Add a second, distinct audiobook to the already-mounted isolated ABS fixture.
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

# Login.
ready=0
i=0
while [ "$i" -lt 35 ]; do
  dump login.xml || true
  count="$(python3 ui.py count 0 login.xml 2>/dev/null || echo 0)"
  if [ "$count" -ge 3 ] && grep -q 'Sign In' login.xml; then ready=1; break; fi
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
dump login-server.xml || exit 70
server="$(python3 ui.py value 0 login-server.xml)"
if [ "$server" != 'http://127.0.0.1:13378' ]; then exit 71; fi

dump login.xml || exit 72
p="$(python3 ui.py edit 1 login.xml)" || exit 73
"$adb" shell input tap $p
sleep 1
"$adb" shell input text "$ABS_USER"
sleep 1

dump login.xml || exit 74
p="$(python3 ui.py edit 2 login.xml)" || exit 75
"$adb" shell input tap $p
sleep 1
"$adb" shell input text "$ABS_PASSWORD"
sleep 1
"$adb" shell input keyevent 4
sleep 1
dump submit.xml || exit 76
tap desc 'Sign In' submit.xml || exit 77

auth=0
i=0
while [ "$i" -lt 35 ]; do
  sleep 2
  dump home.xml || true
  if grep -q 'Recently Added' home.xml \
    && grep -q 'Chapter Test A' home.xml \
    && grep -q 'Chapter Test B' home.xml \
    && ! grep -q 'Sign in to your Audiobookshelf server' home.xml; then
    auth=1
    break
  fi
  i=$((i + 1))
done
if [ "$auth" -ne 1 ]; then exit 78; fi
"$adb" exec-out screencap -p > home.png

# Start A first. Starting a book replaces any pre-existing manual queue, so B
# must be queued only after A is already the current playing item.
tap desc 'Chapter Test A' home.xml || exit 79
ready_a=0
i=0
while [ "$i" -lt 20 ]; do
  sleep 1
  dump detail.xml || true
  if grep -q 'Runtime Bot' detail.xml && grep -q 'content-desc="Play"' detail.xml; then
    ready_a=1
    break
  fi
  i=$((i + 1))
done
if [ "$ready_a" -ne 1 ]; then exit 80; fi
"$adb" exec-out screencap -p > detail.png
tap desc 'Play' detail.xml || exit 81

playing=0
i=0
while [ "$i" -lt 45 ]; do
  sleep 1
  "$adb" shell dumpsys media_session > media-playing.txt
  if grep -q 'package=de.vito0912.yaabsa.dev' media-playing.txt \
    && grep -q 'state=PlaybackState {state=PLAYING(3)' media-playing.txt \
    && grep -q 'description=Chapter Test A' media-playing.txt; then
    playing=1
    break
  fi
  i=$((i + 1))
done
if [ "$playing" -ne 1 ]; then exit 82; fi

# Return to the shelf without restarting A.
"$adb" shell input keyevent 4 >/dev/null 2>&1 || true
sleep 1
if ! wait_for_home home-playing.xml 4; then exit 83; fi
"$adb" shell dumpsys media_session > media-playing-home.txt
if ! grep -q 'state=PlaybackState {state=PLAYING(3)' media-playing-home.txt \
  || ! grep -q 'description=Chapter Test A' media-playing-home.txt; then
  exit 84
fi

# Queue B through the real UI while A continues playing.
tap desc 'Chapter Test B' home-playing.xml || exit 85
b_detail=0
i=0
while [ "$i" -lt 20 ]; do
  sleep 1
  dump b-detail.xml || true
  if grep -q 'Runtime Bot B' b-detail.xml && grep -q 'content-desc="Add to queue"' b-detail.xml; then
    b_detail=1
    break
  fi
  i=$((i + 1))
done
if [ "$b_detail" -ne 1 ]; then exit 86; fi
tap desc 'Add to queue' b-detail.xml || exit 87

queued=0
i=0
while [ "$i" -lt 10 ]; do
  sleep 1
  dump b-detail.xml || true
  if grep -q 'Runtime Bot B' b-detail.xml && grep -q 'content-desc="Remove from queue"' b-detail.xml; then
    queued=1
    break
  fi
  i=$((i + 1))
done
if [ "$queued" -ne 1 ]; then exit 88; fi
"$adb" exec-out screencap -p > retarget-before-seek.png

# The UI state is necessary but not the queue oracle. Verify the persisted
# isolated-app queue intent read-only and require A as anchor + exactly one B.
sleep 1
if ! queue_intent_snapshot before queue-intent-before.txt; then exit 89; fi
cp queue-intent-before.txt retarget.logcat.txt

# Return to shelf; A must still be playing and B must have been added without
# another call to Play on A.
"$adb" shell input keyevent 4 >/dev/null 2>&1 || true
sleep 1
if ! wait_for_home player.xml 4; then exit 90; fi
"$adb" shell dumpsys media_session > media-before-seek.txt
if ! grep -q 'state=PlaybackState {state=PLAYING(3)' media-before-seek.txt \
  || ! grep -q 'description=Chapter Test A' media-before-seek.txt; then
  exit 91
fi

# Seek A into its final chapter S2 using the real mini-player seek bar. The
# coordinate is only input; MediaSession position is the oracle.
size="$("$adb" shell wm size | tr -d '\r' | grep -Eo '[0-9]+x[0-9]+' | tail -n 1)"
if [ -z "$size" ]; then exit 92; fi
w="${size%x*}"
h="${size#*x}"
if [ "$w" -lt 800 ] || [ "$h" -lt 1800 ]; then exit 93; fi
seek_x=$((w * 88 / 100))
seek_y=$((h * 942 / 1000))
echo "SCENARIO3_FINAL_CHAPTER_SEEK=${seek_x},${seek_y} size=${w}x${h}"
"$adb" shell input tap "$seek_x" "$seek_y"

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
if [ "$seek_ok" -ne 1 ]; then exit 94; fi
"$adb" exec-out screencap -p > retarget-after-seek.png

# Arm end-of-current-chapter while actually playing S2.
dump player.xml || true
if grep -q 'More player controls' player.xml; then
  tap desc 'More player controls' player.xml || exit 95
else
  tap_player_more_fallback || exit 96
fi

actions_ready=0
i=0
while [ "$i" -lt 5 ]; do
  sleep 1
  dump actions.xml || true
  if grep -q 'Sleep timer' actions.xml; then actions_ready=1; break; fi
  i=$((i + 1))
done
if [ "$actions_ready" -ne 1 ]; then exit 97; fi
tap desc 'Sleep timer' actions.xml || exit 98

sleep_ready=0
i=0
while [ "$i" -lt 4 ]; do
  sleep 1
  dump sleep.xml || true
  if grep -q 'End of chapter' sleep.xml; then sleep_ready=1; break; fi
  i=$((i + 1))
done
if [ "$sleep_ready" -ne 1 ]; then
  p="$(python3 ui.py above 'Sleep timer' actions.xml)" || exit 99
  "$adb" shell input tap $p
  i=0
  while [ "$i" -lt 4 ]; do
    sleep 1
    dump sleep.xml || true
    if grep -q 'End of chapter' sleep.xml; then sleep_ready=1; break; fi
    i=$((i + 1))
  done
fi
if [ "$sleep_ready" -ne 1 ]; then exit 100; fi
tap contains 'End of chapter' sleep.xml || exit 101

armed=0
i=0
while [ "$i" -lt 10 ]; do
  sleep 1
  "$adb" logcat -d > armed.logcat.txt
  if grep -q 'Chapter sleep timer armed for S2 at 360s' armed.logcat.txt; then
    armed=1
    break
  fi
  i=$((i + 1))
done
if [ "$armed" -ne 1 ]; then exit 102; fi
"$adb" shell dumpsys media_session > media-armed.txt
if ! grep -q 'state=PlaybackState {state=PLAYING(3)' media-armed.txt \
  || ! grep -q 'description=Chapter Test A' media-armed.txt; then
  exit 103
fi
position_ms="$(media_position_ms media-armed.txt)"
echo "ARMED_MEDIA_SESSION_POSITION_MS=$position_ms" | tee armed-position.txt
if [ -z "$position_ms" ] || [ "$position_ms" -le 180000 ] || [ "$position_ms" -ge 360000 ]; then exit 104; fi

# Close action sheet and wait for final-chapter expiry.
"$adb" shell input keyevent 4
sleep 1
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
if [ "$expired" -ne 1 ]; then exit 105; fi

"$adb" shell dumpsys media_session > media-after.txt
"$adb" exec-out screencap -p > after-boundary.png
if ! grep -q 'Playback completion claimed by chapter sleep timer; suppressing queue/loop auto-advance.' final.logcat.txt; then exit 106; fi
if grep -q 'Chapter sleep timer expiry failed' final.logcat.txt; then exit 107; fi
if grep -q 'Chapter sleep timer expiry aborted' final.logcat.txt; then exit 108; fi
if grep -q 'Chapter sleep timer disabled fail-closed' final.logcat.txt; then exit 109; fi
if grep -q 'FATAL EXCEPTION' final.logcat.txt; then exit 110; fi
if grep -q 'state=PlaybackState {state=PLAYING(3)' media-after.txt; then exit 111; fi
if ! grep -q 'state=PlaybackState {state=PAUSED(2)' media-after.txt; then exit 112; fi
if ! grep -q 'description=Chapter Test A' media-after.txt; then exit 113; fi

final_position_ms="$(media_position_ms media-after.txt)"
echo "FINAL_POSITION_MS=$final_position_ms" | tee final-position.txt
if [ -z "$final_position_ms" ] || [ "$final_position_ms" -lt 355000 ] || [ "$final_position_ms" -gt 365000 ]; then exit 114; fi

# Queue intent must still contain B after A's claimed chapter-end completion.
sleep 1
if ! queue_intent_snapshot after queue-intent-after.txt; then exit 115; fi
before_b_matches="$(awk -F= '$1=="B_MATCH_COUNT" {print $2}' queue-intent-before.txt)"
after_b_matches="$(awk -F= '$1=="B_MATCH_COUNT" {print $2}' queue-intent-after.txt)"
before_anchor="$(awk -F= '$1=="ANCHOR_MATCH_A" {print $2}' queue-intent-before.txt)"
after_anchor="$(awk -F= '$1=="ANCHOR_MATCH_A" {print $2}' queue-intent-after.txt)"

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
EOF2

# Secondary UI check: B must still expose Remove from queue, never Currently
# playing. DB evidence above remains the primary queue oracle.
if ! wait_for_home final.xml 4; then exit 116; fi
tap desc 'Chapter Test B' final.xml || exit 117
post_b=0
i=0
while [ "$i" -lt 20 ]; do
  sleep 1
  dump final.xml || true
  if grep -q 'Runtime Bot B' final.xml && grep -q 'content-desc="Remove from queue"' final.xml; then
    post_b=1
    break
  fi
  if grep -q 'content-desc="Currently playing"' final.xml; then
    echo 'SCENARIO3_B_BECAME_CURRENT=1' >&2
    exit 118
  fi
  i=$((i + 1))
done
"$adb" exec-out screencap -p > after-boundary.png
if [ "$post_b" -ne 1 ]; then exit 119; fi

curl -fsS "$ABS_URL/api/me/progress/$ABS_ITEM_ID" -H "Authorization: Bearer $token" -o abs-progress-after.json
rc=$?
if [ "$rc" -ne 0 ]; then exit 120; fi

echo 'CHAPTER_SLEEP_SCENARIO3_EVIDENCE_COMPLETE=1'
