-- Event-driven Telegram outbox. No scheduler / no empty n8n polling.
create extension if not exists pg_net with schema extensions;
alter table orbita_private.dispatch_config add column if not exists delivery_url text;
update orbita_private.dispatch_config set delivery_url='https://autoconfi.app.n8n.cloud/webhook/orbita-entrega-telegram-v4';

create table orbita_private.delivery_dispatches (
 message_id uuid primary key references public.orbita_messages(id) on delete cascade,
 request_id bigint, dispatched_at timestamptz not null default clock_timestamp(), attempts int not null default 1
);
alter table orbita_private.delivery_dispatches enable row level security;
revoke all on orbita_private.delivery_dispatches from public,anon,authenticated;
grant all on orbita_private.delivery_dispatches to service_role;
create policy service_dispatches on orbita_private.delivery_dispatches to service_role using(true) with check(true);

create function orbita_private.dispatch_delivery(p_id uuid) returns boolean
language plpgsql security definer set search_path='' as $$
declare cfg orbita_private.dispatch_config; rid bigint;
begin
 if not exists(select 1 from public.orbita_messages where id=p_id and channel='telegram' and direction='out' and status='pending') then return false;end if;
 select * into strict cfg from orbita_private.dispatch_config;
 if cfg.delivery_url is null then raise exception 'Entrega Telegram não configurada';end if;
 select net.http_post(url:=cfg.delivery_url,body:=jsonb_build_object('id',p_id),headers:=jsonb_build_object('Content-Type','application/json','x-orbita-key',cfg.api_key),timeout_milliseconds:=15000) into rid;
 insert into orbita_private.delivery_dispatches(message_id,request_id) values(p_id,rid)
 on conflict(message_id) do update set request_id=excluded.request_id,dispatched_at=clock_timestamp(),attempts=orbita_private.delivery_dispatches.attempts+1;
 return true;
end$$;
revoke all on function orbita_private.dispatch_delivery(uuid) from public,anon,authenticated;
grant execute on function orbita_private.dispatch_delivery(uuid) to service_role;

create function orbita_private.on_outbound_message() returns trigger language plpgsql security definer set search_path='' as $$
begin perform orbita_private.dispatch_delivery(new.id);return new;end$$;
revoke all on function orbita_private.on_outbound_message() from public,anon,authenticated;
create trigger orbita_dispatch_outbound after insert on public.orbita_messages for each row
when(new.channel='telegram' and new.direction='out' and new.status='pending') execute function orbita_private.on_outbound_message();

create function public.orbita_claim_message(p_id uuid) returns setof public.orbita_messages
language plpgsql security invoker set search_path='' as $$
declare m public.orbita_messages; l public.orbita_leads;
begin
 select * into m from public.orbita_messages where id=p_id and channel='telegram' and direction='out' and status='pending' for update skip locked;
 if not found then return;end if;
 select * into l from public.orbita_leads where phone=m.phone;
 if (m.author='bot' and (l.mode<>'bot' or m.revision<>l.revision)) or (l.mode='optout' and m.author<>'system') then
 update public.orbita_messages set status='cancelled',error='Envio cancelado após intervenção' where id=m.id;return;end if;
 return query update public.orbita_messages set status='sending',claimed_at=clock_timestamp() where id=m.id returning *;
end$$;
revoke all on function public.orbita_claim_message(uuid) from public,anon,authenticated;
grant execute on function public.orbita_claim_message(uuid) to service_role;

-- Explicit retry only while pending: never retry a possibly delivered message blindly.
create function orbita_private.retry_delivery(p_id uuid) returns boolean
language plpgsql security definer set search_path='' as $$
declare m public.orbita_messages;
begin
 select * into m from public.orbita_messages where id=p_id for update;
 if not found or not orbita_private.can_lead(m.phone) then raise exception 'Acesso negado';end if;
 if m.status<>'pending' or m.channel<>'telegram' then raise exception 'Só é possível retomar envio ainda não iniciado';end if;
 if exists(select 1 from orbita_private.delivery_dispatches where message_id=p_id and dispatched_at>now()-interval '30 seconds') then raise exception 'Aguarde 30 segundos antes de tentar novamente';end if;
 return orbita_private.dispatch_delivery(p_id);
end$$;
revoke all on function orbita_private.retry_delivery(uuid) from public,anon;
grant execute on function orbita_private.retry_delivery(uuid) to authenticated;
create function public.orbita_retry_delivery(p_id uuid) returns boolean language sql security invoker set search_path='' as $$select orbita_private.retry_delivery(p_id)$$;
revoke all on function public.orbita_retry_delivery(uuid) from public,anon;
grant execute on function public.orbita_retry_delivery(uuid) to authenticated;
