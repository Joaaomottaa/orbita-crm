-- Align fictional seed evidence with its visible score; does not affect live/simulator tests.
update public.orbita_leads l set
qualification=jsonb_build_object('fit',score>=60,'need',case when score>0 then 'Automatizar atendimento e reduzir retrabalho' else null end,'urgency',case when score>=85 then '30_days' else 'unknown' end,'decision_role',case when score=100 then 'decision_maker' else 'unknown' end),
reasons=(case when score>=60 then '[{"label":"Aderência B2B","points":35}]'::jsonb else '[]'::jsonb end)
 ||(case when score>0 then '[{"label":"Necessidade declarada","points":25}]'::jsonb else '[]'::jsonb end)
 ||(case when score>=85 then '[{"label":"Prazo de até 30 dias","points":25}]'::jsonb else '[]'::jsonb end)
 ||(case when score=100 then '[{"label":"Decisão de compra","points":15}]'::jsonb else '[]'::jsonb end)
where is_demo and exists(select 1 from public.orbita_messages m where m.phone=l.phone and m.event_key='seed-in:'||l.phone);
