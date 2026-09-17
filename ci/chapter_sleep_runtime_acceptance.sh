#!/usr/bin/env bash

adb="${RUNTIME_SDK_ROOT}/platform-tools/adb"
if [ ! -x "$adb" ]; then
  echo "ADB_NOT_FOUND=$adb" >&2
  exit 60
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
  "$adb" shell uiautomator dump /sdcard/u.xml >/dev/null 2>&1 || return 1
  "$adb" exec-out cat /sdcard/u.xml > "$1"
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

ready=0
i=0
while [ "$i" -lt 35 ]; do
  dump login.xml || true
  count="$(python3 ui.py count 0 login.xml 2>/dev/null || echo 0)"
  if [ "$count" -ge 3 ] && grep -q 'Sign In' login.xml; then ready=1; break; fi
  sleep 2
  i=$((i + 1))
done
if [ "$ready" -ne 1 ]; then exit 61; fi
echo "LOGIN_SEMANTICS_READY_EDITTEXTS=$count"

p="$(python3 ui.py edit 0 login.xml)"
rc=$?
if [ "$rc" -ne 0 ]; then exit 62; fi
"$adb" shell input tap $p
sleep 1
"$adb" shell input text h
sleep 1
"$adb" shell input text 'ttp://127.0.0.1:13378'
sleep 1
dump login-server.xml || exit 63
server="$(python3 ui.py value 0 login-server.xml)"
echo "LOGIN_SERVER=$server"
if [ "$server" != 'http://127.0.0.1:13378' ]; then exit 64; fi

dump login.xml || exit 65
p="$(python3 ui.py edit 1 login.xml)"
rc=$?
if [ "$rc" -ne 0 ]; then exit 66; fi
"$adb" shell input tap $p
sleep 1
"$adb" shell input text "$ABS_USER"
sleep 1
dump login-user.xml || exit 67
user="$(python3 ui.py value 1 login-user.xml)"
echo "LOGIN_USER=$user"
if [ "$user" != "$ABS_USER" ]; then exit 68; fi

dump login.xml || exit 69
p="$(python3 ui.py edit 2 login.xml)"
rc=$?
if [ "$rc" -ne 0 ]; then exit 70; fi
"$adb" shell input tap $p
sleep 1
"$adb" shell input text "$ABS_PASSWORD"
sleep 1
"$adb" shell input keyevent 4
sleep 1
dump submit.xml || exit 71
tap desc 'Sign In' submit.xml || exit 72
echo 'LOGIN_SIGN_IN_TAPPED=1'

auth=0
i=0
while [ "$i" -lt 30 ]; do
  sleep 2
  dump home.xml || true
  if grep -q 'Chapter Test A' home.xml && ! grep -q 'Sign in to your Audiobookshelf server' home.xml; then auth=1; break; fi
  i=$((i + 1))
done
if [ "$auth" -ne 1 ]; then exit 73; fi
"$adb" exec-out screencap -p > home.png

tap desc 'Chapter Test A' home.xml || exit 74
detail=0
i=0
while [ "$i" -lt 20 ]; do
  sleep 1
  dump detail.xml || true
  if grep -q 'Runtime Bot' detail.xml && grep -q 'content-desc="Play"' detail.xml; then detail=1; break; fi
  i=$((i + 1))
done
if [ "$detail" -ne 1 ]; then exit 75; fi
"$adb" exec-out screencap -p > detail.png
tap desc 'Play' detail.xml || exit 76

playing=0
i=0
while [ "$i" -lt 45 ]; do
  sleep 1
  "$adb" shell dumpsys media_session > media-playing.txt
  if grep -q 'package=de.vito0912.yaabsa.dev' media-playing.txt && grep -q 'state=PlaybackState {state=PLAYING(3)' media-playing.txt; then playing=1; break; fi
  i=$((i + 1))
