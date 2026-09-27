create table public.orbita_simulator_requests (
id uuid primary key, phone text not null check(phone ~ '^\+999[0-9]{10}$'),
body text not null check(length(body) between 1 and 4000),
created_by uuid not null default auth.uid(), created_at timestamptz not null default now(),
status text not null default 'pending' check(status in ('pending','processing','done','failed')),
revision int, processed_at timestamptz, error text);
create unique index orbita_simulator_one_pending on public.orbita_simulator_requests(phone) where status in ('pending','processing');
create index orbita_simulator_created on public.orbita_simulator_requests(created_at);
alter table public.orbita_simulator_requests enable row level security;
revoke all on public.orbita_simulator_requests from public,anon,authenticated;
grant select,insert on public.orbita_simulator_requests to authenticated;
grant all on public.orbita_simulator_requests to service_role;
create policy simulator_read on public.orbita_simulator_requests for select to authenticated using((select public.orbita_is_operator()));
create policy simulator_insert on public.orbita_simulator_requests for insert to authenticated with check((select public.orbita_is_operator()) and created_by=(select auth.uid()) and status='pending' and revision is null and processed_at is null and error is null);
create function public.orbita_simulator_enqueue(p_phone text,p_text text,p_id uuid) returns jsonb language plpgsql security invoker set search_path='' as $$
declare existing public.orbita_simulator_requests;begin
if not public.orbita_is_operator() then raise exception 'Acesso restrito ao operador';end if;
select * into existing from public.orbita_simulator_requests where id=p_id;
if found then
if existing.phone<>p_phone or existing.body<>trim(p_text) then raise exception 'ID reutilizado com conteúdo diferente';end if;
return jsonb_build_object('id',p_id,'status',existing.status);end if;
if p_phone !~ '^\+999[0-9]{10}$' or nullif(trim(p_text),'') is null then raise exception 'Use a identidade fictícia gerada pelo simulador';end if;
if exists(select 1 from public.orbita_leads where phone=p_phone and (not is_demo or channel<>'demo')) then raise exception 'Simulador não pode alterar um contato real';end if;
if exists(select 1 from public.orbita_simulator_requests where phone=p_phone and status in ('pending','processing')) then raise exception 'Aguarde a resposta anterior do n8n';end if;
insert into public.orbita_simulator_requests(id,phone,body) values(p_id,p_phone,trim(p_text));
return jsonb_build_object('id',p_id,'status','pending');
end $$;
revoke all on function public.orbita_simulator_enqueue(text,text,uuid) from public,anon;
grant execute on function public.orbita_simulator_enqueue(text,text,uuid) to authenticated;

create function public.orbita_simulator_next() returns setof jsonb language plpgsql security invoker set search_path='' as $$
declare req public.orbita_simulator_requests; result jsonb;begin
update public.orbita_simulator_requests set status='failed',error='Execução sem resposta após 3 minutos. Confira o n8n; envie novamente apenas após verificar.',processed_at=now() where status='processing' and processed_at<now()-interval '3 minutes';
select * into req from public.orbita_simulator_requests where status='pending' order by created_at for update skip locked limit 1;
if req.id is null then return;end if;
begin
if exists(select 1 from public.orbita_leads where phone=req.phone and (not is_demo or channel<>'demo')) then raise exception 'Contato real protegido';end if;
result:=public.orbita_ingest(jsonb_build_object('channel','demo','phone',req.phone,'external_id','sim:'||req.phone,'event_key','sim:'||req.id,'text',req.body));
update public.orbita_simulator_requests set status=case when result->>'action'='qualify' then 'processing' else 'done' end, revision=(result->>'revision')::int,processed_at=now() where id=req.id;
return next result;
exception when others then update public.orbita_simulator_requests set status='failed',error=left(sqlerrm,300),processed_at=now() where id=req.id;end;
end $$;
revoke all on function public.orbita_simulator_next() from public,anon,authenticated;
grant execute on function public.orbita_simulator_next() to service_role;

create function public.orbita_simulator_delivery() returns trigger language plpgsql security invoker set search_path='' as $$
begin
if new.channel='demo' and new.direction='out' and new.status='pending' then
if not exists(select 1 from public.orbita_leads where phone=new.phone and is_demo and channel='demo') then raise exception 'Entrega simulada exige lead fictício';end if;
new.status:='sent';new.provider_id:='simulated:'||new.id;
end if;
return new;end $$;
revoke all on function public.orbita_simulator_delivery() from public,anon,authenticated;
create trigger orbita_simulator_delivery before insert on public.orbita_messages for each row execute function public.orbita_simulator_delivery();

create function public.orbita_simulator_completion() returns trigger language plpgsql security invoker set search_path='' as $$
begin
if new.channel='demo' and new.direction='out' and new.author='bot' and new.status='sent' then
update public.orbita_simulator_requests set status='done',processed_at=now() where phone=new.phone and revision=new.revision and status='processing';
end if;return new;end $$;
revoke all on function public.orbita_simulator_completion() from public,anon,authenticated;
create trigger orbita_simulator_completion after insert on public.orbita_messages for each row execute function public.orbita_simulator_completion();
alter publication supabase_realtime add table public.orbita_simulator_requests;

