create extension if not exists pgcrypto with schema extensions;
create extension if not exists btree_gist with schema extensions;
create schema if not exists orbita_private;
revoke all on schema orbita_private from public, anon, authenticated;
create table public.orbita_members(email text primary key, name text not null, enabled boolean not null default true);
insert into public.orbita_members values ('l2mortal01@gmail.com','João Paulo',true);
create table public.orbita_settings(id boolean primary key default true check(id), business_name text not null default 'Órbita Automação', business_context text not null default 'Serviços B2B de automação e IA. Diagnóstico inicial de 30 minutos, sem promessa de preço ou resultado. Entender processo, volume, prazo e participantes da decisão.', hot_threshold int not null default 70 check(hot_threshold between 50 and 100), warm_threshold int not null default 40 check(warm_threshold between 1 and 49), timezone text not null default 'America/Sao_Paulo', sla_minutes int not null default 15 check(sla_minutes between 1 and 1440));
insert into public.orbita_settings(id) values(true);
create table public.orbita_leads(phone text primary key check(phone ~ '^\+[1-9][0-9]{7,14}$'), name text, company text, email text, channel text not null check(channel in ('telegram','whatsapp','manual','demo')), stage text not null default 'new' check(stage in ('new','qualifying','qualified','meeting','won','lost')), mode text not null default 'bot' check(mode in ('bot','human','paused','optout')), qualification jsonb not null default '{}', score int not null default 0 check(score between 0 and 100), temperature text not null default 'unknown' check(temperature in ('unknown','cold','warm','hot')), reasons jsonb not null default '[]', summary text, revision int not null default 0, handoff_requested_at timestamptz, human_owner text, offered_slots jsonb not null default '[]', created_at timestamptz not null default now(), updated_at timestamptz not null default now(), last_inbound_at timestamptz, is_demo boolean not null default false);
create table public.orbita_identities(channel text not null, external_id text not null, phone text not null references public.orbita_leads(phone), primary key(channel,external_id));
create index orbita_identities_phone on public.orbita_identities(phone);
create table public.orbita_messages(id uuid primary key default gen_random_uuid(), phone text not null references public.orbita_leads(phone), channel text not null, external_id text, event_key text unique, direction text not null check(direction in ('in','out')), author text not null check(author in ('lead','bot','human','system')), body text not null check(length(body) between 1 and 6000), status text not null default 'received' check(status in ('received','pending','sending','sent','failed','cancelled','uncertain')), revision int, provider_id text, created_at timestamptz not null default now(), claimed_at timestamptz, error text);
create index orbita_messages_thread on public.orbita_messages(phone,created_at desc);
create index orbita_messages_pending on public.orbita_messages(created_at) where status='pending';
create table public.orbita_slots(id uuid primary key default gen_random_uuid(), resource text not null default 'Consultor', starts_at timestamptz not null, ends_at timestamptz not null, enabled boolean not null default true, check(ends_at>starts_at and ends_at-starts_at<=interval '4 hours'), exclude using gist(resource with =, tstzrange(starts_at,ends_at,'[)') with &&));
create table public.orbita_bookings(id uuid primary key default gen_random_uuid(), phone text not null references public.orbita_leads(phone), slot_id uuid not null references public.orbita_slots(id), status text not null default 'confirmed' check(status in ('confirmed','cancelled','completed','no_show')), created_at timestamptz not null default now());
create unique index orbita_one_booking_slot on public.orbita_bookings(slot_id) where status='confirmed';
create unique index orbita_one_booking_lead on public.orbita_bookings(phone) where status='confirmed';
create table public.orbita_events(id bigint generated always as identity primary key, phone text references public.orbita_leads(phone), kind text not null, detail jsonb not null default '{}', actor text not null default 'automation', created_at timestamptz not null default now());
create index orbita_events_phone on public.orbita_events(phone,created_at desc);
create table public.orbita_tasks(id uuid primary key default gen_random_uuid(), phone text references public.orbita_leads(phone), kind text not null, title text not null, status text not null default 'open' check(status in ('open','done')), due_at timestamptz not null default now(), created_at timestamptz not null default now());
create unique index orbita_one_open_task on public.orbita_tasks(phone,kind) where status='open';
create index orbita_tasks_due on public.orbita_tasks(due_at) where status='open';
create table orbita_private.integration_keys(name text primary key, hash text not null);
alter table orbita_private.integration_keys enable row level security;
grant usage on schema orbita_private to service_role;
grant select on orbita_private.integration_keys to service_role;

