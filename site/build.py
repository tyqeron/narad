#!/usr/bin/env python3
"""Build Narad's tag-versioned, dependency-light GitHub Pages website."""
import argparse
from html import escape, unescape
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import posixpath
import re
import shutil
import subprocess
from urllib.parse import quote, urlsplit, urlunsplit
import xml.etree.ElementTree as ET

import markdown

ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / 'site'
CONFIG = json.loads((SITE / 'config.json').read_text())
TITLES = {'README.md': 'Narad overview', 'PRD.md': 'Product requirements',
          'ARCHITECURE.md': 'Architecture', 'TECHNICAL_IMPLEMENTATION_SPEC.md': 'Technical implementation spec',
          'ROADMAP.md': 'Roadmap', 'SPRINT_BACKLOG.md': 'Sprint backlog',
          'DEVELOPMENT.md': 'Development journal', 'LICENSE': 'License'}
PLATFORMS = {'ANDROID', 'LINUX', 'WINDOWS', 'IOS'}
FEATURES = {'CAMERA', 'SCREEN_SHARING', 'TRANSFERS', 'PHONE_INTEGRATION', 'MEETING', 'FIND_DEVICE'}


def esc(value):
    return escape(str(value), quote=True)


class PlainText(HTMLParser):
    def __init__(self):
        super().__init__(); self.parts = []
    def handle_data(self, data):
        self.parts.append(data)


def plain(html):
    parser = PlainText(); parser.feed(html)
    return re.sub(r'\s+', ' ', ' '.join(parser.parts)).strip()


def documents():
    # Deliberately include only public documentation, never daemon/SDK/private state.
    paths = set(ROOT.glob('*.md')) | set((ROOT / 'docs').rglob('*.md'))
    paths |= set((ROOT / 'clients').glob('**/README.md'))
    paths = {p for p in paths if not any(x in p.parts for x in ('build', '.dart_tool', 'ephemeral', '.symlinks', '.gradle'))}
    paths.add(ROOT / 'LICENSE')
    result = []
    for path in sorted(paths):
        rel = path.relative_to(ROOT).as_posix()
        text = path.read_text()
        heading = re.search(r'^#\s+(.+)$', text, re.M)
        title = TITLES.get(rel, heading.group(1) if heading else path.stem.replace('_', ' ').title())
        if rel.startswith('clients/'):
            title = 'Flutter client guide' if rel == 'clients/flutter/README.md' else f'{title} · {path.parent.name}'
        category = ('Platforms' if path.stem in PLATFORMS else 'Features' if path.stem in FEATURES else
                    'Product & engineering' if path.parent == ROOT and rel != 'README.md' and rel != 'LICENSE' else
                    'Start here' if rel in ('README.md', 'docs/IMPLEMENTATION_STATUS.md') else 'Project reference')
        slug = rel.removesuffix('.md').removeprefix('docs/').lower()
        url = 'docs/' + ('overview' if rel == 'README.md' else 'architecture' if rel == 'ARCHITECURE.md' else slug) + '/'
        result.append({'path': rel, 'title': plain(title), 'category': category, 'url': url, 'source': text})
    return result


class Builder:
    def __init__(self, output, url, version):
        parsed = urlsplit(url)
        if parsed.scheme != 'https' or not parsed.netloc or parsed.query or parsed.fragment or parsed.username:
            raise ValueError('Site URL must be an absolute HTTPS URL without credentials, query or fragment')
        self.output = output
        self.url = url.rstrip('/')
        self.base = parsed.path.rstrip('/')
        self.version = version
        self.repo = CONFIG['repository'].rstrip('/')
        self.docs = documents()
        self.docmap = {d['path']: d['url'] for d in self.docs}
        self.pages = []

    def link(self, path=''):
        return self.base + '/' + path.lstrip('/')

    def source(self, path, raw=False):
        return self.link('sources/' + quote(path, safe='/')) if raw else self.repo + '/blob/' + quote(self.version, safe='') + '/' + quote(path, safe='/')

    def frame(self, title, description, path, body, active='', extra_schema=None):
        canonical = self.url + '/' + path
        nav = ''.join(f'<a href="{esc(self.link(p))}" {"aria-current=page" if active == label else ""}>{label}</a>' for label,p in [('Overview',''),('Docs','docs/'),('Collaborators','collaborators/'),('Feedback','feedback/'),('Donate','donate/')])
        schema = {'@context':'https://schema.org','@type':'WebPage','name':title,'description':description,'url':canonical,'isPartOf':{'@type':'WebSite','name':'Narad','url':self.url+'/'}}
        schemas = [schema] + ([extra_schema] if extra_schema else [])
        data = json.dumps(schemas, ensure_ascii=False).replace('<', '\\u003c')
        return f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)} | Narad</title><meta name="description" content="{esc(description)}">
