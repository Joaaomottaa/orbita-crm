-- RBAC: browser reads through RLS; mutations through a checked private RPC.
alter table public.orbita_members add column user_id uuid unique references auth.users(id), add column role text not null default 'user' check(role in ('admin','user')), add column is_demo boolean not null default false,add column created_at timestamptz not null default now();
update public.orbita_members set role='admin' where email='l2mortal01@gmail.com';
alter table public.orbita_leads add column assigned_to uuid references auth.users(id);
create index orbita_leads_assigned on public.orbita_leads(assigned_to,created_at desc);
alter table public.orbita_messages add column actor_id uuid references auth.users(id);
create index orbita_messages_actor on public.orbita_messages(actor_id,created_at desc) where actor_id is not null;
grant usage on schema orbita_private to authenticated;
create function orbita_private.is_admin() returns boolean language sql stable security definer set search_path='' as $$select auth.uid() is not null and exists(select 1 from public.orbita_members where user_id=auth.uid() and enabled and role='admin')$$;
create function orbita_private.is_member() returns boolean language sql stable security definer set search_path='' as $$select auth.uid() is not null and exists(select 1 from public.orbita_members where user_id=auth.uid() and enabled)$$;
create function orbita_private.can_lead(ph text) returns boolean language sql stable security definer set search_path='' as $$select orbita_private.is_member() and (orbita_private.is_admin() or exists(select 1 from public.orbita_leads where phone=ph and assigned_to=auth.uid()))$$;
revoke all on function orbita_private.is_admin(),orbita_private.is_member(),orbita_private.can_lead(text) from public,anon;
grant execute on function orbita_private.is_admin(),orbita_private.is_member(),orbita_private.can_lead(text) to authenticated,service_role;
create or replace function public.orbita_is_operator() returns boolean language sql stable security invoker set search_path='' as $$select orbita_private.is_member()$$;
create function public.orbita_is_admin() returns boolean language sql stable security invoker set search_path='' as $$select orbita_private.is_admin()$$;
revoke all on function public.orbita_is_admin() from public,anon;grant execute on function public.orbita_is_admin() to authenticated;
drop policy own_membership on public.orbita_members;
create policy members_read on public.orbita_members for select to authenticated using(user_id=(select auth.uid()) or (select orbita_private.is_admin()));
grant all on public.orbita_members to service_role;
do $$declare t text;begin
foreach t in array array['orbita_settings','orbita_leads','orbita_identities','orbita_messages','orbita_slots','orbita_bookings','orbita_events','orbita_tasks'] loop
execute format('drop policy operator_access on public.%I',t);
execute format('revoke insert,update,delete on public.%I from authenticated',t);
end loop;end$$;
create policy leads_read on public.orbita_leads for select to authenticated using((select orbita_private.is_member()) and ((select orbita_private.is_admin()) or assigned_to=(select auth.uid())));
do $$declare t text;begin foreach t in array array['orbita_identities','orbita_messages','orbita_bookings','orbita_events','orbita_tasks'] loop
execute format('create policy owned_read on public.%I for select to authenticated using (orbita_private.can_lead(phone) or (select orbita_private.is_admin()))',t);
end loop;end$$;
create policy settings_read on public.orbita_settings for select to authenticated using((select orbita_private.is_member()));
create policy slots_read on public.orbita_slots for select to authenticated using((select orbita_private.is_member()));
drop policy simulator_read on public.orbita_simulator_requests;
drop policy simulator_insert on public.orbita_simulator_requests;
revoke insert,update,delete on public.orbita_simulator_requests from authenticated;
create policy simulator_read on public.orbita_simulator_requests for select to authenticated using((select orbita_private.is_member()) and (created_by=(select auth.uid()) or (select orbita_private.is_admin())));
alter table public.orbita_simulator_requests drop constraint orbita_simulator_requests_phone_check;
alter table public.orbita_simulator_requests add constraint orbita_simulator_requests_phone_check check(phone ~ '^\+[1-9][0-9]{7,14}$');
create table orbita_private.dispatch_config(id boolean primary key default true check(id),url text not null,api_key text not null);
alter table orbita_private.dispatch_config enable row level security;
revoke all on orbita_private.dispatch_config from public,anon,authenticated;
grant all on orbita_private.dispatch_config to service_role;
create function public.orbita_dispatch_config() returns jsonb language sql security invoker set search_path='' as $$select to_jsonb(c) from orbita_private.dispatch_config c$$;
revoke all on function public.orbita_dispatch_config() from public,anon,authenticated;grant execute on function public.orbita_dispatch_config() to service_role;
CREATE OR REPLACE FUNCTION orbita_private.operator(p_action text, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare l public.orbita_leads; ident public.orbita_identities; uid text:=auth.jwt()->>'email'; v_id uuid; begin
if not public.orbita_is_operator() then raise exception 'Access denied';end if;
if p_action in ('settings','slot','close_slot','cancel_booking','assign','member') and not orbita_private.is_admin() then raise exception 'Somente administradores';end if;
if p_action='member' then
if p->>'email'=uid then raise exception 'Não altere seu próprio acesso';end if;
update public.orbita_members set enabled=coalesce((p->>'enabled')::boolean,enabled),name=coalesce(nullif(p->>'name',''),name) where email=p->>'email';
insert into public.orbita_events(kind,detail,actor) values('member_updated',p,uid);
return jsonb_build_object('ok',true);end if;
if p_action='assign' then
if not exists(select 1 from public.orbita_members where user_id=(p->>'assigned_to')::uuid and enabled) then raise exception 'Responsável inválido';end if;
update public.orbita_leads set assigned_to=(p->>'assigned_to')::uuid,updated_at=now() where phone=p->>'phone';
insert into public.orbita_events(phone,kind,detail,actor) values(p->>'phone','lead_assigned',p,uid);
return jsonb_build_object('ok',true);end if;
if p_action='settings' then update public.orbita_settings set business_name=left(p->>'business_name',100),business_context=left(p->>'business_context',4000),hot_threshold=(p->>'hot_threshold')::int,warm_threshold=(p->>'warm_threshold')::int,sla_minutes=(p->>'sla_minutes')::int;return jsonb_build_object('ok',true);end if;
if p_action='slot' then insert into public.orbita_slots(resource,starts_at,ends_at,is_demo) values(case when coalesce((p->>'is_demo')::boolean,false) then 'Simulador (fictício)' else coalesce(nullif(p->>'resource',''),'Consultor') end,(p->>'starts_at')::timestamptz,(p->>'ends_at')::timestamptz,coalesce((p->>'is_demo')::boolean,false)) returning id into v_id;return jsonb_build_object('id',v_id);end if;
if p_action='close_slot' then update public.orbita_slots set enabled=false where id=(p->>'id')::uuid and not exists(select 1 from public.orbita_bookings where slot_id=(p->>'id')::uuid and status='confirmed');return jsonb_build_object('ok',true);end if;
if p_action='cancel_booking' then update public.orbita_bookings set status='cancelled' where id=(p->>'id')::uuid returning phone into uid;update public.orbita_leads set stage='qualified' where phone=uid and stage='meeting';return jsonb_build_object('ok',true);end if;
if p_action='create_lead' then insert into public.orbita_leads(phone,name,company,channel,assigned_to) values(p->>'phone',nullif(p->>'name',''),nullif(p->>'company',''),'manual',auth.uid()); return jsonb_build_object('ok',true);end if;
select * into l from public.orbita_leads where phone=p->>'phone' for update;
if l.phone is null or not orbita_private.can_lead(l.phone) then raise exception 'Lead indisponível para seu usuário';end if;
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
insert into public.orbita_messages(phone,channel,external_id,event_key,direction,author,body,status,revision,actor_id) values(l.phone,ident.channel,ident.external_id,'human:'||(p->>'request_id'),'out','human',left(p->>'body',4000),'pending',l.revision,auth.uid()) on conflict(event_key) do nothing;
elsif p_action='book' then
perform 1 from public.orbita_slots where id=(p->>'slot_id')::uuid and is_demo=l.is_demo and enabled and starts_at>now() for update;
if not found then raise exception 'Horário indisponível';end if;
insert into public.orbita_bookings(phone,slot_id) values(l.phone,(p->>'slot_id')::uuid); update public.orbita_leads set stage='meeting',updated_at=now() where phone=l.phone;
else raise exception 'Unknown action';end if;
insert into public.orbita_events(phone,kind,detail,actor) values(l.phone,'operator_'||p_action,p,uid);
return jsonb_build_object('ok',true);end $function$
;

revoke all on function orbita_private.operator(text,jsonb) from public,anon;
grant execute on function orbita_private.operator(text,jsonb) to authenticated;
create or replace function public.orbita_operator(p_action text,p jsonb) returns jsonb language sql security invoker set search_path='' as $$select orbita_private.operator(p_action,p)$$;

create function orbita_private.simulator_enqueue(p_phone text,p_text text,p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare existing public.orbita_simulator_requests;l public.orbita_leads;begin
if not orbita_private.is_member() then raise exception 'Acesso restrito';end if;
if p_phone !~ '^\+[1-9][0-9]{7,14}$' or nullif(trim(p_text),'') is null or length(p_text)>4000 then raise exception 'Informe telefone com código do país e mensagem de até 4000 caracteres';end if;
perform pg_advisory_xact_lock(hashtextextended(p_phone,0));
select * into existing from public.orbita_simulator_requests where id=p_id;
if found then
if existing.created_by<>auth.uid() or existing.phone<>p_phone or existing.body<>trim(p_text) then raise exception 'Solicitação inválida';end if;
return jsonb_build_object('id',p_id,'status',existing.status);end if;
select * into l from public.orbita_leads where phone=p_phone for update;
if found and (not l.is_demo or l.channel<>'demo' or not orbita_private.can_lead(p_phone)) then raise exception 'Número já pertence a um contato real ou a outro funcionário. Use outro número de teste.';end if;
update public.orbita_simulator_requests set status='failed',error='Execução expirou. Verifique o n8n antes de tentar novamente.',processed_at=now() where phone=p_phone and status in ('pending','processing') and created_at<now()-interval '3 minutes';
if exists(select 1 from public.orbita_simulator_requests where phone=p_phone and status in ('pending','processing')) then raise exception 'Aguarde a resposta anterior';end if;
if (select count(*) from public.orbita_simulator_requests where created_by=auth.uid() and created_at>now()-interval '1 minute')>=12 then raise exception 'Limite de teste: aguarde um minuto';end if;
insert into public.orbita_leads(phone,channel,is_demo,assigned_to) values(p_phone,'demo',true,auth.uid()) on conflict do nothing;
insert into public.orbita_slots(resource,starts_at,ends_at,is_demo)
select 'Simulador (fictício)',d,d+interval '30 minutes',true from(select (date_trunc('day',now() at time zone 'America/Sao_Paulo')+interval '1 day 10 hours'+n*interval '1 hour') at time zone 'America/Sao_Paulo' d from generate_series(0,2)n)s on conflict do nothing;
insert into public.orbita_simulator_requests(id,phone,body,created_by) values(p_id,p_phone,trim(p_text),auth.uid());
return jsonb_build_object('id',p_id,'status','pending');end$$;
revoke all on function orbita_private.simulator_enqueue(text,text,uuid) from public,anon;grant execute on function orbita_private.simulator_enqueue(text,text,uuid) to authenticated;
create or replace function public.orbita_simulator_enqueue(p_phone text,p_text text,p_id uuid) returns jsonb language sql security invoker set search_path='' as $$select orbita_private.simulator_enqueue(p_phone,p_text,p_id)$$;
create function public.orbita_simulator_process(p_id uuid) returns setof jsonb language plpgsql security invoker set search_path='' as $$
declare req public.orbita_simulator_requests; result jsonb;begin
update public.orbita_simulator_requests set status='failed',error='Execução sem resposta após 3 minutos. Confira o n8n; envie novamente apenas após verificar.',processed_at=now() where status='processing' and processed_at<now()-interval '3 minutes';
select * into req from public.orbita_simulator_requests where id=p_id and status='pending' order by created_at for update skip locked limit 1;
if req.id is null then return;end if;
begin
if exists(select 1 from public.orbita_leads where phone=req.phone and (not is_demo or channel<>'demo')) then raise exception 'Contato real protegido';end if;
result:=public.orbita_ingest(jsonb_build_object('channel','demo','phone',req.phone,'external_id','sim:'||req.phone,'event_key','sim:'||req.id,'text',req.body));
update public.orbita_simulator_requests set status=case when result->>'action'='qualify' then 'processing' else 'done' end, revision=(result->>'revision')::int,processed_at=now() where id=req.id;
return next result;
exception when others then update public.orbita_simulator_requests set status='failed',error=left(sqlerrm,300),processed_at=now() where id=req.id;end;
end $$;
revoke all on function public.orbita_simulator_process(uuid) from public,anon,authenticated;
grant execute on function public.orbita_simulator_process(uuid) to service_role;


create function orbita_private.assign_new_lead() returns trigger language plpgsql security definer set search_path='' as $$begin
if new.assigned_to is null then select user_id into new.assigned_to from public.orbita_members where enabled and role='admin' and user_id is not null order by created_at limit 1;end if;return new;end$$;
revoke all on function orbita_private.assign_new_lead() from public,anon,authenticated;
create trigger orbita_assign_new_lead before insert on public.orbita_leads for each row execute function orbita_private.assign_new_lead();
alter publication supabase_realtime add table public.orbita_members,public.orbita_events;
