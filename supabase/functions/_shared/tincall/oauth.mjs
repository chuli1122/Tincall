// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

// MCP OAuth uses public-client authorization code + PKCE. Approval happens in
// the owner's authenticated Tincall app; a browser never receives the phone key.
export class OAuthError extends Error {
  constructor(code,status=400){super(code);this.code=code;this.status=status;}
}
const check=(value,code='invalid_request',status=400)=>{if(!value)throw new OAuthError(code,status);};
const response=(value,status=200)=>new Response(JSON.stringify(value),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store','Pragma':'no-cache'}});
const opaque=prefix=>prefix+Array.from(crypto.getRandomValues(new Uint8Array(32)),b=>b.toString(16).padStart(2,'0')).join('');
const userCode=()=>Array.from(crypto.getRandomValues(new Uint8Array(8)),b=>'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'[b%32]).join('');
const normalizeCode=value=>typeof value==='string'?value.toUpperCase().replace(/[\s-]/g,''):'';
const parameters=search=>{const result={};for(const [key,value] of search){check(!(key in result));result[key]=value;}return result;};
async function body(request,json=false){
  const type=request.headers.get('content-type')?.split(';')[0].trim();
  check(type===(json?'application/json':'application/x-www-form-urlencoded'));
  const reader=request.body?.getReader();check(reader);let size=0;const chunks=[];
  try{while(true){const {done,value}=await reader.read();if(done)break;size+=value.length;check(size<=16384);chunks.push(value);}}finally{reader.releaseLock();}
  const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
  const text=new TextDecoder().decode(bytes);
  if(!json)return parameters(new URLSearchParams(text));
  let value;try{value=JSON.parse(text);}catch{throw new OAuthError('invalid_request');}
  check(value && typeof value==='object' && !Array.isArray(value));return value;
}
function callback(uri){
  let url;try{url=new URL(uri);}catch{throw new OAuthError('invalid_redirect_uri');}
  // Exact platform redirects are checked again before authorization and
  // exchange; do not accept arbitrary callback URLs.
  const chatGPT=url.origin==='https://chatgpt.com' &&
    (url.pathname==='/connector_platform_oauth_redirect' || /^\/connector\/oauth\/[A-Za-z0-9_-]+$/.test(url.pathname));
  const claude=url.origin==='https://claude.ai' && url.pathname==='/api/mcp/auth_callback';
  check(!url.username && !url.password && !url.search && !url.hash && (chatGPT || claude),'invalid_redirect_uri');
  return uri;
}
export function createMCPOAuth({store,baseURL}) {
  const base=baseURL.replace(/\/$/,'');const resource=base+'/mcp';
  const metadataURL=base+'/.well-known/oauth-protected-resource';
  const scope='tincall:mcp';
  const resourceCheck=value=>check(value===undefined || value===resource,'invalid_target');
  const redirect=(url,status=303)=>new Response(null,{status,headers:{Location:url,'Cache-Control':'no-store','Referrer-Policy':'no-referrer'}});
  function authorizationResponse(request,error){
    const url=new URL(request.redirect_uri);url.searchParams.set('iss',base);
    if(request.state)url.searchParams.set('state',request.state);
    if(error)url.searchParams.set('error',error);else url.searchParams.set('code',request.code);
    return redirect(url.href);
  }
  async function publicResponse(request,path){
    if(request.method==='GET' && path==='/.well-known/oauth-protected-resource')
      return response({resource,authorization_servers:[base],scopes_supported:[scope],bearer_methods_supported:['header']});
    // OpenID discovery also supports issuers with a path prefix, including the
    // Supabase gateway which cannot serve RFC 8414 routes at the host root.
    if(request.method==='GET' && ['/.well-known/oauth-authorization-server','/.well-known/openid-configuration'].includes(path))
      return response({issuer:base,authorization_endpoint:base+'/oauth/authorize',token_endpoint:base+'/oauth/token',registration_endpoint:base+'/oauth/register',revocation_endpoint:base+'/oauth/revoke',response_types_supported:['code'],grant_types_supported:['authorization_code','refresh_token'],token_endpoint_auth_methods_supported:['none'],code_challenge_methods_supported:['S256'],scopes_supported:[scope],authorization_response_iss_parameter_supported:true});
    if(!['/oauth/register','/oauth/authorize','/oauth/consent','/oauth/token','/oauth/revoke'].includes(path))return null;
    const external=new URL(base);check(external.protocol==='https:' || (external.protocol==='http:' && ['localhost','127.0.0.1','[::1]'].includes(external.hostname)),'server_configuration_missing',503);
    if(path==='/oauth/register'){
      check(request.method==='POST','invalid_request',405);const p=await body(request,true);
      check(Array.isArray(p.redirect_uris) && p.redirect_uris.length>=1 && p.redirect_uris.length<=5);
      p.redirect_uris.forEach(callback);
      check(p.token_endpoint_auth_method===undefined || p.token_endpoint_auth_method==='none','invalid_client_metadata');
      check(p.grant_types===undefined || (Array.isArray(p.grant_types) && p.grant_types.every(v=>['authorization_code','refresh_token'].includes(v))),'invalid_client_metadata');
      check(p.response_types===undefined || (Array.isArray(p.response_types) && p.response_types.every(v=>v==='code')),'invalid_client_metadata');
      const client={client_id:opaque('tcc_'),client_name:typeof p.client_name==='string'?p.client_name.slice(0,100):'MCP client',redirect_uris:[...new Set(p.redirect_uris)]};
      await store.oauthCommand('client.create',client);
      return response({...client,token_endpoint_auth_method:'none',grant_types:['authorization_code','refresh_token'],response_types:['code']},201);
    }
    if(path==='/oauth/authorize'){
      check(request.method==='GET','invalid_request',405);const p=parameters(new URL(request.url).searchParams);
      check(p.response_type==='code','unsupported_response_type');check(p.code_challenge_method==='S256' && /^[A-Za-z0-9_-]{43}$/.test(p.code_challenge??''));
      resourceCheck(p.resource);check(p.scope===undefined || p.scope===scope,'invalid_scope');check((p.state??'').length<=2048);
      const client=await store.oauthCommand('client.get',{client_id:p.client_id});check(client && client.redirect_uris.includes(p.redirect_uri),'invalid_client');
      const id=opaque('tcr_');
      await store.oauthCommand('request.create',{id,user_code:userCode(),client_id:p.client_id,redirect_uri:p.redirect_uri,state:p.state??'',resource,code_challenge:p.code_challenge});
      return redirect(base+'/oauth/consent?request='+id);
    }
    if(path==='/oauth/consent'){
      check(request.method==='GET','invalid_request',405);
      const id=new URL(request.url).searchParams.get('request');check(/^tcr_[0-9a-f]{64}$/.test(id??''));
      const pending=await store.oauthCommand('request.get',{id});check(pending,'expired_request',410);
      if(pending.denied)return authorizationResponse(pending,'access_denied');
      if(pending.code)return authorizationResponse(pending);
      const code=pending.user_code.slice(0,4)+'-'+pending.user_code.slice(4);
      return new Response(`Tincall · MCP OAuth 授权\n\n一次性授权码：${code}\n\n1. 打开 Tincall，在设置中打开这条云端连接。\n2. 进入「MCP OAuth 授权」，输入上面的授权码。\n3. 选择允许访问的联系人，确认授权。\n4. 回到本页面刷新，继续连接。\n\n授权码 10 分钟内有效。只授权你刚刚发起的连接。不要输入别人发给你的授权码，也不要替别人批准授权。\n\nOpen this cloud connection in Tincall settings and choose “MCP OAuth authorization”. Enter ${code}, choose a contact and approve, then refresh this page. Expires in 10 minutes. Never enter a code sent by someone else or approve authorization on their behalf.`,{headers:{'Content-Type':'text/plain; charset=utf-8','Cache-Control':'no-store','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff'}});
    }
    if(path==='/oauth/revoke'){
      check(request.method==='POST','invalid_request',405);const p=await body(request);
      check(typeof p.token==='string' && p.token.length<=200);await store.oauthCommand('revoke',{token:p.token,client_id:p.client_id??''});return response({});
    }
    check(request.method==='POST','invalid_request',405);const p=await body(request);resourceCheck(p.resource);
    check(/^tcc_[0-9a-f]{64}$/.test(p.client_id??''),'invalid_client');
    const tokens={access_token:opaque('tcoa_'),refresh_token:opaque('tcor_')};
    let saved;
    if(p.grant_type==='authorization_code'){
      check(/^tcoc_[0-9a-f]{64}$/.test(p.code??''),'invalid_grant');
      check(/^[A-Za-z0-9._~-]{43,128}$/.test(p.code_verifier??''),'invalid_grant');
      const pending=await store.oauthCommand('request.get',{code:p.code});
      check(pending && pending.client_id===p.client_id && pending.redirect_uri===p.redirect_uri && pending.resource===resource,'invalid_grant');
      // S256 is the protocol's required PKCE proof, unrelated to file checksums.
      const bytes=new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(p.code_verifier)));
      const challenge=btoa(String.fromCharCode(...bytes)).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');
      check(challenge===pending.code_challenge,'invalid_grant');
      saved=await store.oauthCommand('exchange',{code:p.code,client_id:p.client_id,redirect_uri:p.redirect_uri,resource,...tokens});
    } else if(p.grant_type==='refresh_token'){
      check(/^tcor_[0-9a-f]{64}$/.test(p.refresh_token??''),'invalid_grant');
      saved=await store.oauthCommand('refresh',{refresh_token:p.refresh_token,client_id:p.client_id,resource,next_refresh_token:tokens.refresh_token,access_token:tokens.access_token});
    } else throw new OAuthError('unsupported_grant_type');
    check(saved,'invalid_grant');return response({...tokens,token_type:'Bearer',expires_in:3600,scope});
  }
  async function ownerResponse(request,path,principal){
    if(!['/oauth/requests/lookup','/oauth/requests/decide'].includes(path))return null;
    check(request.method==='POST','invalid_request',405);check(!principal.contact_id,'access_denied',403);
    const p=await body(request,true);const code=normalizeCode(p.user_code);check(/^[A-HJ-NP-Z2-9]{8}$/.test(code));
    const pending=await store.oauthCommand('request.get',{user_code:code});check(pending && !pending.code && !pending.denied,'expired_request',410);
    const {bindings}=await store.mcpRoleCommand(principal.owner_id,'list');
    if(path.endsWith('/lookup')){
      const client=await store.oauthCommand('client.get',{client_id:pending.client_id});
      return response({user_code:code,client_name:client?.client_name || 'MCP client',requested_at:new Date(Date.parse(pending.expires_at)-600000).toISOString(),contacts:bindings.map(b=>({contact_id:b.contact_id,display_name:b.display_name}))});
    }
    check(['approve','deny'].includes(p.decision));
    if(p.decision==='approve')check(bindings.some(b=>b.contact_id===p.contact_id),'invalid_contact');
    const decided=await store.oauthCommand('request.decide',{user_code:code,owner_id:principal.owner_id,contact_id:p.decision==='approve'?p.contact_id:null,denied:p.decision==='deny',code:opaque('tcoc_')});
    check(decided,'expired_request',410);return response({approved:p.decision==='approve',continuation_url:base+'/oauth/consent?request='+pending.id});
  }
  return {publicResponse,ownerResponse,metadataURL,resource,
    challenge(){return `Bearer resource_metadata="${metadataURL}", scope="${scope}"`;},
    async authenticate(token){
      check(/^tcoa_[0-9a-f]{64}$/.test(token),'invalid_token',401);
      const principal=await store.oauthCommand('authenticate',{access_token:token,resource});check(principal,'invalid_token',401);return principal;
    }};
}