create function public.orbita_is_operator() returns boolean language sql stable security invoker set search_path='' as $$ select auth.uid() is not null and exists(select 1 from public.orbita_members where email=lower(auth.jwt()->>'email') and enabled) $$;
alter table public.orbita_members enable row level security;
create policy own_membership on public.orbita_members for select to authenticated using(email=lower((select auth.jwt())->>'email'));
grant select on public.orbita_members to authenticated;
do $$ declare t text; begin foreach t in array array['orbita_settings','orbita_leads','orbita_identities','orbita_messages','orbita_slots','orbita_bookings','orbita_events','orbita_tasks'] loop execute format('alter table public.%I enable row level security',t); execute format('create policy operator_access on public.%I for all to authenticated using ((select public.orbita_is_operator())) with check ((select public.orbita_is_operator()))',t); execute format('grant select,insert,update on public.%I to authenticated',t); execute format('grant all on public.%I to service_role',t); end loop; end $$;
grant usage,select on sequence public.orbita_events_id_seq to authenticated,service_role;
grant select on public.orbita_members to service_role;
revoke all on all tables in schema public from anon;

create function public.orbita_verify_key(p_key text) returns boolean language sql stable security invoker set search_path='' as $$ select exists(select 1 from orbita_private.integration_keys where name='n8n' and hash=encode(extensions.digest(p_key,'sha256'),'hex')) $$;
revoke all on function public.orbita_verify_key(text) from public,anon,authenticated;
grant execute on function public.orbita_verify_key(text) to service_role;

create function public.orbita_ingest(p jsonb) returns jsonb language plpgsql security invoker set search_path='' as $$
declare ph text; l public.orbita_leads; ch text:=p->>'channel'; ext text:=p->>'external_id'; txt text:=left(coalesce(p->>'text',''),6000); mid uuid; sl uuid; bk uuid; reply text; s public.orbita_slots; begin
if ch not in ('telegram','whatsapp','demo') or nullif(ext,'') is null or nullif(p->>'event_key','') is null then raise exception 'Invalid envelope'; end if;
ph:=nullif(p->>'phone','');
if ph is null then select phone into ph from public.orbita_identities where channel=ch and external_id=ext; end if;
if ph is null then return jsonb_build_object('action','request_contact','external_id',ext,'channel',ch); end if;
if ph !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'Phone must be E.164'; end if;
if exists(select 1 from public.orbita_identities where channel=ch and external_id=ext and phone<>ph) then raise exception 'Identity conflict: operator review required'; end if;
insert into public.orbita_leads(phone,channel,name,is_demo) values(ph,ch,nullif(left(p->>'name',120),''),ch='demo') on conflict(phone) do nothing;
select * into l from public.orbita_leads where phone=ph for update;
insert into public.orbita_identities values(ch,ext,ph) on conflict do nothing;
if txt='' then txt:='[Contato compartilhado]'; end if;
insert into public.orbita_messages(phone,channel,external_id,event_key,direction,author,body) values(ph,ch,ext,p->>'event_key','in','lead',txt) on conflict(event_key) do nothing returning id into mid;
if mid is null then return jsonb_build_object('action','duplicate'); end if;
update public.orbita_leads set revision=revision+1,last_inbound_at=now(),updated_at=now(),name=coalesce(name,nullif(left(p->>'name',120),'')) where phone=ph returning * into l;
update public.orbita_messages set status='cancelled',error='Resposta substituída por nova mensagem' where phone=ph and author='bot' and status='pending';
if lower(trim(txt)) ~ '^(parar|sair|cancelar mensagens|stop|não quero receber mensagens)[.! ]*$' then
update public.orbita_leads set mode='optout' where phone=ph; reply:='Tudo bem. O atendimento automático foi encerrado.';
elsif lower(txt) ~ '(falar|conversar).*(humano|pessoa|vendedor|atendente)' then
update public.orbita_leads set mode='human',handoff_requested_at=now() where phone=ph;
insert into public.orbita_tasks(phone,kind,title,due_at) values(ph,'handoff','Lead pediu atendimento humano',now()+interval '15 minutes') on conflict do nothing;
reply:='Vou encaminhar sua conversa para uma pessoa da equipe. Ela receberá o contexto por aqui.';
elsif l.mode<>'bot' then return jsonb_build_object('action','stored','phone',ph,'mode',l.mode);
elsif trim(txt) ~ '^[1-3]$' and jsonb_array_length(l.offered_slots)>0 then
sl:=(l.offered_slots->(trim(txt)::int-1)->>'id')::uuid;
select * into s from public.orbita_slots where id=sl and enabled and starts_at>now()+interval '1 hour' for update;
if s.id is not null and not exists(select 1 from public.orbita_bookings where (slot_id=sl or phone=ph) and status='confirmed') then
insert into public.orbita_bookings(phone,slot_id) values(ph,sl) returning id into bk;
update public.orbita_leads set stage='meeting',offered_slots='[]',mode=case when temperature='hot' then 'human' else mode end where phone=ph;
reply:='Reunião confirmada para '||to_char(s.starts_at at time zone 'America/Sao_Paulo','DD/MM às HH24:MI')||' (Brasília). A equipe continuará com você por aqui.';
insert into public.orbita_events(phone,kind,detail) values(ph,'booking_confirmed',jsonb_build_object('booking',bk));
else reply:='Esse horário não está mais disponível ou você já tem uma reunião marcada. Vou chamar a equipe para ajustar sua agenda.'; update public.orbita_leads set mode='human',handoff_requested_at=now() where phone=ph; insert into public.orbita_tasks(phone,kind,title) values(ph,'handoff','Ajustar agendamento') on conflict do nothing; end if;
end if;
if reply is not null then insert into public.orbita_messages(phone,channel,external_id,direction,author,body,status,revision) values(ph,ch,ext,'out','system',reply,'pending',l.revision); return jsonb_build_object('action','stored','phone',ph); end if;
return jsonb_build_object('action','qualify','phone',ph,'revision',l.revision,'lead',to_jsonb(l),'message',txt,'context',coalesce((select jsonb_agg(x) from(select author,body from public.orbita_messages where phone=ph and (direction='in' or status='sent') order by created_at desc limit 16)x),'[]'),'settings',(select to_jsonb(o) from public.orbita_settings o));
end $$;

