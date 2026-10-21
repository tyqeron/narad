#!/usr/bin/env python3
"""Site contracts: all documents, internal routes/anchors, metadata and subpaths."""
from html.parser import HTMLParser
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('narad_site', ROOT/'site/build.py')
site = importlib.util.module_from_spec(spec); spec.loader.exec_module(site)


class Page(HTMLParser):
    def __init__(self, source):
        super().__init__(); self.links=[]; self.ids=set(); self.meta={}; self.h1=0; self.canonical=None; self.jsonld=[]; self.in_json=False
        self.feed(source)
    def handle_starttag(self, tag, attrs):
        a=dict(attrs)
        if 'id' in a: self.ids.add(a['id'])
        if tag=='h1': self.h1+=1
        if tag=='link' and a.get('rel')=='canonical': self.canonical=a['href']
        if tag=='meta': self.meta[a.get('name',a.get('property',''))]=a.get('content')
        if tag=='script' and a.get('type')=='application/ld+json': self.in_json=True
        for key in ['href','src']:
            if a.get(key): self.links.append(a[key])
    def handle_endtag(self,tag):
        if tag=='script':self.in_json=False
    def handle_data(self,data):
        if self.in_json:self.jsonld.extend(json.loads(data))


class SiteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='narad-site-test-')
        cls.output=Path(cls.temp.name)/'site'
        cls.builder=site.Builder(cls.output,'https://example.org/narad','v1.2.3')
        cls.builder.build()
        cls.pages={p.relative_to(cls.output).as_posix():Page(p.read_text()) for p in cls.output.rglob('*.html')}
    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()

    def test_every_document_has_html_and_original(self):
        paths={d['path'] for d in self.builder.docs}
        for required in ['PRD.md','ARCHITECURE.md','TECHNICAL_IMPLEMENTATION_SPEC.md','ROADMAP.md','SPRINT_BACKLOG.md','DEVELOPMENT.md','LICENSE','docs/WEBSITE.md']:
            self.assertIn(required,paths)
        for doc in self.builder.docs:
            self.assertTrue((self.output/doc['url']/'index.html').is_file())
            self.assertEqual((self.output/'sources'/doc['path']).read_text(),(ROOT/doc['path']).read_text())
        self.assertFalse(any('/build/' in x or '.dart_tool' in x for x in paths))

    def test_all_local_links_and_fragments_resolve(self):
        errors=[]
        for source,page in self.pages.items():
            for link in page.links:
                uri=urlsplit(link)
                if uri.scheme or uri.netloc:continue
                if uri.path:
                    self.assertTrue(uri.path.startswith('/narad/'),(source,link))
                    path=unquote(uri.path.removeprefix('/narad/'))
                    target=self.output/path
                    if target.is_dir():target/='index.html'
                else:target=self.output/source
                if not target.is_file():errors.append((source,link,'missing file'));continue
                if uri.fragment and target.suffix=='.html':
                    other=self.pages[target.relative_to(self.output).as_posix()]
                    if unquote(uri.fragment) not in other.ids:errors.append((source,link,'missing anchor'))
        self.assertEqual(errors,[])

    def test_seo_metadata_and_sitemap(self):
        for path,page in self.pages.items():
            self.assertEqual(page.h1,1,path)
            self.assertTrue(page.meta.get('description'),path)
            self.assertTrue(page.canonical.startswith('https://example.org/narad/'),path)
            self.assertEqual(page.meta['og:url'],page.canonical)
            self.assertTrue(page.jsonld,path)
            image_path=urlsplit(page.meta['og:image']).path.removeprefix('/narad/')
            self.assertTrue((self.output/image_path).is_file(),path)
        ns={'s':'http://www.sitemaps.org/schemas/sitemap/0.9'}
        urls=[x.text for x in ET.parse(self.output/'sitemap.xml').findall('.//s:loc',ns)]
        self.assertEqual(len(urls),len(self.builder.pages)-1)
        self.assertNotIn('https://example.org/narad/404/',urls)
        self.assertIn('Sitemap: https://example.org/narad/sitemap.xml',(self.output/'robots.txt').read_text())

    def test_search_contains_full_document_text(self):
        index=json.loads((self.output/'search-index.json').read_text())
        self.assertEqual(len(index),len(self.builder.docs))
        self.assertTrue(all(d['url'].startswith('/narad/docs/') and d['text'] for d in index))
        self.assertTrue(any('Product Requirements' in d['text'] for d in index))

    def test_feedback_and_unconfigured_patreon_are_honest(self):
        feedback=(self.output/'feedback/index.html').read_text()
        self.assertIn('github.com/tyqeron/narad/issues/new',feedback)
        self.assertIn('issue draft',feedback)
        donate=(self.output/'donate/index.html').read_text()
        if site.CONFIG.get('donation_url'):
            self.assertIn('href="'+site.esc(site.CONFIG['donation_url'])+'"',donate)
        else:
            self.assertIn('Patreon details coming soon',donate)
            self.assertNotIn('href="https://patreon.com/',donate)
        collaborators=(self.output/'collaborators/index.html').read_text()
        self.assertIn('/graphs/contributors',collaborators)
        self.assertNotRegex(collaborators,r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')

    def test_root_domain_and_custom_subpath(self):
        with tempfile.TemporaryDirectory() as folder:
            output=Path(folder)/'root'; builder=site.Builder(output,'https://narad.example','v1/feature'); builder.build()
            html=(output/'index.html').read_text()
            self.assertIn('href="/assets/site.css"',html)
            self.assertIn('/tree/v1%2Ffeature',html)
            self.assertNotIn('href="/narad/',html)

    def test_configured_donation_url_and_validation(self):
        previous=site.CONFIG['donation_url']
        try:
            with tempfile.TemporaryDirectory() as folder:
                output=Path(folder)/'donations';site.CONFIG['donation_url']='https://www.patreon.com/narad-test-fixture'
                builder=site.Builder(output,'https://example.org','test');builder.build()
                self.assertIn('href="https://www.patreon.com/narad-test-fixture"',(output/'donate/index.html').read_text())
                site.CONFIG['donation_url']='javascript:alert(1)'
                with self.assertRaises(ValueError):builder.community()
        finally:site.CONFIG['donation_url']=previous

    def test_output_safety_and_removed_page_cleanup(self):
        stale=self.output/'old-page.html';stale.write_text('old')
        self.builder.build();self.assertFalse(stale.exists())
        with tempfile.TemporaryDirectory() as folder:
            unsafe=Path(folder);(unsafe/'keep.txt').write_text('keep')
            with self.assertRaises(ValueError):site.Builder(unsafe,'https://example.org','test').build()
            self.assertEqual((unsafe/'keep.txt').read_text(),'keep')

if __name__=='__main__':unittest.main()
