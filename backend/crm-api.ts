import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.57.4';
const url=Deno.env.get('SUPABASE_URL')!,secret=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const service=createClient(url,secret,{auth:{persistSession:false}});
const origins=['https://orbita-crm-opens-joao.limalipe355.chatgpt.site','http://127.0.0.1:4173'];
Deno.serve(async req=>{
 const origin=req.headers.get('origin')||'';
 const cors={'Access-Control-Allow-Origin':origins.includes(origin)?origin:origins[0],'Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Access-Control-Allow-Methods':'POST,OPTIONS','Vary':'Origin'};
 const reply=(d:unknown,status=200)=>new Response(JSON.stringify(d),{status,headers:{...cors,'Content-Type':'application/json'}});
 if(req.method==='OPTIONS')return new Response(null,{headers:cors});
 if(req.method!=='POST')return reply({error:'POST required'},405);
 const token=req.headers.get('Authorization')?.replace(/^Bearer /i,'');
 if(!token)return reply({error:'Entre para continuar'},401);
 const {data:auth,error:authErr}=await service.auth.getUser(token);
 if(authErr||!auth.user)return reply({error:'Sessão expirada. Entre novamente.'},401);
 const {data:member}=await service.from('orbita_members').select('*').eq('user_id',auth.user.id).eq('enabled',true).maybeSingle();
 if(!member)return reply({error:'Acesso desativado ou não autorizado'},403);
 try{
  const raw=await req.text();if(raw.length>20000)return reply({error:'Pedido muito grande'},413);
  const {action,data={}}=JSON.parse(raw);
  if(action==='simulate'){
   const client=createClient(url,Deno.env.get('SUPABASE_ANON_KEY')!,{global:{headers:{Authorization:'Bearer '+token}},auth:{persistSession:false}});
   const {data:q,error}=await client.rpc('orbita_simulator_enqueue',{p_phone:data.phone,p_text:data.text,p_id:data.id});if(error)throw error;
   if(q.status==='pending'){
    const {data:cfg,error:cErr}=await service.rpc('orbita_dispatch_config');if(cErr||!cfg)throw Error('Integração do simulador não configurada');
    try{
     const r=await fetch(cfg.url,{method:'POST',headers:{'Content-Type':'application/json','x-orbita-key':cfg.api_key},body:JSON.stringify({request_id:q.id}),signal:AbortSignal.timeout(15000)});
     if(!r.ok)throw Error('n8n indisponível ('+r.status+'). Verifique a publicação do fluxo.');
    }catch(e){await service.from('orbita_simulator_requests').update({status:'failed',error:'Não foi possível iniciar o n8n. Confira o fluxo e tente novamente.',processed_at:new Date().toISOString()}).eq('id',q.id).eq('status','pending');throw e;}
   }
   return reply(q);
  }
  if(action==='create_user'){
   if(member.role!=='admin')return reply({error:'Somente administradores'},403);
   const email=String(data.email||'').trim().toLowerCase(),name=String(data.name||'').trim();
   if(!email.includes('@')||!name||!['admin','user'].includes(data.role)||String(data.password||'').length<12)throw Error('Preencha nome, e-mail, perfil e senha com pelo menos 12 caracteres.');
   const {data:u,error}=await service.auth.admin.createUser({email,password:data.password,email_confirm:true,user_metadata:{name}});if(error)throw error;
   const {error:mErr}=await service.from('orbita_members').insert({email,name,role:data.role,user_id:u.user.id,enabled:true});
   if(mErr){await service.auth.admin.deleteUser(u.user.id);throw Error('Não foi possível liberar o acesso. Tente novamente.');}
   await service.from('orbita_events').insert({kind:'member_created',actor:member.email,detail:{email,role:data.role}});
   return reply({ok:true});
  }
  return reply({error:'Ação inválida'},400);
 }catch(e){return reply({error:e instanceof Error?e.message:String((e as {message?:string}).message||'Não foi possível concluir')},400);}
});
