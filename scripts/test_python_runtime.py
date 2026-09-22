import io
import tarfile
import unittest
from bundle_python import safe_members

class ArchiveTests(unittest.TestCase):
    def members(self,name,link=None):
        data=io.BytesIO()
        with tarfile.open(fileobj=data,mode='w') as file:
            entry=tarfile.TarInfo(name)
            if link is not None:entry.type=tarfile.SYMTYPE;entry.linkname=link
            file.addfile(entry)
        data.seek(0)
        with tarfile.open(fileobj=data) as file:return safe_members(file)
    def test_relative_runtime_link(self):
        self.assertEqual(len(self.members('python/bin/python3','python3.12')),1)
    def test_escaping_members_and_links(self):
        for name,link in [('../outside',None),('/outside',None),('python/bin/python3','../../../outside'),('python/bin/python3','/usr/bin/python3')]:
            with self.subTest(name=name,link=link),self.assertRaises(ValueError):self.members(name,link)
