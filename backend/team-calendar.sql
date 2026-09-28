CREATE OR REPLACE FUNCTION orbita_private.operator(p_action text, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare l public.orbita_leads; ident public.orbita_identities; uid text:=auth.jwt()->>'email'; v_id uuid; begin
if not public.orbita_is_operator() then raise exception 'Access denied';end if;
if p_action in ('settings','slot','edit_slot','close_slot','cancel_booking','assign','member') and not orbita_private.is_admin() then raise exception 'Somente administradores';end if;
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
if p_action='edit_slot' then
if (p->>'starts_at')::timestamptz<=now() then raise exception 'Escolha um horário futuro';end if;
update public.orbita_slots set starts_at=(p->>'starts_at')::timestamptz,ends_at=(p->>'ends_at')::timestamptz where id=(p->>'id')::uuid;
insert into public.orbita_events(kind,detail,actor) values('slot_edited',p,uid);
return jsonb_build_object('ok',true);end if;
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


create function orbita_private.slot_busy(p_id uuid) returns boolean language sql stable security definer set search_path='' as $$select orbita_private.is_member() and exists(select 1 from public.orbita_bookings where slot_id=p_id and status='confirmed')$$;
revoke all on function orbita_private.slot_busy(uuid) from public,anon;
grant execute on function orbita_private.slot_busy(uuid) to authenticated;
create function public.orbita_slots_view() returns setof jsonb language sql stable security invoker set search_path='' as $$select to_jsonb(s)||jsonb_build_object('reserved',orbita_private.slot_busy(s.id)) from public.orbita_slots s order by starts_at limit 1000$$;
revoke all on function public.orbita_slots_view() from public,anon;grant execute on function public.orbita_slots_view() to authenticated;
