CREATE OR REPLACE FUNCTION public.orbita_ingest(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare ph text; l public.orbita_leads; ch text:=p->>'channel'; ext text:=p->>'external_id'; txt text:=left(coalesce(p->>'text',''),6000); mid uuid; sl uuid; bk uuid; reply text; s public.orbita_slots; begin
if ch not in ('telegram','whatsapp','demo') or nullif(ext,'') is null or nullif(p->>'event_key','') is null then raise exception 'Invalid envelope'; end if;
ph:=nullif(p->>'phone','');
if ph is null then select phone into ph from public.orbita_identities where channel=ch and external_id=ext; end if;
if ph is null then return jsonb_build_object('action','request_contact','external_id',ext,'channel',ch); end if;
if ph !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'Phone must be E.164'; end if;
if exists(select 1 from public.orbita_identities where channel=ch and external_id=ext and phone<>ph) then raise exception 'Identity conflict: operator review required'; end if;
if exists(select 1 from public.orbita_leads where phone=ph and is_demo<>(ch='demo')) then raise exception 'Número reservado em outro ambiente. Não misture simulação e contato real.';end if;
insert into public.orbita_leads(phone,channel,name,is_demo) values(ph,ch,nullif(left(p->>'name',120),''),ch='demo') on conflict(phone) do nothing;
select * into l from public.orbita_leads where phone=ph for update;
insert into public.orbita_identities values(ch,ext,ph) on conflict do nothing;
if txt='' then txt:='[Contato compartilhado]'; end if;
insert into public.orbita_messages(phone,channel,external_id,event_key,direction,author,body) values(ph,ch,ext,p->>'event_key','in','lead',txt) on conflict(event_key) do nothing returning id into mid;
if mid is null then return jsonb_build_object('action','duplicate'); end if;
update public.orbita_leads set channel=ch,revision=revision+1,last_inbound_at=now(),updated_at=now(),name=coalesce(name,nullif(left(p->>'name',120),'')) where phone=ph returning * into l;
update public.orbita_messages set status='cancelled',error='Resposta substituída por nova mensagem' where phone=ph and author='bot' and status='pending';
if lower(trim(txt)) ~ '^(parar|sair|cancelar mensagens|stop|não quero receber mensagens)[.! ]*$' then
update public.orbita_leads set mode='optout' where phone=ph;
update public.orbita_messages set status='cancelled' where phone=ph and direction='out' and status in ('pending','sending'); reply:='Tudo bem. O atendimento automático foi encerrado.';
elsif lower(txt) ~ '(falar|conversar).*(humano|pessoa|vendedor|atendente)' then
update public.orbita_leads set mode='human',handoff_requested_at=now() where phone=ph;
insert into public.orbita_tasks(phone,kind,title,due_at) values(ph,'handoff','Lead pediu atendimento humano',now()+interval '15 minutes') on conflict do nothing;
reply:='Vou encaminhar sua conversa para uma pessoa da equipe. Ela receberá o contexto por aqui.';
elsif l.mode<>'bot' then return jsonb_build_object('action','stored','phone',ph,'mode',l.mode);
elsif trim(txt) ~ '^[1-3]$' and jsonb_array_length(l.offered_slots)>0 then
sl:=(l.offered_slots->(trim(txt)::int-1)->>'id')::uuid;
select * into s from public.orbita_slots where id=sl and is_demo=l.is_demo and enabled and starts_at>now()+interval '1 hour' for update;
if s.id is not null and not exists(select 1 from public.orbita_bookings where (slot_id=sl or phone=ph) and status='confirmed') then
insert into public.orbita_bookings(phone,slot_id) values(ph,sl) returning id into bk;
update public.orbita_leads set stage='meeting',offered_slots='[]',mode=case when temperature='hot' then 'human' else mode end where phone=ph;
reply:='Reunião confirmada para '||to_char(s.starts_at at time zone 'America/Sao_Paulo','DD/MM às HH24:MI')||' (Brasília). A equipe continuará com você por aqui.';
insert into public.orbita_events(phone,kind,detail) values(ph,'booking_confirmed',jsonb_build_object('booking',bk));
else reply:='Esse horário não está mais disponível ou você já tem uma reunião marcada. Vou chamar a equipe para ajustar sua agenda.'; update public.orbita_leads set mode='human',handoff_requested_at=now() where phone=ph; insert into public.orbita_tasks(phone,kind,title) values(ph,'handoff','Ajustar agendamento') on conflict do nothing; end if;
end if;
if reply is not null then insert into public.orbita_messages(phone,channel,external_id,direction,author,body,status,revision) values(ph,ch,ext,'out','system',reply,'pending',l.revision); return jsonb_build_object('action','stored','phone',ph); end if;
return jsonb_build_object('action','qualify','phone',ph,'revision',l.revision,'lead',to_jsonb(l),'message',txt,'context',coalesce((select jsonb_agg(x) from(select author,body from public.orbita_messages where phone=ph and (direction='in' or status='sent') order by created_at desc limit 16)x),'[]'),'settings',(select to_jsonb(o) from public.orbita_settings o));
end $function$
;
CREATE OR REPLACE FUNCTION public.orbita_fail(p_phone text, p_revision integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare l public.orbita_leads; begin
select * into l from public.orbita_leads where phone=p_phone for update;
if l.phone is null or l.mode<>'bot' or l.revision<>p_revision then return jsonb_build_object('ok',false,'reason','stale_or_human');end if;
update public.orbita_leads set mode='human',revision=revision+1,handoff_requested_at=now() where phone=p_phone;
update public.orbita_messages set status='cancelled' where phone=p_phone and author='bot' and status='pending';
insert into public.orbita_tasks(phone,kind,title) values(p_phone,'ai_failure','IA indisponível: assumir conversa') on conflict do nothing;
update public.orbita_simulator_requests set status='failed',error='A IA não concluiu o atendimento. A conversa foi encaminhada para um vendedor.',processed_at=now() where phone=p_phone and revision=p_revision and status='processing';
return jsonb_build_object('ok',true);end $function$
;
revoke insert,update,delete on public.orbita_members from authenticated;
create policy service_dispatch on orbita_private.dispatch_config for all to service_role using(true) with check(true);


-- Preserve message order inside the same transaction.
alter table public.orbita_messages alter column created_at set default clock_timestamp();
