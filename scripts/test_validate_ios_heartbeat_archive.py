import plistlib
from pathlib import Path
import tempfile
import unittest

from validate_ios_heartbeat_archive import APP_ID, EXTENSION_ID, DISPLAY_NAME, validate_app, validate_source


class IdentityValidationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / 'Payload/Runner.app'
        self.extension = self.app / 'PlugIns/GenerationActivityExtension.appex'
        for path, identity, executable in ((self.app, APP_ID, 'Runner'), (self.extension, EXTENSION_ID, 'GenerationActivityExtension')):
            path.mkdir(parents=True, exist_ok=True)
            info = {'CFBundleIdentifier': identity, 'CFBundleDisplayName': DISPLAY_NAME, 'CFBundleExecutable': executable}
            if path == self.extension:
                info['NSExtension'] = {'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'}
            (path / 'Info.plist').write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
            (path / executable).write_bytes(b'fixture executable')

    def test_current_source(self):
        validate_source(Path(__file__).resolve().parents[1])

    def test_valid_embedded_app(self):
        validate_app(self.app)

    def test_missing_app(self):
        with self.assertRaisesRegex(ValueError, 'Runner.app missing'):
            validate_app(self.app / 'missing')

    def test_missing_extension(self):
        self.extension.rename(self.extension.with_name('missing.appex'))
        with self.assertRaisesRegex(ValueError, 'Extension.appex missing'):
            validate_app(self.app)

    def test_old_main_identifier_fails(self):
        self.assert_identity_fails(self.app, 'psyche.kelivo')

    def test_old_extension_identifier_fails(self):
        self.assert_identity_fails(self.extension, 'psyche.kelivo.GenerationActivityExtension')

    def test_mismatched_extension_prefix_fails(self):
        self.assert_identity_fails(self.extension, 'com.other.app.GenerationActivityExtension')

    def test_missing_executable_fails(self):
        (self.extension / 'GenerationActivityExtension').unlink()
        with self.assertRaisesRegex(ValueError, 'executable missing'):
            validate_app(self.app)

    def assert_identity_fails(self, path, identity):
        info = plistlib.loads((path / 'Info.plist').read_bytes())
        info['CFBundleIdentifier'] = identity
        (path / 'Info.plist').write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            validate_app(self.app)


if __name__ == '__main__':
    unittest.main()
