from pathlib import Path
import runpy

base = Path(__file__).with_name('p1_integrate.py')
runpy.run_path(str(base), run_name='__main__')

test_path = Path('test/util/playback_start_attempt_test.dart')
text = test_path.read_text()
if not text.startswith('\\\n'):
    raise SystemExit('Unexpected generated P1 test preamble')
test_path.write_text(text[2:])
print('P1 generated test preamble repaired')
