-- Fictitious, deterministic demonstration data. No external messages are queued.
do $$declare u record;i int;lphone text;st text;tm text;sc int;startt timestamptz;sl uuid;names text[]:=array['Marina Costa','Rafael Lima','Beatriz Alves','Lucas Oliveira','Camila Rocha','Pedro Martins','Juliana Ribeiro','André Nunes','Patrícia Dias','Felipe Melo','Renata Souza','Diego Lopes']; companies text[]:=array['Lumina Contabilidade','Estúdio Forma','Norte Educação','Ateliê Lume','Vértice Serviços','Nova Gestão','Ponto Consultoria','Atlas Logística','Clínica Horizonte','Inova Cursos','Foco Imobiliária','Viva Tecnologia'];begin
for u in select *,row_number() over(order by email) num from public.orbita_members where email in ('ana@orbita.example','bruno@orbita.example','carla@orbita.example') loop
for i in 1..12 loop
lphone:='+999'||lpad((u.num*100+i)::text,10,'0');
st:=(array['new','qualifying','qualifying','qualified','qualified','meeting','won','lost','meeting','qualifying','won','new'])[1+((i+u.num::int-2)%12)];
sc:=case st when 'new' then 0 when 'qualifying' then 60 when 'lost' then 25 when 'won' then 100 else 85 end;
tm:=case when sc>=70 then 'hot' when sc>=40 then 'warm' when sc=0 then 'unknown' else 'cold' end;
startt:=now()-make_interval(days=>i+u.num::int,hours=>i);
insert into public.orbita_leads(phone,name,company,channel,stage,mode,qualification,score,temperature,reasons,summary,revision,is_demo,assigned_to,created_at,updated_at,handoff_requested_at,human_owner)
values(lphone,names[i],companies[i]||' · '||split_part(u.name,' ',1),'demo',st,case when st in ('meeting','won') then 'human' else 'bot' end,jsonb_build_object('fit',sc>=60,'need','Automatizar atendimento e reduzir retrabalho','urgency',case when sc>=85 then '30_days' else 'unknown' end),sc,tm,
case when sc>=85 then '[{"label":"Aderência B2B","points":35},{"label":"Necessidade declarada","points":25},{"label":"Prazo de até 30 dias","points":25}]'::jsonb else '[]'::jsonb end,
'Dado fictício para apresentação. Automatizar atendimento, registrar oportunidades e reduzir tarefas manuais.',2,true,u.user_id,startt,startt+interval '15 minutes',case when sc>=85 then startt+interval '2 minutes' end,case when st in ('meeting','won') then u.email end)
on conflict(phone) do nothing;
insert into public.orbita_identities(channel,external_id,phone) values('demo','sim:'||lphone,lphone) on conflict do nothing;
insert into public.orbita_messages(phone,channel,event_key,direction,author,body,status,created_at)
values(lphone,'demo','seed-in:'||lphone,'in','lead','Olá, sou '||names[i]||'. Gostaria de automatizar o atendimento da empresa.','received',startt),
(lphone,'demo','seed-bot:'||lphone,'out','bot','Olá! Qual etapa do atendimento mais ocupa o tempo da equipe hoje?','sent',startt+interval '20 seconds') on conflict(event_key) do nothing;
if i<=(case u.num when 1 then 9 when 2 then 6 else 4 end) then
insert into public.orbita_messages(phone,channel,event_key,direction,author,body,status,actor_id,created_at)
values(lphone,'demo','seed-human:'||lphone,'out','human','Olá! Sou '||u.name||' e vou acompanhar seu diagnóstico.','sent',u.user_id,startt+make_interval(mins=>5+u.num::int*3)) on conflict(event_key) do nothing;end if;
if st='qualified' then insert into public.orbita_tasks(phone,kind,title,due_at,created_at) values(lphone,'handoff','Lead quente: assumir conversa',now()+make_interval(mins=>case when i%2=0 then -20 else 30 end),startt) on conflict do nothing;end if;
if st='meeting' then
insert into public.orbita_slots(resource,starts_at,ends_at,is_demo) values('Simulação · '||u.name,date_trunc('day',now())+make_interval(days=>2+u.num::int,hours=>10+i),date_trunc('day',now())+make_interval(days=>2+u.num::int,hours=>10+i,mins=>30),true) returning id into sl;
insert into public.orbita_bookings(phone,slot_id,created_at) values(lphone,sl,startt+interval '20 minutes') on conflict do nothing;end if;
end loop;end loop;end$$;


