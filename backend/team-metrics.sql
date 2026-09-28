create function public.orbita_metrics(p_days int default 30,p_demo text default 'all',p_owner uuid default null) returns jsonb language sql stable security invoker set search_path='' as $$
with ls as(select * from public.orbita_leads where created_at>=now()-make_interval(days=>greatest(1,least(p_days,365))) and (p_owner is null or assigned_to=p_owner) and (p_demo='all' or (p_demo='demo' and is_demo) or (p_demo='real' and not is_demo))),
ms as(select m.* from public.orbita_messages m join ls l on l.phone=m.phone where m.author='human' and m.status='sent'),
staff as(select m.user_id,m.name,m.email,m.role,m.enabled,
(select count(*) from ls where assigned_to=m.user_id) leads,
(select count(*) from ls where assigned_to=m.user_id and stage not in ('won','lost')) open,
(select count(*) from ls where assigned_to=m.user_id and stage='won') won,
(select count(distinct phone) from ms where actor_id=m.user_id) attended,
(select count(*) from ms where actor_id=m.user_id) replies,
(select count(*) from public.orbita_bookings b join ls l on l.phone=b.phone where l.assigned_to=m.user_id and b.status in ('confirmed','completed')) meetings,
(select count(*) from public.orbita_tasks t join ls l on l.phone=t.phone where l.assigned_to=m.user_id and t.status='open' and t.due_at<now()) overdue
from public.orbita_members m where (select public.orbita_is_operator())),
stages as(select stage,count(*) n from ls group by stage),
daily as(select created_at::date as day,count(*) n from ls group by created_at::date)
select jsonb_build_object('staff',coalesce((select jsonb_agg(to_jsonb(s) order by s.attended desc,s.leads desc) from staff s),'[]'),'stages',coalesce((select jsonb_agg(to_jsonb(s)) from stages s),'[]'),'daily',coalesce((select jsonb_agg(to_jsonb(d) order by d.day) from daily d),'[]'),'total',(select count(*) from ls),'demo',(select count(*) from ls where is_demo),'days',p_days)
$$;
revoke all on function public.orbita_metrics(int,text,uuid) from public,anon;grant execute on function public.orbita_metrics(int,text,uuid) to authenticated;