<link rel="canonical" href="{esc(canonical)}"><meta name="robots" content="{"noindex, follow" if path == "404/" else "index, follow"}">
<meta name="theme-color" content="#172b2a"><meta property="og:type" content="website"><meta property="og:site_name" content="Narad">
<meta property="og:title" content="{esc(title)}"><meta property="og:description" content="{esc(description)}"><meta property="og:url" content="{esc(canonical)}">
<meta property="og:image" content="{esc(self.url+'/assets/social.png')}"><meta property="og:image:width" content="1200"><meta property="og:image:height" content="630"><meta property="og:image:alt" content="Narad — your devices, in sync">
<meta name="twitter:card" content="summary_large_image"><meta name="twitter:title" content="{esc(title)}"><meta name="twitter:description" content="{esc(description)}"><meta name="twitter:image" content="{esc(self.url+'/assets/social.png')}">
<link rel="icon" type="image/png" href="{self.link('assets/narad.png')}"><link rel="stylesheet" href="{self.link('assets/site.css')}">
<script type="application/ld+json">{data}</script><script defer src="{self.link('assets/site.js')}"></script></head>
<body><a class="skip" href="#main">Skip to content</a><header class="header"><div class="nav-shell"><a class="brand" href="{self.link()}"><img src="{self.link('assets/narad.png')}" width="34" height="34" alt=""><span>narad<span class="brand-dot">.</span></span></a>
<button class="menu" data-menu aria-expanded="false" aria-controls="navigation" aria-label="Toggle navigation">Menu ☰</button><nav id="navigation" aria-label="Main navigation">{nav}<a class="github" href="{self.repo}">GitHub <span aria-hidden="true">↗</span></a></nav></div></header>
{body}<footer><div class="footer-grid"><div><a class="brand" href="{self.link()}">narad<span class="brand-dot">.</span></a><p>Built for your devices.<br>Made possible by a community.</p></div><div><span class="eyebrow">EXPLORE</span><a href="{self.link('docs/')}">Documentation</a><a href="{self.link('docs/prd/')}">Product requirements</a><a href="{self.repo}/releases">Releases</a></div><div><span class="eyebrow">GET INVOLVED</span><a href="{self.link('collaborators/')}">Collaborators</a><a href="{self.link('feedback/')}">Share feedback</a><a href="{self.link('donate/')}">Support Narad</a><a href="{self.repo}">Source code</a></div></div><div class="footer-bottom"><span>Open source. Local first. Community built.</span><span>Docs version <a href="{self.repo}/tree/{quote(self.version,safe='')}">{esc(self.version)}</a> · <a href="{self.link('docs/license/')}">License</a></span></div></footer></body></html>'''

    def page(self, path, title, description, body, active='', schema=None):
        target = self.output / path / 'index.html'
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(self.frame(title, description, path, body, active, schema))
        self.pages.append(path)

    def card(self, doc):
        return f'<a class="doc-card" href="{self.link(doc["url"])}"><span class="eyebrow">{esc(doc["category"])}</span><h3>{esc(doc["title"])} <span aria-hidden="true">↗</span></h3><p>{esc(doc["description"])}</p></a>'

    def render_docs(self):
        index = []
        builder = self
        class Rewrite(HTMLParser):
            def __init__(self, source):
                super().__init__(convert_charrefs=False); self.source = source; self.parts = []
            def handle_starttag(self, tag, attrs):
                rewritten = []
                for key,value in attrs:
                    if key in ('href','src') and value:
                        parsed = urlsplit(unescape(value))
                        if parsed.scheme.lower() in ('javascript','data','vbscript'):
                            value = '#'
                        elif not parsed.scheme and not parsed.netloc and parsed.path:
                            resolved = posixpath.normpath(posixpath.join(posixpath.dirname(self.source),parsed.path))
                            if resolved in builder.docmap:
                                value = builder.link(builder.docmap[resolved])
                            elif tag == 'img' and (ROOT/resolved).is_file() and resolved.startswith('clients/flutter/assets/branding/'):
                                value = builder.link('assets/'+Path(resolved).name)
                            else:
                                value = builder.source(resolved)
                            value += ('?'+parsed.query if parsed.query else '') + ('#'+parsed.fragment if parsed.fragment else '')
                    rewritten.append(key if value is None else f'{key}="{esc(value)}"')
                self.parts.append('<'+tag+(' '+' '.join(rewritten) if rewritten else '')+'>')
            def handle_endtag(self, tag): self.parts.append('</'+tag+'>')
            def handle_data(self, data): self.parts.append(data)
            def handle_entityref(self, name): self.parts.append('&'+name+';')
            def handle_charref(self, name): self.parts.append('&#'+name+';')
        for doc in self.docs:
            md = markdown.Markdown(extensions=['fenced_code','tables','toc','sane_lists'], extension_configs={'toc':{'permalink':True}})
            rendered = md.convert(doc['source']) if doc['path'] != 'LICENSE' else '<h1>License</h1><pre>'+esc(doc['source'])+'</pre>'
            # The page title is provided by the layout; keep one H1 per page.
            rendered = re.sub(r'<h1(\b[^>]*)>(.*?)</h1>',r'<h2\1>\2</h2>',rendered,flags=re.S)
            doc['description'] = plain(rendered)[:170].rsplit(' ',1)[0] + '…'
            rewrite = Rewrite(doc['path']); rewrite.feed(rendered)
            content = ''.join(rewrite.parts)
            toc = md.toc.replace('class="toc"', 'class="toc-links"')
            sidebar = '<a class="back" href="'+self.link('docs/')+'">← All documentation</a>'
            for category in ['Start here','Platforms','Features','Product & engineering','Project reference']:
                sidebar += f'<h2>{esc(category)}</h2>'
                sidebar += ''.join(f'<a {"aria-current=page" if d is doc else ""} href="{self.link(d["url"])}">{esc(d["title"])}</a>' for d in self.docs if d['category']==category)
            body = f'''<main id="main" class="docs-layout"><aside class="docs-nav" aria-label="Documentation">{sidebar}</aside><article class="document"><div class="doc-meta"><span class="eyebrow">{esc(doc['category'])}</span><span>{esc(self.version)}</span></div><h1>{esc(doc['title'])}</h1><div class="source-links"><a href="{self.source(doc['path'])}">View source ↗</a><a href="{self.source(doc['path'],True)}" download>Download document ↓</a></div><div class="prose">{content}</div></article><aside class="toc" aria-label="On this page"><span class="eyebrow">ON THIS PAGE</span>{toc}</aside></main>'''
            schema = {'@context':'https://schema.org','@type':'TechArticle','headline':doc['title'],'description':doc['description'],'url':self.url+'/'+doc['url'],'version':self.version}
            self.page(doc['url'], doc['title'], doc['description'], body, 'Docs', schema)
            index.append({'title':doc['title'],'url':self.link(doc['url']),'text':plain(rendered)})
            raw = self.output/'sources'/doc['path']; raw.parent.mkdir(parents=True,exist_ok=True); raw.write_text(doc['source'])
        (self.output/'search-index.json').write_text(json.dumps(index,ensure_ascii=False))

    def build(self):
        self.pages = []
        marker = self.output / '.narad-site-output'
        if self.output.exists() and any(self.output.iterdir()):
            if not marker.is_file():
                raise ValueError('Refusing to replace a nonempty output directory without a Narad build marker')
            shutil.rmtree(self.output)
        self.output.mkdir(parents=True,exist_ok=True)
        marker.touch()
        shutil.copytree(SITE/'assets',self.output/'assets',dirs_exist_ok=True)
        shutil.copy2(ROOT/'clients/flutter/assets/branding/narad.png',self.output/'assets/narad.png')
        self.render_docs()
        sections = ''
        for category in ['Start here','Platforms','Features','Product & engineering','Project reference']:
            sections += f'<section class="doc-group"><h2>{category}</h2><div class="doc-grid">'+''.join(self.card(d) for d in self.docs if d['category']==category)+'</div></section>'
        self.page('docs/','Documentation','Explore every Narad guide, platform setup, feature reference, PRD, architecture document and development plan.',f'''<main id="main" class="container"><div class="page-heading"><span class="eyebrow">THE KNOWLEDGE BASE</span><h1>Everything behind Narad.</h1><p>From your first pairing to the protocol underneath it. The complete project documentation, published directly from the source.</p><div class="version-pill">Documentation for {esc(self.version)} · {len(self.docs)} documents</div></div><section class="search-panel" aria-label="Search documentation"><label for="doc-search">Find your answer</label><input id="doc-search" type="search" placeholder="Try Android, camera, permissions…" data-index="{self.link('search-index.json')}" autocomplete="off"><p id="search-status" role="status" aria-live="polite"></p><ul id="search-results"></ul><noscript><p>Search requires JavaScript. Every document is available below.</p></noscript></section>{sections}</main>''','Docs')
        self.home()
        self.community()
        self.collaborators()
        self.page('404/','Page not found','Find Narad documentation, downloads and community resources.',f'<main id="main" class="container page-heading"><span class="eyebrow">404</span><h1>A little disconnected.</h1><p>This page could not be found. Let’s get you back to your devices.</p><a class="button" href="{self.link()}">Back to Narad</a><a class="button secondary" href="{self.link("docs/")}">Browse documentation</a></main>')
        shutil.copy2(self.output/'404/index.html',self.output/'404.html')
        # GitHub Pages serves 404.html at arbitrary paths: all assets use base-aware URLs.
        ET.register_namespace('', 'http://www.sitemaps.org/schemas/sitemap/0.9')
        tree = ET.Element('{http://www.sitemaps.org/schemas/sitemap/0.9}urlset')
        for path in self.pages:
            if path == '404/': continue
            item = ET.SubElement(tree,'{http://www.sitemaps.org/schemas/sitemap/0.9}url')
            ET.SubElement(item,'{http://www.sitemaps.org/schemas/sitemap/0.9}loc').text = self.url+'/'+path
        ET.ElementTree(tree).write(self.output/'sitemap.xml',encoding='utf-8',xml_declaration=True)
        (self.output/'robots.txt').write_text('User-agent: *\nAllow: /\nSitemap: '+self.url+'/sitemap.xml\n')
        (self.output/'.nojekyll').touch()
        print(f'Built {len(self.pages)} pages and {len(self.docs)} documents in {self.output}')

    def home(self):
        features = [('↗','Files without the detour','Send files directly. Browse shared folders, create directories, and move large files without a Narad file-size cap.','docs/transfers/'),('⌘','Copy here. Paste there.','Keep your clipboard in sync across trusted devices with opt-in sharing and per-device permissions.','docs/overview/#use-the-app'),('◉','A different point of view','View a remote camera, switch lenses, and save photos or video. Explore screen mirroring and supported extended displays.','docs/camera/'),('♫','Make your devices a team','Share speakers and microphones. Set up a phone as part of your desktop meeting workflow.','docs/meeting/'),('◎','Stay in the conversation','Bring Android and desktop notifications to your other devices, with permissioned dismissal and supported Android replies.','docs/phone_integration/'),('⚙','Your devices. Your rules.','Choose what each paired device can do. Use approved commands, device controls, and find-my-device tools.','docs/find_device/')]
        cards = ''.join(f'<a class="feature-card" href="{self.link(url)}"><span class="feature-icon" aria-hidden="true">{icon}</span><h3>{title}</h3><p>{body}</p><span class="text-link">Explore feature ↗</span></a>' for icon,title,body,url in features)
        diagram = '''<div class="device-scene" aria-label="A laptop, phone and tablet paired over a local network" role="img"><div class="scene-grid"></div><div class="orbit orbit-one"></div><div class="orbit orbit-two"></div><div class="connection c-one"></div><div class="connection c-two"></div><div class="laptop"><div class="device-top"><span class="tiny-logo">n.</span><span>My devices</span><i></i></div><div class="mock-title">Good things, connected.</div><div class="mock-device"><span class="device-symbol">▯</span><div>Everyday phone<small>Connected · Android</small></div><b>●</b></div><div class="mock-device"><span class="device-symbol">▭</span><div>Studio tablet<small>Connected · Android</small></div><b>●</b></div><div class="mock-file"><span>↗</span><div>weekend-photos.zip<small>Transferred directly. Just like that.</small></div><span>✓</span></div></div><div class="laptop-base"></div><div class="phone"><div class="phone-notch"></div><div class="tiny-logo">n.</div><small>Clipboard in sync</small><div class="phone-lines"><i></i><i></i><i></i></div><div class="phone-check">✓</div></div><div class="tablet"><span class="tiny-logo">n.</span><div class="tablet-art"><i></i><b></b></div><small>Your other screen.</small></div><div class="scene-badge"><span>●</span> Direct. Private. Yours.</div><span class="scene-note">ONE TRUSTED NETWORK. MORE POSSIBILITIES.</span></div>'''
        body = f'''<main id="main"><section class="hero container"><div class="hero-copy"><span class="eyebrow"><span class="live-dot"></span> LOCAL FIRST. OPEN SOURCE.</span><h1>Your devices.<br>Finally, <em>in sync.</em></h1><p class="hero-description">Your phone, tablet and computer have a lot to share. Narad brings them together on your own network — without the cloud in between.</p><div class="hero-actions"><a class="button" href="{self.repo}/releases">Get Narad <span aria-hidden="true">↗</span></a><a class="button secondary" href="{self.link('docs/')}">Read the docs <span aria-hidden="true">→</span></a></div><p class="hero-footnote">Linux & Android builds · Windows support in development</p></div>{diagram}</section><div class="principles"><div class="container"><span><b>01</b> No account required</span><span><b>02</b> Direct device connections</span><span><b>03</b> Permission by permission</span><span><b>04</b> Built in the open</span></div></div>
