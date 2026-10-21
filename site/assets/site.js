const menu = document.querySelector('[data-menu]');
menu?.addEventListener('click', () => {
  const expanded = menu.getAttribute('aria-expanded') !== 'true';
  menu.setAttribute('aria-expanded', String(expanded));
  document.querySelector('#navigation').classList.toggle('open', expanded);
});
const search = document.querySelector('#doc-search');
if (search) {
  const results = document.querySelector('#search-results');
  const status = document.querySelector('#search-status');
  let index;
  const normalize = value => value.normalize('NFKD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
  const run = async () => {
    const query = search.value.trim();
    if (!query) { results.replaceChildren(); status.textContent = ''; return; }
    try {
      index ??= await fetch(search.dataset.index).then(r => { if (!r.ok) throw Error(); return r.json(); });
      if (query !== search.value.trim()) return;
      const terms = normalize(query).split(/\s+/).filter(Boolean);
      const matches = index.map(doc => {
        const title = normalize(doc.title), text = normalize(doc.text);
        return {doc, score: terms.every(t => title.includes(t) || text.includes(t)) ? terms.reduce((s,t) => s + (title.includes(t) ? 10 : 1), 0) : 0};
      }).filter(x => x.score).sort((a,b) => b.score-a.score).slice(0,30);
      results.replaceChildren();
      for (const {doc} of matches) {
        const item = document.createElement('li'), link = document.createElement('a'), snippet = document.createElement('p');
        link.href = doc.url; link.textContent = doc.title;
        const at = Math.max(0, normalize(doc.text).indexOf(terms[0])-65);
        snippet.textContent = (at ? '…' : '') + doc.text.slice(at, at+230) + '…';
        item.append(link, snippet); results.append(item);
      }
      status.textContent = matches.length ? `${matches.length} matching document${matches.length === 1 ? '' : 's'}` : 'No documents found. Try a feature or platform name.';
    } catch { status.textContent = 'Search is unavailable. You can still browse all documents below.'; }
  };
  search.addEventListener('input', run);
  search.value = new URLSearchParams(location.search).get('q') || ''; run();
}
const feedback = document.querySelector('#feedback-form');
feedback?.addEventListener('submit', event => {
  event.preventDefault();
  if (!feedback.reportValidity()) return;
  const data = new FormData(feedback);
  const body = `## ${data.get('kind')}\n\n${data.get('message')}\n\n## Environment\n\nPlatform: ${data.get('platform')}\nNarad version: ${data.get('version') || 'Not specified'}\n\nSubmitted from the Narad community website.`;
  const url = new URL(`${feedback.dataset.repository}/issues/new`);
  url.searchParams.set('title', `[${data.get('kind')}] ${data.get('title')}`);
  url.searchParams.set('body', body);
  const status = document.querySelector('#feedback-status');
  if (url.href.length > 7800) {
    status.textContent = 'This draft is too long for a GitHub link. Please shorten the title or details and try again.';
    return;
  }
  status.textContent = '';
  location.assign(url.href);
});
