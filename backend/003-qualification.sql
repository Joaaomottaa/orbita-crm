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
select coalesce(jsonb_agg(z),'[]') into offered from(select s.id,s.starts_at,s.resource from public.orbita_slots s where s.enabled and s.starts_at>now()+interval '2 hours' and s.starts_at<now()+interval '14 days' and not exists(select 1 from public.orbita_bookings b where b.slot_id=s.id and b.status='confirmed') order by s.starts_at limit 3)z;
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