<section class="container section"><div class="section-heading"><div><span class="eyebrow">LESS FRICTION. MORE FLOW.</span><h2>One connection.<br>A whole lot of possibility.</h2></div><p>Keep the devices you love.<br>Help them work better together.</p></div><div class="feature-grid">{cards}</div><div class="capability-strip"><span class="eyebrow">ALSO IN THE TOOLKIT</span><div><a href="{self.link('docs/screen_sharing/')}">Screen mirroring & supported extended displays ↗</a><a href="{self.link('docs/phone_integration/')}">Android contacts, SMS & call controls ↗</a><a href="{self.link('docs/android/')}">Android home-screen widgets ↗</a><a href="{self.link('docs/linux/')}">Desktop tray & background startup ↗</a></div></div></section>
<section class="getting-started"><div class="container steps-layout"><div><span class="eyebrow">A SIMPLE START</span><h2>Nearby.<br>Paired.<br><em>Ready.</em></h2><a class="text-link" href="{self.link('docs/overview/#use-the-app')}">Your first connection →</a></div><ol class="steps"><li><span>01</span><div><h3>Find each other.</h3><p>Install Narad on your devices and connect them to the same trusted local network.</p></div></li><li><span>02</span><div><h3>Make it official.</h3><p>Send a pairing request, compare the verification code, and accept on the other device.</p></div></li><li><span>03</span><div><h3>Choose what to share.</h3><p>Grant each device the permissions you want. Start with a file, a clipboard, or a new point of view.</p></div></li></ol></div></section>
<section class="container section"><div class="section-heading"><div><span class="eyebrow">MEET YOUR DEVICES WHERE THEY ARE</span><h2>A growing family.</h2></div><a class="text-link" href="{self.link('docs/implementation_status/')}">See the full implementation status ↗</a></div><div class="platform-grid"><a href="{self.link('docs/android/')}"><span class="platform-mark">A</span><h3>Android</h3><span class="status">Available builds</span><p>Phones, tablets, sharing and companion features.</p></a><a href="{self.link('docs/linux/')}"><span class="platform-mark">L</span><h3>Linux</h3><span class="status">Available builds</span><p>Your desktop, with tray integration and an installer.</p></a><a href="{self.link('docs/windows/')}"><span class="platform-mark">W</span><h3>Windows</h3><span class="status pending">In development</span><p>Runner, ZIP and MSIX packaging. Native device QA pending.</p></a><a href="{self.link('docs/ios/')}"><span class="platform-mark">i</span><h3>iOS</h3><span class="status pending">Source preview</span><p>Foreground companion work. Platform restrictions apply.</p></a></div><p class="section-note">Capabilities vary by platform. Read the platform guides before planning your setup.</p></section>
<section class="docs-spotlight container"><div><span class="eyebrow">NOT A BLACK BOX</span><h2>The ideas. The plans.<br>The details. All here.</h2><p>Explore the PRD, architecture, protocol, roadmap and every project guide. Understand what works today and where we’re headed.</p><a class="button" href="{self.link('docs/')}">Explore {len(self.docs)} documents →</a></div><div class="spotlight-links"><a href="{self.link('docs/prd/')}"><span>01 / VISION</span>Product requirements ↗</a><a href="{self.link('docs/architecture/')}"><span>02 / DESIGN</span>Architecture ↗</a><a href="{self.link('docs/roadmap/')}"><span>03 / DIRECTION</span>Project roadmap ↗</a></div></section><section class="container section community-strip"><div><span class="eyebrow">BETTER, TOGETHER</span><h2>A community project.<br>A shared effort.</h2><p>Your ideas, bug reports, code and support help Narad move forward.</p></div><div><a class="button" href="{self.link('feedback/')}">Share your feedback →</a><a class="button secondary" href="{self.link('donate/')}">Support the community ♡</a><a class="text-link" href="{self.link('collaborators/')}">Meet the collaborators →</a></div></section></main>'''
        self.page('', 'Your devices, in sync', CONFIG['description'], body, 'Overview', {'@context':'https://schema.org','@type':'SoftwareApplication','name':'Narad','applicationCategory':'UtilitiesApplication','operatingSystem':'Android, Linux, Windows','description':CONFIG['description'],'url':self.url+'/', 'downloadUrl':self.repo+'/releases','license':self.url+'/docs/license/','isAccessibleForFree':True,'offers':{'@type':'Offer','price':'0','priceCurrency':'USD'}})

    def collaborators(self):
        # Names only from public commit metadata. Never publish author emails.
        try:
            log = subprocess.check_output(['git','shortlog','-sn','HEAD'],cwd=ROOT,text=True)
            authors = [(name, int(count)) for count,name in (line.strip().split('\t',1) for line in log.splitlines())]
        except (OSError,subprocess.CalledProcessError,ValueError):
            authors = []
        people = ''.join(f'<div class="collaborator"><strong>{esc(name)}</strong><span>{count} commit{"s" if count != 1 else ""} in this version’s history</span></div>' for name,count in authors)
        roles = [('Build','Work on the Rust core, Flutter interface, native platform integrations, and release tooling.'),('Test','Try Narad on real devices. Help uncover platform-specific bugs and unexpected behavior.'),('Explain','Improve setup guides, examples, troubleshooting, and the project’s technical documentation.'),('Design','Help make cross-device workflows simpler, more accessible, and easier to understand.')]
        cards = ''.join(f'<div><h3>{esc(title)}</h3><p>{esc(text)}</p></div>' for title,text in roles)
        self.page('collaborators/','Collaborators & contributors','Meet the contributors behind Narad and help build, test, document and design local-first device sharing.',f'''<main id="main" class="container"><div class="page-heading"><span class="eyebrow">THE PEOPLE BEHIND THE CONNECTION</span><h1>Built by people.<br>Better with you.</h1><p>Narad grows through the time, care and curiosity of its collaborators. There is room here for more than just code.</p></div><section class="panel"><span class="eyebrow">CONTRIBUTORS TO THIS VERSION</span><h2>Thank you for building Narad.</h2><div class="collaborator-list">{people}</div><p class="form-note">Names and commit counts come from the repository history included in this version. This credits code contributions; many other kinds of community work matter too.</p><a class="text-link" href="{self.repo}/graphs/contributors">Explore contributors on GitHub ↗</a></section><section class="section collaborators" style="padding-top:60px"><div class="section-heading"><div><span class="eyebrow">FIND YOUR WAY IN</span><h2>Bring what you know.</h2></div><a class="button" href="{self.repo}/issues">Find an issue to work on ↗</a></div><div class="collaborator-roles">{cards}</div><p><a class="text-link" href="{self.link('feedback/')}">Have an idea for collaborating? Start a conversation →</a></p></section></main>''','Collaborators')

    def community(self):
        feedback = f'''<main id="main" class="container"><div class="page-heading"><span class="eyebrow">BUILT WITH YOU</span><h1>Your experience<br>shapes what’s next.</h1><p>A rough edge? A clever idea? Tell the community. Every useful detail helps make Narad better for everyone.</p></div><div class="community-layout"><form id="feedback-form" class="panel" data-repository="{self.repo}" action="{self.repo}/issues/new" method="get"><h2>Share your feedback</h2><div class="form-row"><label>Type<select name="kind"><option>Feedback</option><option>Bug report</option><option>Feature idea</option><option>Documentation</option></select></label><label>Platform<select name="platform"><option>Android</option><option>Linux</option><option>Windows</option><option>iOS</option><option>Multiple platforms</option><option>Website / documentation</option></select></label></div><label>Give it a title<input name="title" required maxlength="120" placeholder="What would you like us to know?"></label><label>Narad version <span class="muted">(optional)</span><input name="version" maxlength="60" placeholder="e.g. the tag from your download"></label><label>The details<textarea name="message" required maxlength="1200" rows="7" placeholder="What happened, what did you expect, or what would you love to see?"></textarea></label><p class="form-note">This opens a GitHub issue draft. Sign in to GitHub, review the draft, then submit it there. Issues are public: don’t include private messages, tokens or personal information.</p><button class="button" type="submit">Continue to GitHub →</button><p id="feedback-status" class="form-note" role="alert"></p><noscript><p>JavaScript is off. <a href="{self.repo}/issues/new?template=community-feedback.md">Use the GitHub feedback template</a>.</p></noscript></form><aside class="community-aside"><span class="eyebrow">A FEW GOOD PLACES TO START</span><h2>Make your feedback count.</h2><p>For bugs, include both device platforms, the app version, steps to reproduce, and the result you expected.</p><a class="aside-link" href="{self.repo}/issues">Check existing feedback ↗</a><a class="aside-link" href="{self.link('docs/')}">Look through the docs →</a><hr><p>No GitHub account? You can still browse the documentation and existing public issues. Submission currently requires GitHub.</p></aside></div></main>'''
        self.page('feedback/','Community feedback','Share a Narad bug report, feature idea or experience with the open-source community through GitHub Issues.',feedback,'Feedback')
        donation = CONFIG.get('donation_url','').strip()
        if donation and (urlsplit(donation).scheme != 'https' or not urlsplit(donation).netloc or urlsplit(donation).username):
            raise ValueError('Donation URL must be an absolute HTTPS URL without credentials')
        donate_cta = f'<a class="button" href="{esc(donation)}" rel="noopener noreferrer">{esc(CONFIG["donation_label"])} ↗</a><p class="form-note">You’ll continue to our external donation provider. Review its recipient, terms and payment details before donating.</p>' if donation else '<div class="donation-pending"><span class="status pending">Patreon details coming soon</span><p>Our Patreon link will be added here once it is ready. In the meantime, you can help by testing, contributing, and sharing feedback.</p></div>'
        self.page('donate/','Support the Narad community','Support the open-source work behind Narad with donations, testing, documentation, code and community feedback.',f'''<main id="main" class="container"><div class="page-heading"><span class="eyebrow">A LITTLE SUPPORT. A LONG WAY.</span><h1>Keep good things<br><em>connected.</em></h1><p>Narad is built in the open by people who care about making their devices work better together. Help the community keep that work moving.</p></div><div class="community-layout"><section class="panel donation-panel"><span class="heart" aria-hidden="true">♡</span><h2>Support the people behind Narad.</h2><p>Every contribution is a way to say: this kind of independent, local-first software is worth building.</p>{donate_cta}<p class="form-note">Donations are voluntary. They don’t purchase app features or guarantee a delivery date.</p></section><aside class="community-aside"><span class="eyebrow">MANY WAYS TO GIVE BACK</span><h2>Support isn’t only financial.</h2><a class="aside-link" href="{self.link('feedback/')}">Test a feature. Share what you find. ↗</a><a class="aside-link" href="{self.repo}">Contribute code or documentation. ↗</a><a class="aside-link" href="{self.repo}">Star the project. Help others find it. ↗</a><p>A thoughtful bug report, a clearer guide, or a few minutes of testing on a new device can make a real difference.</p></aside></div></main>''','Donate')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=SITE/'_build')
    parser.add_argument('--url',default=os.environ.get('SITE_URL',CONFIG['site_url']))
    parser.add_argument('--version',default=os.environ.get('SITE_VERSION','main'))
    args = parser.parse_args()
    Builder(args.output.resolve(),args.url,args.version).build()