create function public.orbita_commit(p jsonb) returns jsonb language plpgsql security invoker set search_path='' as $$
declare l public.orbita_leads; q jsonb; a jsonb:=coalesce(p->'extracted','{}'); total int:=0; r jsonb:='[]'; temp text; reply text:=left(p->>'reply',3500); offered jsonb; ident public.orbita_identities; cfg public.orbita_settings; begin
select * into l from public.orbita_leads where phone=p->>'phone' for update;
if l.phone is null or l.mode<>'bot' or l.revision<>(p->>'revision')::int then return jsonb_build_object('saved',false,'reason','stale_or_human'); end if;
if reply is null or length(reply)=0 then raise exception 'Empty reply'; end if;
select * into cfg from public.orbita_settings;
q:=l.qualification||jsonb_strip_nulls(a);
if q->>'fit'='true' then total:=total+35;r:=r||jsonb_build_array(jsonb_build_object('label','Aderência a automação B2B','points',35));end if;
if length(coalesce(q->>'need',''))>5 then total:=total+25;r:=r||jsonb_build_array(jsonb_build_object('label','Necessidade declarada','points',25));end if;
if q->>'urgency'='30_days' then total:=total+25;r:=r||jsonb_build_array(jsonb_build_object('label','Prazo de até 30 dias','points',25));end if;
if q->>'decision' in ('decision_maker','involved') then total:=total+15;r:=r||jsonb_build_array(jsonb_build_object('label','Participa da decisão','points',15));end if;
temp:=case when total>=cfg.hot_threshold and q->>'fit'='true' and length(coalesce(q->>'need',''))>5 then 'hot' when total>=cfg.warm_threshold then 'warm' when q='{}' then 'unknown' else 'cold' end;
select * into ident from public.orbita_identities where phone=l.phone and channel=l.channel limit 1;
if coalesce((p->>'offer_meeting')::boolean,false) or temp='hot' then
select coalesce(jsonb_agg(z),'[]') into offered from(select s.id,s.starts_at,s.resource from public.orbita_slots s where s.enabled and s.starts_at>now()+interval '2 hours' and s.starts_at<now()+interval '14 days' and not exists(select 1 from public.orbita_bookings b where b.slot_id=s.id and b.status='confirmed') order by s.starts_at limit 3)z;
if jsonb_array_length(offered)>0 and not exists(select 1 from public.orbita_bookings where phone=l.phone and status='confirmed') then
reply:=case when temp='hot' then 'Seu cenário tem aderência ao que fazemos. Já sinalizei a equipe comercial. Se quiser, podemos reservar um diagnóstico de 30 minutos.' else 'Podemos conversar em um diagnóstico de 30 minutos.' end||E'\nEscolha uma opção (horário de Brasília):';
for i in 0..jsonb_array_length(offered)-1 loop reply:=reply||E'\n'||(i+1)::text||' — '||to_char((offered->i->>'starts_at')::timestamptz at time zone 'America/Sao_Paulo','DD/MM às HH24:MI');end loop;
reply:=reply||E'\nResponda somente com o número. A reserva será confirmada na próxima mensagem.';
else offered:='[]'; reply:='Já sinalizei a equipe comercial sobre seu interesse. No momento não tenho horários livres para oferecer; uma pessoa continuará o agendamento com você.'; end if;
end if;
update public.orbita_leads set name=coalesce(nullif(left(a->>'name',120),''),name),company=coalesce(nullif(left(a->>'company',160),''),company),email=coalesce(nullif(left(a->>'email',180),''),email),qualification=q,score=total,temperature=temp,reasons=r,summary=left(p->>'summary',1000),stage=case when stage in ('meeting','won','lost') then stage when temp='hot' then 'qualified' else 'qualifying' end,offered_slots=coalesce(offered,offered_slots),handoff_requested_at=case when temp='hot' then coalesce(handoff_requested_at,now()) else handoff_requested_at end,updated_at=now() where phone=l.phone;
if temp='hot' then insert into public.orbita_tasks(phone,kind,title,due_at) values(l.phone,'handoff','Lead quente: assumir conversa',now()+make_interval(mins=>cfg.sla_minutes)) on conflict do nothing;end if;
insert into public.orbita_messages(phone,channel,external_id,event_key,direction,author,body,status,revision) values(l.phone,ident.channel,ident.external_id,'reply:'||l.phone||':'||l.revision,'out','bot',reply,'pending',l.revision) on conflict(event_key) do nothing;
insert into public.orbita_events(phone,kind,detail) values(l.phone,'qualification_updated',jsonb_build_object('score',total,'reasons',r,'rule_version','1.0','evidence',p->'evidence'));
return jsonb_build_object('saved',true,'score',total,'temperature',temp);
end $$;

