#!/usr/bin/env python3
"""Exercise dependency parsing independently of the inspected binary's absolute path."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('bundle', Path(__file__).with_name('sparkle-bundle.py'))
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class LinkageContract(unittest.TestCase):
    def test_absolute_inspection_path_is_not_a_dependency(self):
        header = str(bundle.ROOT / 'dist/app/Autoupdate')
        bundle.verify_linkage(f'{header} (architecture arm64):\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n'
                              f'{header} (architecture x86_64):\n\t@rpath/Sparkle.framework/Versions/B/Sparkle (compatibility version 1.0.0)\n')

    def test_build_and_private_dependencies_are_rejected(self):
        for dependency in (str(bundle.ROOT / '.build/libBad.dylib'),
                           '@rpath/.build/libBad.dylib', '/private/tmp/libBad.dylib',
                           '/opt/homebrew/lib/libBad.dylib'):
            with self.subTest(dependency=dependency), self.assertRaises(AssertionError):
                bundle.verify_linkage(f'fixture:\n\t{dependency} (compatibility version 1.0.0)\n')

    def test_empty_or_unparseable_output_is_rejected(self):
        for output in ('', 'fixture:\n', 'not otool output'):
            with self.subTest(output=output), self.assertRaises(AssertionError):
                bundle.verify_linkage(output)


if __name__ == '__main__':
    unittest.main()
