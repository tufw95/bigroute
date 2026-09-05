"""Exercise publication against a temporary Git remote; no network or secrets."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/publish_channel.sh'


class ChannelPublicationTests(unittest.TestCase):
    def test_atomic_monotonic_and_resumable_publication(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            remote = root / 'remote.git'
            subprocess.run(['git', 'init', '--bare', '-q', str(remote)], check=True)
            commands = root / 'bin'
            commands.mkdir()
            wrappers = {
                'gh': '''#!/usr/bin/env python3
import os, pathlib, shutil, sys
if sys.argv[1:3] == ['auth', 'setup-git'] or sys.argv[1:3] == ['release', 'view']:
    sys.exit(0)
if sys.argv[1:3] == ['release', 'upload']:
    shutil.copyfile(sys.argv[4], os.environ['TEST_LEGACY_FEED'])
    sys.exit(0)
sys.exit('Unexpected gh operation')
''',
                'curl': '''#!/usr/bin/env python3
import os, pathlib, subprocess, sys
url = next(value for value in sys.argv if value.startswith('https://'))
if 'raw.githubusercontent.com' in url:
    data = subprocess.check_output(['git', '--git-dir', os.environ['TEST_REMOTE'], 'show', 'refs/heads/ota-feeds:office/appcast.xml'])
else:
    data = pathlib.Path(os.environ['TEST_LEGACY_FEED']).read_bytes()
pathlib.Path(sys.argv[sys.argv.index('--output') + 1]).write_bytes(data)
'''
            }
            for name, code in wrappers.items():
                path = commands / name
                path.write_text(code)
                path.chmod(0o755)
            feed = root / 'appcast.xml'
            env = {
                **os.environ, 'PATH': f'{commands}:{os.environ["PATH"]}',
                'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_NOSYSTEM': '1',
                'GIT_CONFIG_COUNT': '1',
                'GIT_CONFIG_KEY_0': f'url.{remote.as_uri()}.insteadOf',
                'GIT_CONFIG_VALUE_0': 'https://github.com/fixture/bigroute.git',
                'REPOSITORY': 'fixture/bigroute', 'CHANNEL': 'office', 'VERSION': '1.6.0',
                'APPCAST_PATH': str(feed), 'TEST_REMOTE': str(remote),
                'TEST_LEGACY_FEED': str(root / 'legacy.xml'),
            }

            def content(build, title='Test'):
                return f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><title>{title}</title><sparkle:version>{build}</sparkle:version></item></channel></rss>'

            def publish(value, success=True):
                feed.write_text(value)
                result = subprocess.run(['bash', str(SCRIPT)], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)

            def head():
                return subprocess.check_output(['git', '--git-dir', str(remote), 'rev-parse', 'refs/heads/ota-feeds'])

            original = content(1006000)
            publish(original)
            first = head()
            self.assertEqual(Path(env['TEST_LEGACY_FEED']).read_text(), original)
            publish(original)  # A failed channel step can resume without replacing signed bytes.
            self.assertEqual(head(), first)
            publish(content(1005003), success=False)
            publish(content(1006000, 'Different signed bytes'), success=False)
            self.assertEqual(head(), first)
            self.assertEqual(Path(env['TEST_LEGACY_FEED']).read_text(), original)
            publish(content(1006001))
            self.assertNotEqual(head(), first)
            self.assertEqual(Path(env['TEST_LEGACY_FEED']).read_text(), content(1006001))


if __name__ == '__main__':
    unittest.main()
