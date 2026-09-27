// Ensaio local determinístico. O modo conectado usa o modelo no n8n.
export function qualify(q, rules={hot_threshold:70,warm_threshold:40}) {
 const reasons=[];
 if(q.fit===true)reasons.push({label:'Aderência a automação B2B',points:35});
 if((q.need||'').length>5)reasons.push({label:'Necessidade declarada',points:25});
 if(q.urgency==='30_days')reasons.push({label:'Prazo de até 30 dias',points:25});
 if(['decision_maker','involved'].includes(q.decision))reasons.push({label:'Participa da decisão',points:15});
 const score=reasons.reduce((n,r)=>n+r.points,0);
 const temperature=score>=(rules.hot_threshold??70)&&q.fit===true&&(q.need||'').length>5?'hot':score>=(rules.warm_threshold??40)?'warm':score===0&&q.fit!==false?'unknown':'cold';
 return {score,temperature,reasons};
}
export function extractGuided(text, question) {
 const s=text.trim(),q={};
 const named=s.match(/(?:meu nome é|me chamo|sou o|sou a|sou)\s+([\p{L}]+(?:\s+[\p{L}]+){0,3})/iu);
 if(named&&!/^(dono|dona|decisor|decisora|sócio|sócia|responsável|diretor|diretora)\b/i.test(named[1]))q.name=named[1].split(/\s+(?:da|do|e)\s+/i)[0];
 const company=s.match(/(?:empresa\s+(?:é|se chama)|da empresa|trabalho na|sou da)\s+([\p{L}\p{N}][\p{L}\p{N} &.-]{1,60})/iu);
 if(company)q.company=company[1].split(/[,.]|\s+e\s+(?:quero|preciso)/i)[0].trim();
 if(question==='name'&&!q.name&&!named&&/^[\p{L} ]{2,70}$/u.test(s))q.name=s;
 if(question==='company'&&!q.company&&s.length<100)q.company=s;
 if(/(?:automatiz|automação|integrar|integração|retrabalho|atendimento|triagem|propostas|planilha)/i.test(s)&&!/(?:não tenho|sem)\s+(?:projeto|necessidade|interesse)/i.test(s)){q.need=s;q.fit=true;}
 if(/(?:não tenho|sem)\s+(?:empresa|negócio)|uso pessoal/i.test(s))q.fit=false;
 if(/sem pressa|sem prazo|ano que vem|próximo ano|mais (?:adiante|para frente)|(?:60|90) dias/i.test(s))q.urgency='later';
 else if(/(?:este|nesse|neste) mês|30 dias|urgente|essa semana|esta semana|próxima semana/i.test(s))q.urgency='30_days';
 if(/não decido|não participo|não sou.*(?:dono|dona|decisor|decisora|sócio|sócia)/i.test(s))q.decision='unknown';
 else if(/(?:sou|eu sou)\s+(?:o |a )?(?:dono|dona|decisor|decisora|sócio|sócia)|eu decido/i.test(s))q.decision='decision_maker';
 else if(/participo da decisão|decido junto/i.test(s))q.decision='involved';
 return q;
}
