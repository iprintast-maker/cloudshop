// Use the documented Pages REST API and the already verified artifact ID.
// This avoids the separate artifact-results index used by deploy-pages@v4.
import {appendFileSync} from 'node:fs';
const root=`https://api.github.com/repos/${process.env.GITHUB_REPOSITORY}/pages/deployments`;
const headers={Authorization:`Bearer ${process.env.GH_TOKEN}`,Accept:'application/vnd.github+json','Content-Type':'application/json'};
let deployment=null,done=false;
async function request(url,options={}){const r=await fetch(url,{headers,...options,signal:AbortSignal.timeout(30000)});if(!r.ok)throw Error(`Pages request failed: ${r.status}`);return r.status===204?null:r.json();}
async function cancel(){if(deployment&&!done){try{await request(`${root}/${deployment}/cancel`,{method:'POST'});}catch{}}}
process.on('SIGTERM',async()=>{await cancel();process.exit(1)});
process.on('SIGINT',async()=>{await cancel();process.exit(1)});
try{
 const tokenResponse=await fetch(process.env.ACTIONS_ID_TOKEN_REQUEST_URL,{headers:{Authorization:`Bearer ${process.env.ACTIONS_ID_TOKEN_REQUEST_TOKEN}`},signal:AbortSignal.timeout(30000)});
 if(!tokenResponse.ok)throw Error(`OIDC request failed: ${tokenResponse.status}`);
 const token=(await tokenResponse.json()).value;
 const artifact=Number(process.env.ARTIFACT_ID);if(!Number.isSafeInteger(artifact)||artifact<=0)throw Error('Invalid artifact ID');
 const created=await request(root,{method:'POST',body:JSON.stringify({artifact_id:artifact,pages_build_version:process.env.GITHUB_SHA,oidc_token:token})});
 deployment=created.id||created.status_url?.split('/').pop()||process.env.GITHUB_SHA;
 if(created.page_url)appendFileSync(process.env.GITHUB_OUTPUT,`page_url=${created.page_url}\n`);
 for(let n=0;n<60;n++){
  await new Promise(resolve=>setTimeout(resolve,5000));
  const state=await request(`${root}/${deployment}`);
  console.log(`Pages deployment: ${state.status}`);
  if(state.status==='succeed'){done=true;break;}
  if(['deployment_failed','deployment_content_failed','deployment_cancelled','failed','cancelled'].includes(state.status))throw Error(`Pages deployment failed: ${state.status}`);
 }
 if(!done)throw Error('Pages deployment timed out');
}finally{await cancel();}