done
if [ "$playing" -ne 1 ]; then exit 77; fi
pre_position_ms="$(media_position_ms media-playing.txt)"
echo "PLAYING_POSITION_MS=$pre_position_ms"
if [ -z "$pre_position_ms" ] || [ "$pre_position_ms" -ge 45000 ]; then exit 78; fi

tap desc 'Back' detail.xml || exit 79
sleep 2
dump player.xml || true
"$adb" exec-out screencap -p > player-before-more.png
if grep -q 'More player controls' player.xml && grep -q 'S1' player.xml; then
  echo 'PLAYER_CONTROLS_PATH=semantics'
  tap desc 'More player controls' player.xml || exit 80
else
  echo 'PLAYER_CONTROLS_PATH=validated-coordinate-fallback'
  tap_player_more_fallback || exit 81
fi

actions_ready=0
i=0
while [ "$i" -lt 4 ]; do
  sleep 1
  dump actions.xml || true
  if grep -q 'Sleep timer' actions.xml; then actions_ready=1; break; fi
  i=$((i + 1))
done
"$adb" exec-out screencap -p > actions.png
if [ "$actions_ready" -ne 1 ]; then exit 82; fi
tap desc 'Sleep timer' actions.xml || exit 83

sleep_ready=0
i=0
while [ "$i" -lt 2 ]; do
  sleep 1
  dump sleep.xml || true
  if grep -q 'End of chapter' sleep.xml; then sleep_ready=1; break; fi
  i=$((i + 1))
done
if [ "$sleep_ready" -ne 1 ]; then
  p="$(python3 ui.py above 'Sleep timer' actions.xml)"
  rc=$?
  if [ "$rc" -ne 0 ]; then exit 84; fi
  "$adb" shell input tap $p
  i=0
  while [ "$i" -lt 3 ]; do
    sleep 1
    dump sleep.xml || true
    if grep -q 'End of chapter' sleep.xml; then sleep_ready=1; break; fi
    i=$((i + 1))
  done
fi
"$adb" exec-out screencap -p > sleep.png
if [ "$sleep_ready" -ne 1 ]; then exit 85; fi
if grep -q 'End of chapter · 0s' sleep.xml; then exit 86; fi
tap contains 'End of chapter' sleep.xml || exit 87

armed=0
i=0
while [ "$i" -lt 8 ]; do
  sleep 1
  "$adb" logcat -d > armed.logcat.txt
  if grep -q 'Chapter sleep timer armed for S1 at 180s' armed.logcat.txt; then armed=1; break; fi
  i=$((i + 1))
done
if [ "$armed" -ne 1 ]; then exit 88; fi
"$adb" shell dumpsys media_session > media-armed.txt
if ! grep -q 'state=PlaybackState {state=PLAYING(3)' media-armed.txt; then exit 89; fi
position_ms="$(media_position_ms media-armed.txt)"
echo "ARMED_MEDIA_SESSION_POSITION_MS=$position_ms" | tee armed-position.txt
if [ -z "$position_ms" ] || [ "$position_ms" -ge 180000 ]; then exit 90; fi

# Selecting End of chapter leaves the player-actions sheet open. Close exactly that
# sheet before using the validated mini-player seek-bar coordinate.
"$adb" shell input keyevent 4
sleep 2
"$adb" exec-out screencap -p > retarget-before-seek.png

size="$("$adb" shell wm size | tr -d '\r' | grep -Eo '[0-9]+x[0-9]+' | tail -n 1)"
if [ -z "$size" ]; then exit 91; fi
w="${size%x*}"
h="${size#*x}"
if [ "$w" -lt 800 ] || [ "$h" -lt 1800 ]; then exit 92; fi
seek_x=$((w * 65 / 100))
seek_y=$((h * 942 / 1000))
echo "RETARGET_SEEK_TAP=${seek_x},${seek_y} size=${w}x${h}"
"$adb" shell input tap "$seek_x" "$seek_y"

