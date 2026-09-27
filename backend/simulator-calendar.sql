alter table public.orbita_slots add column is_demo boolean not null default false;
CREATE OR REPLACE FUNCTION public.orbita_commit(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
temp:=case when total>=cfg.hot_threshold and q->>'fit'='true' and length(coalesce(q->>'need',''))>5 then 'hot' when total>=cfg.warm_threshold then 'warm' when total=0 and q->>'fit' is distinct from 'false' then 'unknown' else 'cold' end;
select * into ident from public.orbita_identities where phone=l.phone and channel=l.channel limit 1;
if coalesce((p->>'offer_meeting')::boolean,false) or temp='hot' then
select coalesce(jsonb_agg(z),'[]') into offered from(select s.id,s.starts_at,s.resource from public.orbita_slots s where s.is_demo=l.is_demo and s.enabled and s.starts_at>now()+interval '2 hours' and s.starts_at<now()+interval '14 days' and not exists(select 1 from public.orbita_bookings b where b.slot_id=s.id and b.status='confirmed') order by s.starts_at limit 3)z;
if jsonb_array_length(offered)>0 and not exists(select 1 from public.orbita_bookings where phone=l.phone and status='confirmed') then
reply:=case when temp='hot' then 'Seu cenário tem aderência ao que fazemos. Já sinalizei a equipe comercial. Se quiser, podemos reservar um diagnóstico de 30 minutos.' else 'Podemos conversar em um diagnóstico de 30 minutos.' end||E'\nEscolha uma opção (horário de Brasília):';
for i in 0..jsonb_array_length(offered)-1 loop reply:=reply||E'\n'||(i+1)::text||' — '||to_char((offered->i->>'starts_at')::timestamptz at time zone 'America/Sao_Paulo','DD/MM às HH24:MI');end loop;
reply:=reply||E'\nResponda somente com o número. A reserva será confirmada na próxima mensagem.';
else offered:='[]';
insert into public.orbita_tasks(phone,kind,title,due_at) values(l.phone,'handoff','Agendamento precisa de apoio humano',now()+make_interval(mins=>cfg.sla_minutes)) on conflict do nothing;
reply:='Já sinalizei a equipe comercial sobre seu interesse. No momento não tenho horários livres para oferecer; uma pessoa continuará o agendamento com você.'; end if;
end if;
update public.orbita_leads set name=coalesce(nullif(left(a->>'name',120),''),name),company=coalesce(nullif(left(a->>'company',160),''),company),email=coalesce(nullif(left(a->>'email',180),''),email),qualification=q,score=total,temperature=temp,reasons=r,summary=left(p->>'summary',1000),stage=case when stage in ('meeting','won','lost') then stage when temp='hot' then 'qualified' else 'qualifying' end,offered_slots=coalesce(offered,offered_slots),handoff_requested_at=case when temp='hot' then coalesce(handoff_requested_at,now()) else handoff_requested_at end,updated_at=now() where phone=l.phone;
if temp='hot' then insert into public.orbita_tasks(phone,kind,title,due_at) values(l.phone,'handoff','Lead quente: assumir conversa',now()+make_interval(mins=>cfg.sla_minutes)) on conflict do nothing;end if;
insert into public.orbita_messages(phone,channel,external_id,event_key,direction,author,body,status,revision) values(l.phone,ident.channel,ident.external_id,'reply:'||l.phone||':'||l.revision,'out','bot',reply,'pending',l.revision) on conflict(event_key) do nothing;
insert into public.orbita_events(phone,kind,detail) values(l.phone,'qualification_updated',jsonb_build_object('score',total,'reasons',r,'rule_version','1.0','evidence',p->'evidence'));
return jsonb_build_object('saved',true,'score',total,'temperature',temp);
end $function$
;
CREATE OR REPLACE FUNCTION public.orbita_operator(p_action text, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare l public.orbita_leads; ident public.orbita_identities; uid text:=auth.jwt()->>'email'; v_id uuid; begin
if not public.orbita_is_operator() then raise exception 'Access denied';end if;
if p_action='settings' then update public.orbita_settings set business_name=left(p->>'business_name',100),business_context=left(p->>'business_context',4000),hot_threshold=(p->>'hot_threshold')::int,warm_threshold=(p->>'warm_threshold')::int,sla_minutes=(p->>'sla_minutes')::int;return jsonb_build_object('ok',true);end if;
if p_action='slot' then insert into public.orbita_slots(resource,starts_at,ends_at,is_demo) values(case when coalesce((p->>'is_demo')::boolean,false) then 'Simulador (fictício)' else coalesce(nullif(p->>'resource',''),'Consultor') end,(p->>'starts_at')::timestamptz,(p->>'ends_at')::timestamptz,coalesce((p->>'is_demo')::boolean,false)) returning id into v_id;return jsonb_build_object('id',v_id);end if;
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
perform 1 from public.orbita_slots where id=(p->>'slot_id')::uuid and is_demo=l.is_demo and enabled and starts_at>now() for update;
if not found then raise exception 'Horário indisponível';end if;
insert into public.orbita_bookings(phone,slot_id) values(l.phone,(p->>'slot_id')::uuid); update public.orbita_leads set stage='meeting',updated_at=now() where phone=l.phone;
else raise exception 'Unknown action';end if;
insert into public.orbita_events(phone,kind,detail,actor) values(l.phone,'operator_'||p_action,p,uid);
return jsonb_build_object('ok',true);end $function$
;
CREATE OR REPLACE FUNCTION public.orbita_simulator_enqueue(p_phone text, p_text text, p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare existing public.orbita_simulator_requests;begin
if not public.orbita_is_operator() then raise exception 'Acesso restrito ao operador';end if;
select * into existing from public.orbita_simulator_requests where id=p_id;
if found then
if existing.phone<>p_phone or existing.body<>trim(p_text) then raise exception 'ID reutilizado com conteúdo diferente';end if;
return jsonb_build_object('id',p_id,'status',existing.status);end if;
if p_phone !~ '^\+999[0-9]{10}$' or nullif(trim(p_text),'') is null then raise exception 'Use a identidade fictícia gerada pelo simulador';end if;
if exists(select 1 from public.orbita_leads where phone=p_phone and (not is_demo or channel<>'demo')) then raise exception 'Simulador não pode alterar um contato real';end if;
if exists(select 1 from public.orbita_simulator_requests where phone=p_phone and status in ('pending','processing')) then raise exception 'Aguarde a resposta anterior do n8n';end if;
insert into public.orbita_slots(resource,starts_at,ends_at,is_demo)
select 'Simulador (fictício)',d,d+interval '30 minutes',true
from (select (date_trunc('day',now() at time zone 'America/Sao_Paulo')+interval '1 day 10 hours'+n*interval '1 hour') at time zone 'America/Sao_Paulo' as d from generate_series(0,2) n) s
on conflict do nothing;
insert into public.orbita_simulator_requests(id,phone,body) values(p_id,p_phone,trim(p_text));
return jsonb_build_object('id',p_id,'status','pending');
end $function$
;

