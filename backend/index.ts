import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.57.4';
const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false}});
Deno.serve(async req=>{
 const reply=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json'}});
 if(req.method!=='POST')return reply({error:'POST required'},405);
 const key=req.headers.get('x-orbita-key');if(!key||key.length<32)return reply({error:'Unauthorized'},401);
 const verified=await db.rpc('orbita_verify_key',{p_key:key});if(verified.error||verified.data!==true)return reply({error:'Unauthorized'},401);
 try{
  const raw=await req.text();if(raw.length>32000)return reply({error:'Payload too large'},413);
  const {action,data={}}=JSON.parse(raw);let result;
  if(action==='ingest')result=await db.rpc('orbita_ingest',{p:data});
  else if(action==='simulator_process')result=await db.rpc('orbita_simulator_process',{p_id:data.id});
  else if(action==='simulator_next')result=await db.rpc('orbita_simulator_next');
  else if(action==='commit')result=await db.rpc('orbita_commit',{p:data});
  else if(action==='claim_message')result=await db.rpc('orbita_claim_message',{p_id:data.id});
  else if(action==='claim')result=await db.rpc('orbita_claim_channel',{p_channel:data.channel});
  else if(action==='ack')result=await db.rpc('orbita_ack',{p:data});
  else if(action==='authorize')result=await db.rpc('orbita_authorize_delivery',{p_id:data.id});
  else if(action==='failure')result=await db.rpc('orbita_fail',{p_phone:data.phone,p_revision:data.revision});
  else return reply({error:'Unknown action'},400);
  if(result.error)return reply({error:result.error.message},400);
  return reply(result.data??{ok:true});
 }catch{return reply({error:'Invalid request'},400)}
});