create function public.orbita_claim() returns setof public.orbita_messages language plpgsql security invoker set search_path='' as $$ begin
update public.orbita_messages set status='uncertain',error='Envio sem confirmação. Conferir no canal antes de tentar novamente.' where status='sending' and claimed_at<now()-interval '3 minutes';
update public.orbita_messages m set status='cancelled',error='IA pausada ou revisão antiga' from public.orbita_leads l where m.phone=l.phone and m.author='bot' and m.status='pending' and (l.mode<>'bot' or m.revision<>l.revision);
update public.orbita_messages m set status='failed',error='Janela de 24h encerrada: usar template aprovado no WhatsApp' from public.orbita_leads l where m.phone=l.phone and m.channel='whatsapp' and m.status='pending' and (l.last_inbound_at is null or l.last_inbound_at<now()-interval '24 hours');
return query update public.orbita_messages set status='sending',claimed_at=now() where id in(select id from public.orbita_messages where status='pending' and channel in ('telegram','whatsapp') order by created_at for update skip locked limit 10) returning *;
end $$;

create function public.orbita_ack(p jsonb) returns jsonb language plpgsql security invoker set search_path='' as $$ begin
update public.orbita_messages set status=case when p->>'ok'='true' then 'sent' else 'failed' end,provider_id=p->>'provider_id',error=left(p->>'error',1000) where id=(p->>'id')::uuid and status='sending';
return jsonb_build_object('ok',true);end $$;