retarget_position_ok=0
retarget_log_ok=0
i=0
while [ "$i" -lt 20 ]; do
  sleep 1
  "$adb" shell dumpsys media_session > media-retarget.txt
  "$adb" logcat -d > retarget.logcat.txt
  landed_ms="$(media_position_ms media-retarget.txt)"
  if [ -n "$landed_ms" ] && [ "$landed_ms" -gt 185000 ] && [ "$landed_ms" -lt 330000 ]; then
    retarget_position_ok=1
  fi
  if grep -q 'Chapter sleep timer retargeted to 360s after user navigation' retarget.logcat.txt; then
    retarget_log_ok=1
  fi
  if [ "$retarget_position_ok" -eq 1 ] && [ "$retarget_log_ok" -eq 1 ]; then break; fi
  i=$((i + 1))
done
landed_ms="$(media_position_ms media-retarget.txt)"
echo "RETARGET_MEDIA_SESSION_POSITION_MS=$landed_ms" | tee retarget-position.txt
if [ "$retarget_position_ok" -ne 1 ]; then exit 93; fi
if [ "$retarget_log_ok" -ne 1 ]; then exit 94; fi
if ! grep -q 'state=PlaybackState {state=PLAYING(3)' media-retarget.txt; then exit 95; fi
"$adb" exec-out screencap -p > retarget-after-seek.png

expired=0
i=0
while [ "$i" -lt 50 ]; do
  sleep 5
  "$adb" logcat -d > final.logcat.txt
  if grep -q 'Chapter sleep timer reached chapter end; pausing playback first' final.logcat.txt; then
    retarget_line="$(grep -n 'Chapter sleep timer retargeted to 360s after user navigation' final.logcat.txt | tail -n 1 | cut -d: -f1)"
    expiry_line="$(grep -n 'Chapter sleep timer reached chapter end; pausing playback first' final.logcat.txt | tail -n 1 | cut -d: -f1)"
    if [ -n "$retarget_line" ] && [ -n "$expiry_line" ] && [ "$expiry_line" -gt "$retarget_line" ]; then
      expired=1
      break
    fi
  fi
  i=$((i + 1))
done
if [ "$expired" -ne 1 ]; then exit 96; fi

"$adb" shell dumpsys media_session > media-after.txt
"$adb" exec-out screencap -p > after-boundary.png
"$adb" shell uiautomator dump /sdcard/final.xml >/dev/null 2>&1 || true
"$adb" exec-out cat /sdcard/final.xml > final.xml 2>/dev/null || true

if grep -q 'Chapter sleep timer expiry failed' final.logcat.txt; then exit 97; fi
if grep -q 'Chapter sleep timer expiry aborted' final.logcat.txt; then exit 98; fi
if grep -q 'Chapter sleep timer disabled fail-closed' final.logcat.txt; then exit 99; fi
if grep -q 'FATAL EXCEPTION' final.logcat.txt; then exit 100; fi
if grep -q 'state=PlaybackState {state=PLAYING(3)' media-after.txt; then exit 101; fi

final_position_ms="$(media_position_ms media-after.txt)"
echo "FINAL_POSITION_MS=$final_position_ms" | tee final-position.txt
if [ -z "$final_position_ms" ] || [ "$final_position_ms" -lt 345000 ] || [ "$final_position_ms" -gt 375000 ]; then exit 102; fi

token="$(cat "$RUNNER_TEMP/abs-token")"
if [ -z "$token" ]; then exit 103; fi
curl -fsS "$ABS_URL/api/me/progress/$ABS_ITEM_ID" -H "Authorization: Bearer $token" -o abs-progress-after.json
rc=$?
if [ "$rc" -ne 0 ]; then exit 104; fi

printf '%s\n' 'SCENARIO=2' 'EXPECTED_RETARGET=S1->S2' "LANDED_MS=$landed_ms" "FINAL_MS=$final_position_ms" > scenario-result.txt
echo 'CHAPTER_SLEEP_SCENARIO2_EVIDENCE_COMPLETE=1'
