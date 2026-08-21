# MCP 2.0 — E2E dirigido por intenção natural

Data: 2026-08-21  
App: `/Applications/Soyeht Dev.app` assinado pelo Team ID `W7677A5BK2`  
Commit instalado: `96ca078c9c31`

## Correção de metodologia

Os runs agent-driven anteriores ensinavam nomes como `open_agent_pane` e
`message_agent` no texto entregue ao agente. Eles continuam úteis como prova
do transporte, mas **não são evidência válida de descoberta da capacidade por
intenção do usuário**.

O runner agora bloqueia antes de criar panes se um prompt entregue ao agente
contiver vocabulário de implementação (`MCP`, `soyeht-dev`, `message_agent`,
`open_agent_pane` ou `send_pane_input`). Os prompts completos usados em cada
fluxo também ficam gravados no JSON de evidência para auditoria.

Exemplo real da nova formulação:

> Sem alterar arquivos, abra uma nova pane com opencode neste mesmo workspace,
> no diretório exato …, e dê a ela o nome …. Depois fale com esse agente e peça
> que ele responda a você com exatamente ….

O harness não informou função, servidor, integração, UUID nem comando de CLI.
Processo, `argv`, diretório e mensagens duráveis foram observados somente como
oráculos externos depois da decisão do agente.

## Resultados

### Abrir o agente correto e conversar

Resultado: **3/3 passaram**.

| Pedido natural feito a | Agente que deveria abrir | Processo observado | Diretório | Ida e volta |
|---|---|---|---|---|
| Codex | OpenCode | `opencode --auto` | `QA/` | passou |
| OpenCode | Claude | `claude` | `docs/` | passou |
| Claude | Codex | `codex --yolo` | `TerminalApp/` | passou |

Evidência: `agent-driven-mcp2-natural-language-collaboration-2026-08-21.json`.

### Mensagem chegando enquanto o usuário digita e depois apaga

Resultado: **3/3 passaram**, usando paste UTF-8 e Backspaces físicos via
Accessibility (`café ação` incluído no rascunho).

| Remetente | Destinatário | Ausente antes de apagar | Entregue depois de apagar |
|---|---|---:|---:|
| Codex | OpenCode | sim | sim |
| OpenCode | Claude | sim | sim |
| Claude | Codex | sim | sim |

Em todos os casos o inbox durável registrou contrato 2; o timestamp de entrega
no terminal permaneceu nulo enquanto havia rascunho e apareceu somente após o
rascunho ser apagado.

Evidência: `agent-driven-mcp2-natural-language-collisions-2026-08-21.json`.

## Distinção importante

Depois que o agente escolhe por conta própria como executar a intenção, o
transcript técnico e o envelope de entrega podem naturalmente registrar a
ferramenta escolhida. Isso é resultado observado, não uma dica presente no
pedido do usuário. A auditoria `userPrompt`/`userPrompts` nos JSONs comprova a
separação.