create function public.orbita_operator(p_action text,p jsonb) returns jsonb language plpgsql security invoker set search_path='' as $$
declare l public.orbita_leads; ident public.orbita_identities; uid text:=auth.jwt()->>'email'; v_id uuid; begin
if not public.orbita_is_operator() then raise exception 'Access denied';end if;
if p_action='settings' then update public.orbita_settings set business_name=left(p->>'business_name',100),business_context=left(p->>'business_context',4000),hot_threshold=(p->>'hot_threshold')::int,warm_threshold=(p->>'warm_threshold')::int,sla_minutes=(p->>'sla_minutes')::int;return jsonb_build_object('ok',true);end if;
if p_action='slot' then insert into public.orbita_slots(resource,starts_at,ends_at) values(coalesce(nullif(p->>'resource',''),'Consultor'),(p->>'starts_at')::timestamptz,(p->>'ends_at')::timestamptz) returning id into v_id;return jsonb_build_object('id',v_id);end if;
if p_action='close_slot' then update public.orbita_slots set enabled=false where id=(p->>'id')::uuid and not exists(select 1 from public.orbita_bookings where slot_id=(p->>'id')::uuid and status='confirmed');return jsonb_build_object('ok',true);end if;
if p_action='cancel_booking' then update public.orbita_bookings set status='cancelled' where id=(p->>'id')::uuid returning phone into uid;update public.orbita_leads set stage='qualified' where phone=uid and stage='meeting';return jsonb_build_object('ok',true);end if;
if p_action='create_lead' then insert into public.orbita_leads(phone,name,company,channel) values(p->>'phone',nullif(p->>'name',''),nullif(p->>'company',''),'manual'); return jsonb_build_object('ok',true);end if;
select * into l from public.orbita_leads where phone=p->>'phone' for update;
if l.phone is null then raise exception 'Lead not found';end if;
if p_action='mode' then
if p->>'mode' not in ('bot','human','paused') or l.mode='optout' then raise exception 'Invalid mode or opted out';end if;
update public.orbita_leads set mode=p->>'mode',human_owner=case when p->>'mode'='human' then uid else human_owner end,revision=revision+1,updated_at=now() where phone=l.phone;
update public.orbita_messages set status='cancelled',error='Operador alterou o atendimento' where phone=l.phone and author='bot' and status='pending';
if p->>'mode'='human' then update public.orbita_tasks set status='done' where phone=l.phone and kind='handoff';end if;
elsif p_action='stage' then update public.orbita_leads set stage=p->>'stage',updated_at=now() where phone=l.phone;
elsif p_action='edit' then update public.orbita_leads set name=left(p->>'name',120),company=left(p->>'company',160),email=left(p->>'email',180),updated_at=now() where phone=l.phone;
elsif p_action='send' then
if l.mode<>'human' then raise exception 'Assuma a conversa antes de enviar';end if;
select * into ident from public.orbita_identities where phone=l.phone and channel=l.channel limit 1;
if ident.phone is null then raise exception 'Lead ainda não tem canal de conversa';end if;
insert into public.orbita_messages(phone,channel,external_id,event_key,direction,author,body,status,revision) values(l.phone,ident.channel,ident.external_id,'human:'||(p->>'request_id'),'out','human',left(p->>'body',4000),'pending',l.revision) on conflict(event_key) do nothing;
elsif p_action='book' then
perform 1 from public.orbita_slots where id=(p->>'slot_id')::uuid and enabled and starts_at>now() for update;
if not found then raise exception 'Horário indisponível';end if;
insert into public.orbita_bookings(phone,slot_id) values(l.phone,(p->>'slot_id')::uuid); update public.orbita_leads set stage='meeting',updated_at=now() where phone=l.phone;
else raise exception 'Unknown action';end if;
insert into public.orbita_events(phone,kind,detail,actor) values(l.phone,'operator_'||p_action,p,uid);
return jsonb_build_object('ok',true);end $$;

revoke all on function public.orbita_ingest(jsonb),public.orbita_commit(jsonb),public.orbita_claim(),public.orbita_ack(jsonb) from public,anon,authenticated;
grant execute on function public.orbita_ingest(jsonb),public.orbita_commit(jsonb),public.orbita_claim(),public.orbita_ack(jsonb) to service_role;
revoke all on function public.orbita_operator(text,jsonb),public.orbita_is_operator() from public,anon;
grant execute on function public.orbita_operator(text,jsonb),public.orbita_is_operator() to authenticated;
alter publication supabase_realtime add table public.orbita_leads,public.orbita_messages,public.orbita_slots,public.orbita_bookings,public.orbita_tasks;
