# Órbita — CRM, agenda e atendimento com IA

Aplicação própria para uma empresa de automação e IA. Cadastro, conversa, qualificação, Kanban, agenda e passagem ao vendedor compartilham o mesmo banco. Atualização: 28/09/2026 (UTC).

## Acessar e demonstrar

- [Abrir CRM](https://orbita-crm-opens-joao.limalipe355.chatgpt.site/).
- Administrador: l2mortal01@gmail.com. Credenciais iniciais estão no arquivo local `../ACESSOS-PRIVADOS.txt`, fora deste projeto e do ZIP.
- Três funcionários: Ana Martins, Bruno Almeida e Carla Santos, com 12 leads fictícios cada. Use o filtro de demonstração para comparar carteiras. O administrador também possui o lead utilizado no teste integrado.
- Entre, abra Simulador WhatsApp, informe um telefone de teste com código do país e converse. Exemplo: nome/empresa → necessidade de automação → prazo neste mês → decisor → opção de horário.
- O simulador usa Claude real e grava o lead no CRM. Não envia mensagens para a Meta. Retomar o mesmo telefone preserva o histórico; uma conversa assumida pelo humano permanece humana até o operador retomar a IA.
- O Site conserva o acesso privado do proprietário na hospedagem. Os usuários do Supabase já existem, mas compartilhar o Site com funcionários externos também exige configurar o acesso na hospedagem.

## Dois fluxos, uma jornada

| Fluxo ativo | Responsabilidade |
|---|---|
| [01 · Atendimento](https://autoconfi.app.n8n.cloud/workflow/i8MOp5VaXEcng8SZ) | Telegram ou webhook do simulador → identificar → verificar modo → Claude → validar → atualizar perfil, pontuação, agenda e tarefa humana |
| [02 · Entrega Telegram](https://autoconfi.app.n8n.cloud/workflow/DS09OVYC0j9mR1mU) | A cada minuto, reservar mensagem → conferir pausa/versão → enviar → registrar entrega |

O primeiro possui quatro grupos visuais. Telegram e simulador usam a mesma lógica. Os três adaptadores antigos permanecem arquivados. WhatsApp oficial é uma integração futura; o simulador reproduz a experiência dentro do CRM.

Credenciais vinculadas: Header Auth **Órbita Integração**, **Telegram account** e **Anthropic account**. O erro “Simplified Custom Auth” foi corrigido em todos os nós HTTP. A chave nunca vai para o navegador: a Edge Function autenticada encaminha a mensagem ao webhook n8n. O simulador recebe respostas por Realtime; não depende de consulta de um minuto.

## Acesso e responsabilidades

| Recurso | Administrador | Funcionário |
|---|---|---|
| Leads e conversas | Todos, com filtro por responsável | Apenas sua carteira |
| Assumir, pausar, retomar e responder | Todos | Próprios leads |
| Atribuir responsável | Sim | Não |
| Reservar reunião | Sim | Para seus leads |
| Criar/editar/fechar disponibilidade e cancelar reserva | Sim | Não |
| Criar/desativar usuários e configurar regras | Sim | Não |
| Indicadores | Equipe e filtros individuais | Própria carteira |

As restrições são aplicadas no banco (RLS e funções com verificação de identidade), não apenas escondidas na tela. Desativar um membro bloqueia também suas sessões existentes. Autorizações usam o UUID do Supabase Auth, sem confiar em metadados editáveis pelo usuário. Há login/senha, mostrar senha, recuperação, nova senha e alteração pela Minha conta. Não há cadastro público; o administrador cria contas.

Os gráficos mostram carteira, etapas, entradas diárias, clientes atendidos, respostas humanas, reuniões e tarefas vencidas. “Atendidos” conta clientes distintos com resposta humana enviada pelo funcionário. Carteira e conversão seguem o responsável atual; transferências podem mudar a atribuição histórica. Período e filtro de teste/real ficam explícitos. Os dados fictícios não representam resultados de produção.

## Qualificação e agenda

Aderência: 35 pontos; necessidade: 25; prazo até 30 dias: 25; decisão: 15. Quente exige pelo menos 70, aderência e necessidade; morno começa em 40. Sem evidências suficientes, permanece “A qualificar”. Nome sozinho não define temperatura. A IA extrai contexto e evidências; regras determinísticas calculam a pontuação. Esses critérios são hipóteses comerciais ajustáveis, não uma probabilidade estatística de compra.

Lead quente abre tarefa com SLA e recebe opções de agenda. A reserva é transacional e bloqueia conflitos de horário. Após confirmação, o lead quente passa ao humano. Pedido explícito de humano, pausa e opt-out interrompem a IA. O operador pode intervir a qualquer momento.

Telefone E.164 é a chave do lead. Telegram exige compartilhar o contato próprio e valida a autoria. Simulador e contatos reais não podem reutilizar a mesma identidade indevidamente. Horários fictícios permanecem separados dos reais. Nenhum link de videoconferência é criado automaticamente. Editar a agenda não notifica o cliente automaticamente; a equipe precisa comunicar a mudança.

## Arquitetura e arquivos

- `dist/`: aplicação estática e `fluxo.html` para apresentação/impressão.
- `workflows/`: exportações atuais dos dois workflows. Credenciais contêm referências, sem tokens; remapeie ao importar em outra instância.
- `backend/index.ts`: Edge Function orbita-automation, protegida pela chave de integração.
- `backend/crm-api.ts`: Edge Function orbita-crm, valida usuário autenticado e acesso; despacha simulação e cria contas por ação administrativa.
- SQL: schema.sql → 002-delivery-and-guards.sql → 003-qualification.sql → simulator.sql → simulator-calendar.sql → team-access.sql → team-metrics.sql → team-guards.sql → team-calendar.sql.
- `backend/demo-team-seed.sql`: massa fictícia, seguida de demo-score-consistency.sql; executar uma vez após criar/vincular os três usuários. Não executar novamente no projeto já configurado.
- `backend/tests.sql`, `simulator-tests.sql` e `test-results-v3.json`: regressões e resultados de autorização.

Os SQLs documentam a instalação e evolução; o projeto remoto já está atualizado. Em uma instalação nova, configure os usuários, UUIDs, segredos de Edge Functions, chave/hash de integração, dispatch_config privado e credenciais do n8n. O registro privado de despacho contém a chave necessária ao servidor; o verificador da integração usa hash. Nenhum segredo administrativo deve ser colocado em dist.

## Validação realizada

- 14 regressões transacionais e quatro grupos do simulador aprovados: identidade, idempotência, perfil, score, agenda, concorrência, resposta antiga, pausa, humano e isolamento dos dados fictícios.
- 17 verificações reais de acesso: carteiras separadas, bloqueio de lead alheio, bloqueio de alterações administrativas, escalada de privilégio negada, transferência e revogação imediata, desativação de usuário e métricas por perfil.
- Sete testes complementares aprovados: ocupação sem vazamento, edição administrativa, bloqueio de criação de usuário, autenticação da API e filtros de métricas.
- Login/senha real, sessão de administrador e funcionária, navegação conforme o perfil, atualização de dados e resposta humana conferidos.
- Simulador integrado à Anthropic: nome/empresa registrados; necessidade e prazo/decisão elevaram a pontuação de 60 a 100; três horários oferecidos; opção 1 confirmou reserva e passagem ao humano; resposta do vendedor persistida como enviada.
- Ambos os workflows ativos; exports conferidos; JavaScript validado com node --check.
- Solicitação de recuperação de senha retornou HTTP 200. Isso confirma aceitação da solicitação, não entrega do e-mail.

## Pendências para validar operação externa

1. Enviar “Olá” e compartilhar o próprio contato no bot Telegram correto. Credenciais estão vinculadas e fluxos publicados, mas a conversa real no Telegram ainda não foi confirmada neste teste.
2. Supabase → Authentication → URL Configuration: Site URL `https://orbita-crm-opens-joao.limalipe355.chatgpt.site`; autorizar Redirect URL `https://orbita-crm-opens-joao.limalipe355.chatgpt.site/**` e, apenas para desenvolvimento, `http://127.0.0.1:4173/**`. Configurar SMTP e verificar recebimento/abertura do e-mail de recuperação. O painel não estava autenticado e o MCP não oferece essa configuração.
3. Para uso por outros funcionários, configurar compartilhamento da hospedagem; hoje o Site é privado do proprietário. Trocar senhas iniciais pela Minha conta. E-mails .example são fictícios e não recebem recuperação; usar e-mails reais ao cadastrar a equipe real.

## Riscos e decisões

| Risco | Tratamento e limite |
|---|---|
| IA inventar fatos ou obedecer instruções do lead | Saída estruturada, evidências e regras; testar casos adversariais e revisar qualidade antes de produção |
| Bot competir com vendedor | Pausa, versão da conversa e cancelamento; uma mensagem já entregue ao provedor não pode ser recolhida |
| Reserva simultânea | Transação, restrições e confirmação após gravação |
| Entrega incerta | Estado para conferência, sem reenvio cego |
| Dados de outro funcionário | RLS, funções autorizadas e testes com contas distintas |
| Lead quente sem resposta | Tarefa com SLA; não há escalonamento externo automático nesta versão |
| Custo de execução | Um agendador de entrega a cada minuto representa cerca de 43.200 execuções em 30 dias; o simulador usa evento. Planejar entrega por evento ou desligar testes ociosos conforme o plano n8n |
| Privacidade e escala | Definir retenção, exclusão, backup e base legal. Tela limita cargas a 1.000 registros/2.000 mensagens; paginação e monitoramento precisam evoluir para volume maior |
| Token no chat compartilhado de referência | Rotacionar o token MCP exposto naquela referência; ele não foi incluído no projeto |

## Referências e defesa comercial

[HubSpot: permissões](https://knowledge.hubspot.com/user-management/hubspot-user-permissions-guide) inspirou a separação entre carteira própria e acesso global. [Kommo: equipe comercial](https://support.kommo.com/docs/set-up-kommo-for-a-sales-team) e [permissões](https://support.kommo.com/docs/set-permissions) orientaram responsável único, colaboração e controles administrativos. A pesquisa anterior em Kommo, Letalk, BotConversa e Agendor informou funil junto à conversa, intervenção humana e próxima atividade. [Supabase Auth](https://supabase.com/docs/guides/auth/passwords) orientou o acesso e a recuperação.

Defesa sugerida: “O cliente precisa transformar conversas em oportunidades acompanhadas. A ferramenta reúne o processo específico dele, com menos telas e regras próprias. Comparo implantação, infraestrutura, IA e manutenção com as licenças necessárias para dimensionar o custo total; a economia precisa ser medida no piloto.”

Apresentação em cinco minutos: mostre as três carteiras → abra o desenho do fluxo → converse no simulador → confirme reunião e intervenção humana → compare os indicadores → explique os riscos e o que falta validar no canal externo.
