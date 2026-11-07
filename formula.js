// Мини-движок формул для раздела «Общий отчет» (листы из Excel).
// Понимает: числа, текст в кавычках, ссылки A1 / $A$1 / 'Лист'!A1, диапазоны A1:B5,
// + - * / ^ & = <> < > <= >=, скобки, функции SUM, SUMIF, AVERAGE, MIN, MAX, COUNT, IF, ROUND, ABS.
// Книга: {sheets:[{title,data:{rows:{"1":{"A":{v,f,s}}}}}]}. recalcBook() пишет результат формул в cell.v.
(function(root){
  const ERR=s=>({err:s});
  const isErr=x=>x&&typeof x==='object'&&'err'in x;
  function colNum(s){let n=0;for(const ch of s)n=n*26+(ch.charCodeAt(0)-64);return n}
  function colName(n){let s='';while(n>0){const m=(n-1)%26;s=String.fromCharCode(65+m)+s;n=(n-m-1)/26}return s}
  const normSheet=s=>String(s||'').trim().toLowerCase();

  function tokenize(src){
    const t=[];let i=0;
    while(i<src.length){
      const ch=src[i];
      if(/\s/.test(ch)){i++;continue}
      if(ch==='"'){let j=i+1,s='';while(j<src.length){if(src[j]==='"'){if(src[j+1]==='"'){s+='"';j+=2;continue}break}s+=src[j++]}t.push({k:'str',v:s});i=j+1;continue}
      if(ch==="'"){let j=i+1,s='';while(j<src.length&&!(src[j]==="'"&&src[j+1]!=="'")){if(src[j]==="'"){s+="'";j+=2;continue}s+=src[j++]}i=j+1;if(src[i]==='!'){i++;t.push({k:'sheet',v:s});continue}throw new Error('bad sheet')}
      const num=/^(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?/.exec(src.slice(i));
      if(num&&!/^[A-Za-z]/.test(src.slice(i+num[0].length))){t.push({k:'num',v:parseFloat(num[0])});i+=num[0].length;continue}
      const word=/^[\$A-Za-zА-Яа-яЁё_][\$\wА-Яа-яЁё\.]*/.exec(src.slice(i));
      if(word){
        const w=word[0];i+=w.length;
        if(src[i]==='!'){i++;t.push({k:'sheet',v:w});continue}
        if(src[i]==='('){t.push({k:'fn',v:w.toUpperCase()});continue}
        const ref=/^\$?([A-Za-z]{1,3})\$?(\d+)$/.exec(w);
        if(ref){t.push({k:'ref',c:colNum(ref[1].toUpperCase()),r:+ref[2]});continue}
        if(/^(TRUE|FALSE)$/i.test(w)){t.push({k:'num',v:/^TRUE$/i.test(w)?1:0});continue}
        throw new Error('bad name '+w)
      }
      const two=src.slice(i,i+2);
      if(two==='<>'||two==='<='||two==='>='){t.push({k:'op',v:two});i+=2;continue}
      if('+-*/^&=<>(),:;%'.includes(ch)){t.push({k:'op',v:ch===';'?',':ch});i++;continue}
      throw new Error('bad char '+ch)
    }
    return t
  }

  function parse(src){
    const t=tokenize(src);let p=0;
    const peek=()=>t[p],isOp=v=>t[p]&&t[p].k==='op'&&t[p].v===v,eat=v=>{if(!isOp(v))throw new Error('expected '+v);p++};
    function cmp(){let a=cat();while(t[p]&&t[p].k==='op'&&['=','<>','<','>','<=','>='].includes(t[p].v)){const o=t[p++].v;a={op:o,a,b:cat()}}return a}
    function cat(){let a=add();while(isOp('&')){p++;a={op:'&',a,b:add()}}return a}
    function add(){let a=mul();while(isOp('+')||isOp('-')){const o=t[p++].v;a={op:o,a,b:mul()}}return a}
    function mul(){let a=pow();while(isOp('*')||isOp('/')){const o=t[p++].v;a={op:o,a,b:pow()}}return a}
    function pow(){let a=un();while(isOp('^')){p++;a={op:'^',a,b:un()}}return a}
    function un(){if(isOp('-')){p++;return{op:'neg',a:un()}}if(isOp('+')){p++;return un()}let a=prim();if(isOp('%')){p++;a={op:'/',a,b:{num:100}}}return a}
    function refOrRange(sheet){
      const a=t[p++];if(!a||a.k!=='ref')throw new Error('ref expected');
      if(isOp(':')){p++;const b=t[p++];if(!b||b.k!=='ref')throw new Error('range end');return{range:{sheet,c1:Math.min(a.c,b.c),r1:Math.min(a.r,b.r),c2:Math.max(a.c,b.c),r2:Math.max(a.r,b.r)}}}
      return{ref:{sheet,c:a.c,r:a.r}}
    }
    function prim(){
      const x=peek();if(!x)throw new Error('unexpected end');
      if(x.k==='num'){p++;return{num:x.v}}
      if(x.k==='str'){p++;return{str:x.v}}
      if(x.k==='sheet'){p++;return refOrRange(x.v)}
      if(x.k==='ref')return refOrRange(null);
      if(x.k==='fn'){p++;eat('(');const args=[];if(!isOp(')')){args.push(cmp());while(isOp(',')){p++;args.push(cmp())}}eat(')');return{fn:x.v,args}}
      if(isOp('(')){p++;const e=cmp();eat(')');return e}
      throw new Error('unexpected '+(x.v??x.k))
    }
    const e=cmp();if(p<t.length)throw new Error('extra input');return e
  }

  function makeBook(book){
    const byName=new Map();book.sheets.forEach(s=>byName.set(normSheet(s.title),s));
    const cache=new Map(),busy=new Set(),parsed=new Map();
    function getCell(sheet,c,r){const row=sheet.data.rows[String(r)];return row?row[colName(c)]:undefined}
    function cellValue(sheet,c,r){
      const cell=getCell(sheet,c,r);if(!cell)return null;
      if(cell.f==null)return cell.v??null;
      const key=sheet.title+'!'+c+':'+r;
      if(cache.has(key))return cache.get(key);
      if(busy.has(key))return ERR('#ЦИКЛ!');
      busy.add(key);
      let v;
      try{let ast=parsed.get(cell.f);if(!ast){ast=parse(cell.f);parsed.set(cell.f,ast)}v=ev(ast,sheet);if(v&&v.range)v=v.vals[0]??null}catch(e){v=ERR('#ОШИБКА!')}
      busy.delete(key);
      if(typeof v==='number'&&!isFinite(v))v=ERR('#ДЕЛ/0!');
      cache.set(key,v);return v
    }
    function sheetOf(name,cur){if(name==null)return cur;const s=byName.get(normSheet(name));if(!s)throw new Error('no sheet');return s}
    function rangeVals(rg,cur){const s=sheetOf(rg.sheet,cur),out=[];for(let r=rg.r1;r<=rg.r2;r++){const row=s.data.rows[String(r)];if(!row)continue;for(let c=rg.c1;c<=rg.c2;c++){if(row[colName(c)])out.push(cellValue(s,c,r))}}return out}
    function rangeGrid(rg,cur){const s=sheetOf(rg.sheet,cur),out=[];for(let r=rg.r1;r<=rg.r2;r++)for(let c=rg.c1;c<=rg.c2;c++)out.push(cellValue(s,c,r));return out}
    const num=v=>{if(isErr(v))return v;if(v==null||v==='')return 0;if(typeof v==='number')return v;const n=Number(String(v).replace(',','.').replace(/\s/g,''));return isNaN(n)?ERR('#ЗНАЧ!'):n};
    const txt=v=>v==null?'':typeof v==='number'?String(v):String(v);
    function flat(args,cur){const out=[];for(const a of args){if(a.range)out.push(...rangeVals(a.range,cur).map(v=>({v,fromRange:true})));else out.push({v:ev(a,cur)})}return out}
    function numsOf(args,cur){const out=[];for(const x of flat(args,cur)){if(isErr(x.v))return x.v;if(x.fromRange){if(typeof x.v==='number')out.push(x.v)}else{const n=num(x.v);if(isErr(n))return n;out.push(n)}}return out}
    function crit(c){
      const m=/^(<=|>=|<>|<|>|=)?(.*)$/s.exec(txt(c));const op=m[1]||'=',rhs=m[2];const rn=rhs!==''&&!isNaN(Number(rhs))?Number(rhs):null;
      return v=>{
        if(rn!=null&&(typeof v==='number'||(v!=null&&v!==''&&!isNaN(Number(v))))){const x=Number(v);return op==='='?x===rn:op==='<>'?x!==rn:op==='<'?x<rn:op==='>'?x>rn:op==='<='?x<=rn:x>=rn}
        const a=txt(v).toLowerCase(),b=rhs.toLowerCase();
        if(op==='=')return a===b;if(op==='<>')return a!==b;return false
      }
    }
    function ev(n,cur){
      if('num'in n)return n.num;if('str'in n)return n.str;
      if(n.ref){const s=sheetOf(n.ref.sheet,cur);return cellValue(s,n.ref.c,n.ref.r)}
      if(n.range){return{range:true,vals:rangeVals(n.range,cur)}}
      if(n.fn){
        const A=n.args;
        switch(n.fn){
          case 'SUM':{const xs=numsOf(A,cur);return isErr(xs)?xs:xs.reduce((s,x)=>s+x,0)}
          case 'AVERAGE':{const xs=numsOf(A,cur);return isErr(xs)?xs:xs.length?xs.reduce((s,x)=>s+x,0)/xs.length:ERR('#ДЕЛ/0!')}
          case 'MIN':{const xs=numsOf(A,cur);return isErr(xs)?xs:xs.length?Math.min(...xs):0}
          case 'MAX':{const xs=numsOf(A,cur);return isErr(xs)?xs:xs.length?Math.max(...xs):0}
          case 'COUNT':{return flat(A,cur).filter(x=>typeof x.v==='number').length}
          case 'ABS':{const x=num(ev(A[0],cur));return isErr(x)?x:Math.abs(x)}
          case 'ROUND':{const x=num(ev(A[0],cur)),d=A[1]?num(ev(A[1],cur)):0;if(isErr(x))return x;if(isErr(d))return d;const k=Math.pow(10,d);return Math.round(x*k)/k}
          case 'IF':{const c=ev(A[0],cur);if(isErr(c))return c;const ok=typeof c==='string'?c!=='':!!num(c);const r=ok?(A[1]?ev(A[1],cur):1):(A[2]?ev(A[2],cur):0);return r&&r.range?r.vals[0]??null:r}
          case 'SUMIF':{
            if(!A[0]||!A[0].range)return ERR('#ЗНАЧ!');
            const rg=A[0].range,sr=A[2]&&A[2].range?A[2].range:rg;
            const test=crit(ev(A[1],cur));if(isErr(test))return test;
            const cv=rangeGrid(rg,cur);
            const sz={sheet:sr.sheet,c1:sr.c1,r1:sr.r1,c2:sr.c1+(rg.c2-rg.c1),r2:sr.r1+(rg.r2-rg.r1)};
            const sv=rangeGrid(sz,cur);let s=0;
            for(let i=0;i<cv.length;i++){if(test(cv[i])&&typeof sv[i]==='number')s+=sv[i]}
            return s
          }
          default:return ERR('#ИМЯ?')
        }
      }
      if(n.op==='neg'){const x=num(ev(n.a,cur));return isErr(x)?x:-x}
      let a=ev(n.a,cur),b=ev(n.b,cur);
      if(a&&a.range)a=a.vals[0]??null;if(b&&b.range)b=b.vals[0]??null;
      if(isErr(a))return a;if(isErr(b))return b;
      if(n.op==='&')return txt(a)+txt(b);
      if(['=','<>','<','>','<=','>='].includes(n.op)){
        let x=a,y=b;if(typeof x!=='number'||typeof y!=='number'){x=txt(a).toLowerCase();y=txt(b).toLowerCase()}
        return +(n.op==='='?x===y:n.op==='<>'?x!==y:n.op==='<'?x<y:n.op==='>'?x>y:n.op==='<='?x<=y:x>=y)
      }
      const x=num(a),y=num(b);if(isErr(x))return x;if(isErr(y))return y;
      switch(n.op){case '+':return x+y;case '-':return x-y;case '*':return x*y;case '/':return y===0?ERR('#ДЕЛ/0!'):x/y;case '^':return Math.pow(x,y)}
      return ERR('#ОШИБКА!')
    }
    return {cellValue,colName,colNum}
  }

  // Пересчитать все формулы книги. Возвращает Set названий листов, где что-то изменилось.
  function recalcBook(book){
    const B=makeBook(book),changed=new Set();
    for(const s of book.sheets){
      for(const [r,row] of Object.entries(s.data.rows)){
        for(const [c,cell] of Object.entries(row)){
          if(cell.f==null)continue;
          let v=B.cellValue(s,colNum(c),+r);
          if(isErr(v))v=v.err;else if(typeof v==='number')v=Math.round(v*1e6)/1e6;
          if(v===undefined)v=null;
          if(cell.v!==v){if(!(cell.v==null&&v==null)){cell.v=v;changed.add(s.title)}}
        }
      }
    }
    return changed
  }
  function checkFormula(src){try{parse(src);return null}catch(e){return e.message}}
  // Дата Excel (число дней) → Date (UTC).
  const serialDate=n=>new Date(Date.UTC(1899,11,30)+Math.round(n)*864e5);
  const isSerial=v=>typeof v==='number'&&v>40000&&v<60000&&Math.floor(v)===v;
  // Блоки месяцев на листе «… Выручка»: дни месяца в столбце A, сверху заголовок месяца, снизу «ИТОГО».
  function monthBlocks(sheet){
    const rows=sheet.data.rows,n=sheet.data.nrows||0,a=r=>rows[String(r)]&&rows[String(r)].A?rows[String(r)].A.v:undefined;
    const isTotal=r=>/^\s*итого/i.test(String(a(r)??''));
    const out=[];let cur=null;
    for(let r=1;r<=n;r++){
      const v=a(r);
      if(isSerial(v)){
        const d=serialDate(v),m=d.getUTCFullYear()+'-'+String(d.getUTCMonth()+1).padStart(2,'0');
        if(cur&&cur.m===m){cur.to=r;continue}
        let from=r;while(from>1&&r-from<6&&!isSerial(a(from-1))&&!isTotal(from-1))from--;
        cur={m,from,to:r};out.push(cur)
      }else if(cur&&isTotal(r)&&cur.to===r-1){cur.to=r;cur=null}
    }
    return out
  }
  const api={parse,recalcBook,checkFormula,colName,colNum,monthBlocks,serialDate,isSerial};
  if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.Formula=api;
})(typeof window!=='undefined'?window:globalThis);
