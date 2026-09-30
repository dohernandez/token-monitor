"""Fail if test-only launch code can reach the release build."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHIPPED = ('main.swift', 'Updates.swift')
TEST_GUARD = '#if TOKEN_MONITOR_TESTS'
BANNED = ('CommandLine.arguments', 'self-test', '--diagnostics', '--show', 'launchDiagnostic',
          'runTestMode', 'testReminderCallbacks', 'TOKEN_MONITOR_TEST_MODE', '/tmp/', 'PASS:')


def release_source(text):
    """Drop #if TOKEN_MONITOR_TESTS ... #endif blocks, rejecting #else or nesting."""
    kept, guarded = [], False
    for number, line in enumerate(text.splitlines(), 1):
        directive = line.strip()
        if directive == TEST_GUARD:
            assert not guarded, 'nested test guard at line %d' % number
            guarded = True
        elif guarded and re.match(r'#(if|else|elseif)\b', directive):
            raise AssertionError('unsupported directive inside test guard at line %d' % number)
        elif guarded and directive == '#endif':
            guarded = False
        elif not guarded:
            kept.append(line)
    assert not guarded, 'unterminated test guard'
    return '\n'.join(kept)


class ShippedSourceTests(unittest.TestCase):
    def test_release_source_has_no_test_launch_modes(self):
        for name in SHIPPED:
            source = release_source((ROOT / name).read_text())
            for word in BANNED:
                with self.subTest(file=name, word=word):
                    self.assertNotIn(word, source)

    def test_test_modes_are_guarded_and_only_in_test_builds(self):
        modes = (ROOT / 'tests/TestModes.swift').read_text()
        unguarded = [line for line in release_source(modes).splitlines() if line.strip() and not line.startswith('//')]
        self.assertEqual(unguarded, [])
        build = (ROOT / 'taskfiles/build/scripts/build.sh').read_text()
        self.assertIn('1) build_dir="${build_dir:-$PWD/build/test}"; set -- -D TOKEN_MONITOR_TESTS tests/TestModes.swift', build)
        self.assertEqual(build.count('TOKEN_MONITOR_TESTS'), 1)

    def test_guard_stripping(self):
        text = 'a\n#if TOKEN_MONITOR_TESTS\nCommandLine.arguments\n#endif\nb'
        self.assertEqual(release_source(text), 'a\nb')
        for bad in ('#if TOKEN_MONITOR_TESTS\n#else\n#endif', '#if TOKEN_MONITOR_TESTS\nx'):
            with self.subTest(bad=bad), self.assertRaises(AssertionError):
                release_source(bad)


if __name__ == '__main__':
    unittest.main()
