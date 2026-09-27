# Órbita — desafio Opens

CRM e agenda próprios para uma empresa B2B de serviços de automação e IA. O cliente conversa pelo canal, a equipe trabalha no CRM e o n8n coordena o atendimento. Não depende de HubSpot, RD Station ou Google Calendar.

## O que foi entregue

- Interface com Kanban, busca, temperatura, cadastro, histórico da conversa, edição do contato, assumir/pausar/retomar IA, resposta humana, agenda e configuração das regras.
- Supabase com 10 tabelas operacionais, identidade pelo telefone E.164, RLS, administrador autorizado, Realtime, funções transacionais e API protegida.
- Dois workflows configurados diretamente em **autoconfi.app.n8n.cloud**. Estão salvos como rascunho até cadastrar credenciais e testar os canais.
- Demonstração interativa com dados fictícios, isolada dos dados reais; gráfico do fluxo dentro do CRM e versão de apresentação em `dist/fluxo.html`.
- Exportações JSON em `workflows/`, SQL e código da Edge Function em `backend/`.

## Dois workflows, uma jornada

| Fluxo | Responsabilidade | Abrir |
|---|---|---|
| 01 · Atendimento — Telegram e simulador | Identifica, registra, consulta Claude, qualifica, atualiza CRM e agenda | [n8n](https://autoconfi.app.n8n.cloud/workflow/i8MOp5VaXEcng8SZ) |
| 02 · Entregar respostas — Telegram | Lê fila do bot/operador, confere pausa, envia e registra resultado | [n8n](https://autoconfi.app.n8n.cloud/workflow/DS09OVYC0j9mR1mU) |

O primeiro tem quatro grupos, da esquerda para a direita: identificar → autorizar atendimento → conversar e qualificar → salvar e agendar. Telegram e simulador entram no mesmo atendimento. O segundo mantém a entrega separada para o operador também poder responder pelo CRM. Os três adaptadores antigos foram arquivados; são recuperáveis, mas não fazem parte do teste. WhatsApp real não está integrado nesta versão.

## Simulador WhatsApp

Abra “Simulador WhatsApp” no menu ou `/#simulador`.

- **Ensaio guiado:** funciona imediatamente, sem credenciais. Respostas determinísticas locais; não usa IA real. As sugestões ajudam a ensaiar nome, empresa, dor, prazo, agenda e intervenção humana. Atualiza o Kanban e agenda da demonstração.
- **Conectado:** depois do login, a mensagem entra numa fila autenticada no Supabase. O fluxo 01 busca a próxima mensagem a cada minuto e usa sua credencial Anthropic. A resposta aparece no simulador e no CRM por Realtime. Não envia nada para a Meta ou Telegram.

As identidades têm prefixo fictício +999 e os leads são marcados como demonstração. Horários fictícios são criados para o dia seguinte e ficam separados dos horários reais. O operador pode assumir, pausar e responder. Uma mensagem por conversa fica pendente por vez; após três minutos sem resposta, a fila sinaliza falha. Se o fluxo não estiver ativo, a mensagem continua aguardando. O modo guiado é limitado e não substitui o teste com o modelo.

## Como a qualificação funciona

| Critério com evidência na conversa | Pontos |
|---|---:|
| Aderência a automação/IA em um negócio | 35 |
| Dor ou objetivo concreto | 25 |
| Prazo declarado de até 30 dias | 25 |
| Decisor ou participante da decisão | 15 |

Quente: 70 ou mais, **com aderência e necessidade**. Morno: 40 ou mais sem atingir os critérios de quente. Frio: há informação qualificadora, mas baixa aderência/prioridade. A qualificar: ainda não há sinais suficientes; conhecer apenas o nome não torna o lead frio. Limites ajustáveis nas Configurações, válidos nas próximas avaliações. O score é uma regra demonstrativa a calibrar com o comercial, não uma probabilidade estatística de compra.

Etapa e temperatura são independentes. Um lead pode estar quente e ainda aguardar agenda. O banco guarda motivos, evidências e versão da regra para explicar a decisão.

Ao ficar quente, o lead ganha tarefa humana com prazo de atendimento e resumo. A IA pode concluir a escolha de horário enquanto aguarda o operador. **Assumir** e **Pausar** interrompem a IA e cancelam respostas pendentes. Após a confirmação de agenda de um lead quente, o atendimento passa ao modo humano. Pedido explícito de humano também interrompe imediatamente. Opt-out impede retomada pelo botão normal.

## Identidade, dados e agenda

O telefone no formato `+5511999999999` é a chave primária. `orbita_identities` liga o ID do Telegram ou WhatsApp ao mesmo telefone. Telegram não fornece telefone automaticamente: o fluxo pede o contato próprio e verifica se pertence ao remetente. WhatsApp utiliza o número informado pelo provedor. Trocas de número e identidades conflitantes exigem revisão; não há união automática de pessoas.

`orbita_leads` contém perfil e estados; `orbita_messages`, conversa e fila; `orbita_slots` e `orbita_bookings`, agenda; `orbita_tasks`, próximas ações; `orbita_events`, auditoria; `orbita_settings`, critérios; `orbita_members`, operadores. A chave de integração fica em esquema privado, somente como hash.

O operador abre disponibilidades de 30 minutos no CRM. O bot oferece até três opções reais dos próximos 14 dias, com antecedência mínima de duas horas. O lead responde 1, 2 ou 3; a disponibilidade é conferida outra vez antes da reserva. Restrição de sobreposição por consultor e índices únicos impedem duas reservas confirmadas no mesmo horário e duas reuniões ativas para o mesmo lead. A agenda não cria link de videoconferência: a equipe combina esse detalhe na conversa.

O CRM assina mudanças por Realtime e tem consulta de contingência a cada 15 segundos. A entrega de mensagens nesta versão é uma fila consultada a cada minuto: pode haver até aproximadamente 60 segundos de espera, além da geração da IA. O status fica visível. Não chamar esse envio de instantâneo na apresentação.

## Para ligar o teste real

1. **Integração HTTP no n8n:** crie a credencial `Órbita · Integração segura`, tipo Custom Auth com template. Use `{"headers":{"x-orbita-key":"{{api_key}}"}}`. O valor da chave está no arquivo local `../CONFIGURACAO-PRIVADA.txt`, fora deste projeto. Selecione a mesma credencial em todos os nós HTTP dos dois workflows. Não use a chave `service_role` no navegador.
2. **Telegram:** cadastre o token do bot criado no BotFather e selecione a mesma credencial nos nós Telegram dos fluxos 01 e 02. Um bot deve ter apenas um webhook ativo; não compartilhe o bot de teste com outra automação.
3. **IA:** credencial `Anthropic account` já vinculada ao nó “Claude · conversa comercial”, com `claude-sonnet-5` selecionado a partir da lista retornada pelo n8n. A conexão listou modelos, mas a geração integrada ainda depende da configuração HTTP e ativação. Confira saldo/limites na Anthropic.
4. **Login do CRM:** no Supabase Auth, configure Site URL e Redirect URLs para a URL publicada. O administrador permitido é `l2mortal01@gmail.com`. Configure SMTP se o e-mail padrão do Supabase não permitir esse destinatário. Use “Conectar meu CRM”; a versão demonstrativa não grava no banco.
5. **Agenda:** entre no CRM real e abra horários de teste. Nenhuma disponibilidade real foi inventada no seu banco.
6. **Ativação:** para Telegram, selecione as credenciais e publique os dois fluxos. Para usar somente o simulador conectado, configure HTTP no fluxo 01, desabilite temporariamente o gatilho “Mensagem no Telegram” e o nó “Pedir contato no Telegram” se faltarem suas credenciais, e publique somente o fluxo 01. O fluxo 02 não participa da simulação. Verifique as execuções após enviar uma mensagem de teste.
7. **Teste:** informe nome/empresa/dor/prazo, escolha um horário e assuma a conversa. No Telegram, primeiro compartilhe seu próprio contato. O simulador usa identidade e agenda fictícias. WhatsApp no CRM é a visão do produto futuro; não existem mais adaptadores WhatsApp ativos neste escopo.

Não rode os SQLs novamente no projeto já configurado. Os arquivos são referência e base de reprodução em um projeto vazio: `schema.sql`, `002-delivery-and-guards.sql`, `003-qualification.sql`, `simulator.sql`, `simulator-calendar.sql`. Uma nova instalação precisa gerar nova chave de integração e salvar seu hash no esquema privado. Os JSONs são cópias de revisão dos fluxos; ao importar em outra instância, remapeie credenciais.

## Validação realizada

14 testes de regressão e quatro grupos adicionais de testes do simulador passaram no Supabase; o rollback retirou todos os dados de teste. Cobrem identificação, duplicação, nome atualizado, score, fila humana, intervenção após reserva de envio, resposta obsoleta, reserva, sobreposição, mudança de canal, falha antiga da IA, opt-out, desconhecido e controle de acesso. Arquivos: `backend/tests.sql` e `backend/simulator-tests.sql`. Os novos testes cobrem acesso, identidade fictícia, fila, conclusão, agenda isolada e resposta humana.

A API retornou 401 sem chave e com chave inválida, e 200 com chave válida e fila vazia. O verificador de segurança do Supabase não apontou alertas. Os avisos de desempenho restantes são índices ainda não usados em um banco recém-criado.

No navegador foram conferidos layout, consulta de leads, abertura da conversa, assumir atendimento, mensagem humana simulada e reserva na demonstração. O JavaScript passou na verificação de sintaxe. Os workflows passaram na validação estrutural do n8n.

**Pendente:** execução integrada com token real de Telegram, chamada real ao modelo e login por e-mail no domínio publicado. Não houve envio de mensagem real nem demonstração com leads de produção. Validação estrutural não substitui esses testes.

## Riscos e limites para explicar

| Risco | Tratamento e limite |
|---|---|
| LLM inventar informações ou seguir instruções do lead | Schema, lista de campos, evidência literal, score determinístico e bloqueio de promessas. Isso reduz, mas não elimina alucinação e prompt injection; testar conversas adversariais antes de produção. |
| Mensagens rápidas ou execução fora de ordem | Versão por lead e descarte de resultado antigo; histórico recente incluído na extração. Não há debounce: várias mensagens podem consumir chamadas de IA. |
| Humano e IA responderem juntos | Modo humano, cancelamento e conferência imediatamente antes do envio. Uma mensagem já entregue ao provedor não pode ser recolhida. |
| Provedor aceitar e a confirmação se perder | Estado “conferir entrega”; sem reenvio automático cego. Operador verifica antes de tentar novamente. |
| Agenda disputar o mesmo horário | Transação e restrições no PostgreSQL; confirmação somente após gravar a reserva. |
| Lead quente sem atendente | Tarefa com SLA visível no CRM. Não há notificação externa nem escala automática para gestor nesta versão. |
| Simulação e produção | Interface semelhante ao WhatsApp não é integração Meta. Horários e contatos fictícios ficam separados; o canal oficial exige implantação própria futura. |
| Privacidade | RLS, lista de operadores, chave restrita no servidor. Definir retenção, base legal, procedimento de exclusão e backup com o cliente; não afirmar conformidade LGPD só por ter RLS. |
| Custo da automação | Polling de um minuto equivale a cerca de 43.200 execuções/mês por agendador em 30 dias, (dois agendadores se ambos os fluxos estiverem ligados), antes dos atendimentos. Desligue fora dos testes; produção deve considerar entrega por evento com recuperação periódica. |
| Crescimento da operação | Esta versão é para um cliente e um administrador. Tela carrega até 500 leads/1.000 mensagens; paginação por conversa, equipe e monitoramento são próximos passos antes de volume maior. |
| Chave exposta na referência | O chat público do Claude contém um token MCP do n8n. Revogue/rotacione aquele token; ele não foi copiado para este projeto. |

## Referências e defesa comercial

[Kommo](https://www.kommo.com/): funil e conversa próximos. [Letalk](https://letalk.com.br/): colaboração IA/humano e filas. [BotConversa](https://botconversa.com.br/): qualificação conversacional e Kanban. [Agendor](https://www.agendor.com.br/): histórico e próxima atividade comercial. As ideias foram adaptadas ao escopo; não há cópia de telas ou promessa de equivalência funcional.

Da referência do Claude, foram preservadas pontuação por regras, pausa humana e API oficial. A proposta foi simplificada em dois fluxos no seu ambiente autoconfi e substitui CRM/agenda de terceiros pelo Supabase e pela interface própria.

**Como vender a escolha:** “O cliente precisa transformar conversas em oportunidades acompanhadas. Por isso construí uma ferramenta focada no processo dele: cadastro, qualificação, agenda e passagem para o vendedor. Os dados e as regras ficam centralizados e a operação tem menos telas para aprender. A decisão de custo deve comparar implantação, hospedagem, IA, mensagens e manutenção com as licenças que seriam necessárias; a economia precisa ser medida, não presumida.”

## Roteiro de apresentação — 5 minutos

1. Dor: contatos chegam, a equipe perde contexto e demora para agir. Abra o funil.
2. Jornada: mensagem → identificação → IA → regras → agenda → humano. Abra “Fluxo & decisões”.
3. Demonstre no simulador: nome → empresa → necessidade → prazo → horário 1. Mostre os campos e motivos mudando, o lead no Kanban e a reserva. Assuma e responda como humano. Informe explicitamente se está usando ensaio guiado ou IA conectada.
4. Técnica: telefone único, eventos idempotentes, versão da conversa, reserva transacional e RLS. Relacione isso à sua experiência com validações, SQL e integrações; não invente resultados comerciais deste projeto.
5. Limites: informe o que já foi testado e o que depende de credenciais. Feche com um plano de piloto medindo tempo até atendimento humano, reuniões confirmadas, falhas de entrega e custo por lead.
