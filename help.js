(()=>{
  const search=document.getElementById('guideSearch'),articles=[...document.querySelectorAll('article[data-audience]')],links=[...document.querySelectorAll('nav a')],buttons=[...document.querySelectorAll('[data-role]')];
  let role='all';
  const norm=s=>s.toLocaleLowerCase('ru').replaceAll('ё','е').trim();
  const content=new Map(articles.map(a=>[a,norm(a.textContent)]));
  function filter(){
    const terms=norm(search.value).split(/\s+/).filter(Boolean);let count=0;
    for(const article of articles){const matchesRole=role==='all'||article.dataset.audience==='all'||article.dataset.audience===role;article.hidden=!(matchesRole&&terms.every(t=>content.get(article).includes(t)));if(!article.hidden)count++}
    links.forEach(a=>{a.hidden=document.getElementById(a.hash.slice(1)).hidden});
    document.getElementById('searchStatus').textContent=terms.length||role!=='all'?`Разделов найдено: ${count}`:'';
    document.getElementById('noResults').hidden=count>0;
    buttons.forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.role===role)));
  }
  search.addEventListener('input',filter);
  buttons.forEach(b=>b.addEventListener('click',()=>{role=b.dataset.role;filter()}));
  document.getElementById('clearSearch').addEventListener('click',()=>{search.value='';role='all';filter();search.focus()});
  document.getElementById('printGuide').addEventListener('click',()=>window.print());
  // Quick links also work when a previous role filter hid the requested section.
  document.querySelectorAll('a[href^="#"]').forEach(a=>a.addEventListener('click',()=>{const target=document.getElementById(a.hash.slice(1));if(target?.hidden){role='all';search.value='';filter()}}));
  filter();
})();
