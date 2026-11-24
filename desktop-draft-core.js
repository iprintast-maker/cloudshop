(function(root){
 const key=user=>'iprint.desktop.draft.v1:'+user;
 function parse(value,user){try{const x=JSON.parse(value);return x?.version===1&&x.user===user&&Array.isArray(x.items)&&x.items.length<=1000&&x.items.every(i=>Number(i.catalogId)>0&&Number.isFinite(Number(i.quantity))&&Number(i.quantity)>=0&&Number(i.unitPrice)>=0)?x:null;}catch{return null;}}
 function compatible(d,user,s){return !!d&&d.user===user&&Number(d.context?.personId)===Number(s?.personId)&&Number(d.context?.branchId)===Number(s?.branchId);}
 root.CloudshopDesktopDraft={key,parse,compatible};
})(typeof window==='undefined'?globalThis:window);
