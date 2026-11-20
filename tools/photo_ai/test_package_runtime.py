import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from package_runtime import package, MANIFEST


class PackageTests(unittest.TestCase):
    def test_split_reassemble_and_extract(self):
        with tempfile.TemporaryDirectory() as temp:
            source, output = Path(temp)/'input', Path(temp)/'output'
            for name in ['python/python.exe', 'worker.py', 'engine.py', 'check_runtime.py',
                         'weights/manifest.json', 'weights/pft_tv.pth', 'weights/pft_l1.pth']:
                path = source/name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(name.encode()*10)
            checksum = package(source, output, 'v0.5.6.2', part_size=200)
            raw = (output/MANIFEST).read_bytes()
            self.assertEqual(hashlib.sha256(raw).hexdigest(), checksum)
            manifest = json.loads(raw)
            data = b''
            for part in manifest['parts']:
                content = (output/part['name']).read_bytes()
                self.assertLessEqual(len(content), 200)
                self.assertEqual(len(content), part['size'])
                self.assertEqual(hashlib.sha256(content).hexdigest(), part['sha256'])
                data += content
            self.assertGreater(len(manifest['parts']), 1)
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                self.assertEqual(len(z.infolist()), manifest['fileCount'])
                self.assertEqual(sum(x.file_size for x in z.infolist()), manifest['expandedBytes'])
                self.assertIsNone(z.testzip())
                for name in z.namelist():
                    self.assertEqual(z.read(name), (source/name).read_bytes())

    def test_incomplete_runtime_fails_before_publishing(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(ValueError, 'Missing runtime file'):
                package(Path(temp), Path(temp)/'out', 'v0.5.6.2')


if __name__ == '__main__':
    unittest.main()
