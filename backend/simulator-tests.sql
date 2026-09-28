begin;
create temporary table sim_results(test text,passed boolean);
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-000000000001","email":"intruso@example.invalid","role":"authenticated"}',true);
do $$ begin
begin perform public.orbita_simulator_enqueue('+9991234567890','Olá','00000000-0000-0000-0000-000000000101');raise exception 'Intruso aceito';
exception when others then if sqlerrm='Intruso aceito' then raise;end if;end;
assert not exists(select 1 from public.orbita_simulator_requests);
end $$;
select set_config('request.jwt.claims','{"sub":"d3702db6-18ab-410a-9a1c-41459b31db67","email":"l2mortal01@gmail.com","role":"authenticated"}',true);
do $$ begin
begin perform public.orbita_simulator_enqueue('11999988771','Olá','00000000-0000-0000-0000-000000000101');raise exception 'Telefone sem formato aceito';
exception when others then if sqlerrm='Telefone sem formato aceito' then raise;end if;end;
perform public.orbita_simulator_enqueue('+9991234567890','Meu nome é João Paulo. Quero automatizar o atendimento da empresa este mês.','00000000-0000-0000-0000-000000000101');
perform public.orbita_simulator_enqueue('+9991234567890','Meu nome é João Paulo. Quero automatizar o atendimento da empresa este mês.','00000000-0000-0000-0000-000000000101');
assert (select count(*)=1 from public.orbita_simulator_requests where phone='+9991234567890');
begin perform public.orbita_simulator_enqueue('+9991234567890','Outra mensagem','00000000-0000-0000-0000-000000000102');raise exception 'Concorrência aceita';
exception when others then if sqlerrm='Concorrência aceita' then raise;end if;end;
end $$;
reset role;
insert into sim_results values('RLS, telefone fictício, deduplicação e uma mensagem pendente',true);
do $$ declare r jsonb; rev int; sl uuid; begin
select x into r from public.orbita_simulator_next() x;
assert r->>'action'='qualify';rev:=(r->>'revision')::int;
assert (select is_demo and channel='demo' from public.orbita_leads where phone='+9991234567890');
assert (select status='processing' from public.orbita_simulator_requests where phone='+9991234567890');
insert into public.orbita_slots(resource,starts_at,ends_at) values('QA real',now()+interval '4 days',now()+interval '4 days 30 minutes') returning id into sl;
r:=public.orbita_commit(jsonb_build_object('phone','+9991234567890','revision',rev,'extracted','{"name":"João Paulo","fit":true,"need":"Automatizar atendimento da empresa","urgency":"30_days"}'::jsonb,'reply','Vamos agendar?'));
assert r->>'temperature'='hot';
assert (select status='done' from public.orbita_simulator_requests where phone='+9991234567890');
assert exists(select 1 from public.orbita_messages where phone='+9991234567890' and author='bot' and status='sent' and provider_id like 'simulated:%');
assert not exists(select 1 from public.orbita_messages where phone='+9991234567890' and channel='telegram');
assert not exists(select 1 from public.orbita_leads l cross join lateral jsonb_array_elements(l.offered_slots) o join public.orbita_slots s on s.id=(o->>'id')::uuid where l.phone='+9991234567890' and not s.is_demo);
insert into sim_results values('Fila processada, lead quente e resposta simulada sem envio externo',true);
insert into sim_results values('Agenda oferecida contém apenas horários fictícios',true);
end $$;
set local role authenticated;
do $$ begin
begin perform public.orbita_operator('book',jsonb_build_object('phone','+9991234567890','slot_id',(select id from public.orbita_slots where resource='QA real')));raise exception 'Reserva real aceita';
exception when others then if sqlerrm='Reserva real aceita' then raise;end if;end;
perform public.orbita_operator('mode','{"phone":"+9991234567890","mode":"human"}');
perform public.orbita_operator('send','{"phone":"+9991234567890","body":"Olá, sou o vendedor de teste","request_id":"qa-human-sim"}');
assert exists(select 1 from public.orbita_messages where phone='+9991234567890' and author='human' and status='sent');
end $$;
reset role;
insert into sim_results values('Reserva real bloqueada e resposta humana simulada autorizada',true);
select jsonb_agg(to_jsonb(t)) as tests from sim_results t;
rollback;

