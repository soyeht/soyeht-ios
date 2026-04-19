# Terminal Conversations — Plano v2

> Substitui `docs/terminal-without-tmux-plan.md`. Branch atual: `feature/unify-terminal-screen`.
> Validado com: `axiom:concurrency-validator`, `axiom:swiftui-architecture-auditor`, pesquisa técnica tmux + Apple APIs.
> Data: 2026-04-17.

## 1. Contexto e mudança de eixo

O app Soyeht é cliente de terminal remoto. O caso de uso dominante virou **conversas com agentes de IA** (Claude Code, Codex, OpenClaw, Hermes) rodando em servidores, com continuidade Mac ↔ iPhone.

A tentativa anterior (scroll nativo encaminhando copy-mode do tmux) quebrou UX — tmux em alternate buffer não dá scroll nativo iOS decente. O plano v1 (`terminal-without-tmux-plan.md`) propunha abolir copy-mode e usar capture-pane + scroll nativo.

Este v2 vai além: **eleva "conversa" a entidade de primeira classe no servidor**, com o tmux invisível por baixo, e desenha o caminho completo até worktrees paralelos + teams multi-agente.

## 2. Decisões arquiteturais (resumo)

| Decisão | Valor | Motivo |
|---|---|---|
| **Source of truth** | Servidor (não iCloud KVS) | Conversa vive no server; KVS é cache/presença de Fase 2 |
| **Conversa** | First-class server entity | Permite TranscriptAdapter, cross-device coerente, workspaces |
| **tmux** | Mantido no servidor, invisível na UX | Persistência grátis, multi-attach nativo, sem copy-mode |
| **Protocolo de delta no reattach** | Ring buffer + seq NO SERVIDOR (não tmux -C) | 1 code path, agnóstico de tmux, padrão mosh/ttyd |
| **Backfill inicial** | `capture-pane -e -p -S -100000` gzipped | Uma vez no attach; depois stream via ring+seq |
| **Commander lock** | Server-enforced (input gate) + WS broadcast | iCloud KVS desnecessário quando ambos attachados |
| **Mirror vs takeover** | Mirror default, takeover explícito | Evita roubar input sem querer ao abrir |
| **Workspace** | Opcional (conversa é a primitiva) | Não obriga agrupamento; permite abas soltas |
| **Templates de agente** | JSON versionado NO servidor | Adicionar agente = config, não refactor |
| **Modos de comunicação em workspace** | Display / Broker / Native | Agnostic de agente; `inject-input` é a primitiva |
| **Worktrees** | Endpoints server-side (`git worktree add/remove`) | Paralelismo de features nativo |
| **iCloud KVS** | Fase 2 (não MVP) | WebSocket resolve MVP; KVS vira valor quando app fechado |

## 3. Histórias de usuário

### Core (MVP)

- **US-1 — Continuidade Mac → iPhone.** Claude no Mac, sair, abrir iPhone, ver conversa com histórico completo, continuar digitando.
- **US-2 — Criar conversa Claude no Mac.** `⌘T` → template Claude → prompt rodando em <2s.
- **US-3 — Acesso bidirecional total.** Tudo que crio num device aparece no outro em <5s.
- **US-4 — Terminal iPhone nativo.** Scroll inércia + rubberband + seleção sobrevive live + botão "↓ Ao vivo".
- **US-5 — Abrir Claude/Codex rápido no iPhone.** Sheet inicial mostra 3 projetos recentes + picker de agente, <3s até prompt.

### Avançadas (Fase 2+)

- **US-6 — Workspace plan+review.** Claude planeja numa aba, Codex revisa em outra; "enviar pra @reviewer" manda última resposta pro outro pane via `inject-input`.
- **US-7 — Workspace misto.** N Claudes + abas shell do servidor num único workspace; tipo de cada pane visível no topo.
- **US-8 — Worktrees paralelos.** Escolho repo + lista de branches → server cria N worktrees + spawna agente em cada, sidebar git por pane.

## 4. Modos de workspace

Workspace é opcional. Quando existe, declara um **modo de comunicação**:

### Modo 1 — Display
Só agrupamento visual. Nenhuma comm entre panes. MVP usa *conversas soltas*, este modo chega em Fase 2.

### Modo 2 — Broker (app medeia)
Soyeht fornece 3 primitivas **agent-agnostic**:
- **Mentions (`@nome texto`)**: input interceptado no cliente, injetado via `POST /conversations/:id/inject-input` no pane destino.
- **Pipe output→input**: seleção (ou bloco inteiro) de um pane vira input de outro pane.
- **Shared drawer**: volume compartilhado entre tmux sessions do workspace (Fase 3).

Funciona com Claude + Codex + OpenClaw + Hermes + shell puro em qualquer combinação.

### Modo 3 — Native protocol
Agente tem protocolo próprio (ex: Claude Code Teams). Server lança com flags certos; Soyeht só renderiza + mostra sidebar de metadata exposta pelo protocolo. Locked ao agente, mais rico.

Modos compõem: workspace native Claude Teams também aceita mentions do broker.

## 5. Arquitetura em camadas

### 5.1 Topologia de deployment

Não há conexão peer-to-peer Mac ↔ iPhone. Ambos são clientes de um **backend Soyeht** (daemon HTTPS/WSS). O backend pode estar em:

- **Servidor dedicado** (Linux/Mac remoto, ex: `<user>@<host-ip>`)
- **"Mac Host"** — daemon rodando no próprio Mac do usuário, pareado por QR (`theyos://pair`), identificado via `PairedServer.name = "Mac Host"`. Esse é o cenário atual do usuário principal: Mac app e iPhone são **ambos** clientes do backend que por acaso vive no mesmo Mac. Vantagem: filesystem local do Mac fica acessível; conexão Mac↔backend é localhost (baixa latência).

Isso é invisível pro plano: o servidor é abstração. Onde ele roda é decisão de deploy, não de arquitetura. O MVP funciona identicamente em ambos os cenários.

Ponto operacional (fora de escopo do código): **como iPhone alcança "Mac Host" na 4G?** Precisa LAN comum, ou tunnel/relay (Tailscale, Cloudflared, ngrok, ou mecanismo próprio do theyOS). Pareamento inicial por QR pressupõe LAN; uso remoto pressupõe tunnel. Documentação de ops deve cobrir isso.

### 5.2 Camadas lógicas

```
┌─────────────────────────────────────────────────┐
│  Cliente (iOS/macOS)                            │
│  - TerminalSessionModel (@Observable)           │
│  - WebSocketTerminalView (@MainActor)           │
│  - ConversationListView / WorkspaceView         │
│  - Commander UI (banner, takeover)              │
└──────────────────┬──────────────────────────────┘
                   │ WebSocket (bytes + events) + REST
┌──────────────────┴──────────────────────────────┐
│  Servidor Soyeht                                │
│  - Conversation store (SQLite/Postgres)         │
│  - Ring buffer + seq por conversa               │
│  - Commander gate (input filter)                │
│  - WS broadcast (commander_changed, workspace)  │
│  - TranscriptAdapter (Claude/…)                 │
│  - Template registry (JSON)                     │
│  - Worktree manager                             │
└──────────────────┬──────────────────────────────┘
                   │ tmux sockets, git, PTY
┌──────────────────┴──────────────────────────────┐
│  tmux + PTYs                                    │
│  - history-limit 100000                         │
│  - window-size latest                           │
└─────────────────────────────────────────────────┘
```

## 6. Fase 0 — Pré-refactor (BLOQUEANTE)

**Objetivo:** tornar a camada cliente Swift-6-safe e extrair modelo antes de empilhar features. Sem isso, commander + reconnect + workspaces viram gambiarra sobre gambiarra.

### 0.1 — Annotations de concorrência

- `Sources/SwiftTerm/iOS/iOSTerminalView.swift:54` — adicionar `@MainActor` em `TerminalView: UIScrollView`.
- `TerminalApp/Soyeht/WebSocketTerminalView.swift:5` — adicionar `@MainActor` na classe.
- `TerminalApp/Soyeht/TerminalHostViewController.swift:14` — adicionar `@MainActor`.
- Revisar todos os `Task { ... }` em:
  - `TerminalHostViewController.swift:421–450` (voice input)
  - `TerminalHostViewController.swift:904` (key repeat)
  - `InstanceListView.swift:52`
  - `FileBrowser/FileBrowserViewController.swift:119`
  Aplicar `[weak self]` + `guard let self` em cada.
- `WebSocketTerminalView.swift:164–184` — `backfillInProgress` e `pendingLiveBytes` precisam mutação sob `@MainActor` (após annotation da classe fica automático; auditar).

### 0.2 — Extrair `TerminalSessionModel`

Hoje `WebSocketTerminalView` concentra state machine de conexão em UIView. Não dá pra multi-client, CloudKit sync, testes unitários.

Novo arquivo: `Packages/SoyehtCore/Sources/SoyehtCore/Terminal/TerminalSessionModel.swift`

```swift
@MainActor
@Observable
public final class TerminalSessionModel {
    public enum ConnectionState { case disconnected, connecting, connected, reconnecting(attempt: Int) }

    public private(set) var connectionState: ConnectionState = .disconnected
    public private(set) var commanderClientId: String?
    public private(set) var isCommander: Bool = false
    public let conversationId: String
    public let clientId: String  // device+app instance ID, estável

    public func connect(wsUrl: URL) async { /* ... */ }
    public func disconnect() { /* ... */ }
    public func claimCommander() async throws { /* POST /conversations/:id/commander */ }
    public func send(_ bytes: Data) { /* gated por isCommander */ }
    // ...
}
```

`WebSocketTerminalView` passa a receber o modelo via init e observar `@Observable` state. Toda lógica de reconnect/commander sai do view.

### 0.3 — Estender `SessionStore`

`Packages/SoyehtCore/Sources/SoyehtCore/Store/SessionStore.swift`:

```swift
@Published public private(set) var activeConversations: [Conversation] = []
@Published public private(set) var activeCommanders: [ConversationID: ClientID] = [:]
```

Mirror do server state, atualizado via WS events + polling REST de fallback.

### 0.4 — Remover forwards de tmux copy-mode

Desta branch (`feature/unify-terminal-screen`):
- `Sources/SwiftTerm/iOS/iOSTerminalView.swift`: remover `altBufferScrollPan` + `AltBufferPanDelegate`.
- `TerminalApp/Soyeht/WebSocketTerminalView.swift`: remover `forwardTmuxScroll`, `forwardTmuxExitCopyMode`.
- `TerminalApp/Soyeht/TerminalHostViewController.swift`: remover chamada de `forwardTmuxExitCopyMode` em `scrollToLive()`.

Ficam: o fix do `linefeed` (preserva seleção), o tail-follow gated de `updateScroller`, o redraw hint do `contentOffset.didSet`.

### Critério de aceite Fase 0

- ✅ Build com `-strict-concurrency=complete` sem erros nos arquivos modificados
- ✅ Thread Sanitizer limpo rodando fluxo voice + scroll + reconnect
- ✅ `TerminalSessionModel` com >80% coverage em teste unitário (sem renderizar view)
- ✅ Scroll nativo funciona em shell (alt buffer sem forward)
- ✅ Nenhuma referência a `forwardTmuxScroll` / copy-mode no código

**Estimativa:** 3 dias.

## 7. Fase 1 — MVP (Claude + continuidade Mac↔iPhone com commander)

### Escopo

- **1 agente**: Claude Code
- **N conversas simultâneas** listadas (sem workspace, sem worktree, sem teams)
- **Mac** cria conversa, iPhone atacha
- **iPhone** entra em mirror, botão "Assumir controle" → flipa commander
- **Reconnect** com backfill curto
- Templates de agente já em JSON mas só com Claude (+ Shell baseline)

### 7.1 — Schema de conversa (server)

```sql
CREATE TABLE conversations (
    id TEXT PRIMARY KEY,
    server_container TEXT NOT NULL,
    tmux_session TEXT NOT NULL,
    project_path TEXT,
    agent_kind TEXT NOT NULL,         -- 'claude' | 'shell' | ...
    agent_args TEXT,                  -- JSON array
    commander_client_id TEXT,
    last_activity_at TIMESTAMP,
    created_at TIMESTAMP,
    status TEXT NOT NULL,             -- 'active' | 'paused' | 'ended'
    transcript_path TEXT,             -- opcional; preenchido se TranscriptAdapter descobrir
    preview_text TEXT,                -- last N chars do capture-pane, atualizado sob demanda
    workspace_id TEXT                 -- opcional (Fase 2)
);

CREATE INDEX idx_last_activity ON conversations(last_activity_at DESC);
CREATE INDEX idx_status ON conversations(status);
```

### 7.2 — Endpoints REST

| Método | Path | Propósito |
|---|---|---|
| `GET` | `/conversations` | Lista todas do usuário autenticado |
| `POST` | `/conversations` | Cria (body: `{agent_kind, project_path?, agent_args?}`) |
| `GET` | `/conversations/:id` | Detalhe |
| `GET` | `/conversations/:id/backfill?lines=500&seq=X` | Capture-pane gzipped + current_seq |
| `POST` | `/conversations/:id/commander` | Reivindica commander (body: `{client_id}`) |
| `POST` | `/conversations/:id/inject-input` | (Fase 2 broker) injeta bytes no PTY |
| `DELETE` | `/conversations/:id` | Encerra (kill tmux session) |

Autenticação: o header que já existe no app.

### 7.3 — WebSocket

URL: `wss://<server>/conversations/:id/stream?client_id=<uuid>&last_seq=<n>`

**Frames server → client:**

```
{ "type": "chunk", "seq": 1524, "data": "<base64 or binary>" }
{ "type": "commander_changed", "new_commander_id": "<uuid>" }
{ "type": "status", "status": "active" | "paused" | "ended" }
{ "type": "reset" }   // seq do cliente caducou, refaz backfill
```

**Frames client → server:**

```
{ "type": "input", "data": "<base64>" }
{ "type": "resize", "cols": 80, "rows": 24 }
{ "type": "ping" }
```

O server drop silenciosamente qualquer `input` que não venha do `commander_client_id` atual.

### 7.4 — Ring buffer + seq

Server mantém, por conversa, buffer circular em memória:

- Tamanho: 10 MB por conversa (configurável).
- Cada write no PTY gera um chunk `{seq++, bytes}`.
- Broadcast pra todos os clients attacheados.
- No `GET /backfill?seq=X`:
  - Se X >= `ring.oldest_seq`: retorna chunks `X..current`.
  - Senão: retorna `capture-pane -e -p -S -500` (gzip) + `current_seq` + flag `full_backfill=true` (cliente descarta buffer local e feeda do zero).

### 7.5 — Commander gate (server)

```
on_input_frame(client_id, bytes):
    if conv.commander_client_id != client_id:
        return  # silently drop
    pty.write(bytes)
    ring.append(...)  # bytes chegam no output via echo ou resposta
```

`POST /conversations/:id/commander { client_id }`:
```
with atomic_transaction:
    conv.commander_client_id = client_id
broadcast({type: "commander_changed", new_commander_id: client_id}, to: all_attached)
```

### 7.6 — Cliente iOS (MVP)

Novos arquivos:
- `TerminalApp/Soyeht/Conversations/ConversationsListView.swift` — lista com chip "Mac ativo / iPhone / 💤".
- `TerminalApp/Soyeht/Conversations/NewConversationSheet.swift` — picker projeto + agente (só Claude + Shell no MVP).
- `TerminalApp/Soyeht/Conversations/CommanderBanner.swift` — banner read-only / assumir controle.

Fluxo:
1. App abre → `SessionStore.fetchConversations()` → renderiza lista.
2. Tap numa conversa → cria `TerminalSessionModel(conversationId)` → `connect(wsUrl)` com `last_seq=0` → recebe backfill.
3. Se `commander_client_id != self.clientId` → UI entra em mirror: `view.isEditable = false`, teclado não sobe, banner fixo.
4. Tap no banner "Assumir controle" → `model.claimCommander()` → server flipa + broadcasta → banner some no iPhone, aparece no Mac.
5. Reconnect: `last_seq` salvo, reattach manda `last_seq` atual; server responde com chunks faltando OU reset + capture-pane.

### 7.7 — Cliente macOS (MVP)

Mac app hoje já cria sessão. Mudanças mínimas:
- Ao criar sessão → `POST /conversations` no início → recebe `conversation_id` → WS conecta com esse ID + client_id do Mac.
- Mac começa como commander (primeiro client).
- Mac observa `commander_changed` via WS; quando vira não-commander → mostra banner "Controle no iPhone · [Retomar]".
- Lista lateral de "Conversas ativas" (`ConversationsSidebarView`) — reuso da mesma REST.

### 7.8 — Templates de agente

`server/config/agent_templates.json`:

```json
[
  {
    "id": "claude",
    "name": "Claude Code",
    "icon": "🤖",
    "command": "claude",
    "requires_cwd": true,
    "resume_flag": "--continue",
    "persists_offline": true,
    "transcript_adapter": "claude_jsonl"
  },
  {
    "id": "shell",
    "name": "Shell",
    "icon": "🐚",
    "command": "$SHELL",
    "requires_cwd": false,
    "resume_flag": null,
    "persists_offline": false,
    "transcript_adapter": null
  }
]
```

MVP inclui esses dois. Fase 2 adiciona `codex`, `openclaw`, `hermes` via adicionar linhas.

### 7.9 — tmux settings server-side

Server, ao criar sessão tmux pra conversa:

```bash
tmux new-session -d -s "conv-$CONV_ID" -x 200 -y 50
tmux set-option -t "conv-$CONV_ID" -g history-limit 100000
tmux set-option -t "conv-$CONV_ID" -g window-size latest
tmux set-option -t "conv-$CONV_ID" -g mouse off
tmux send-keys -t "conv-$CONV_ID" "$COMMAND" Enter
```

### Critério de aceite Fase 1

- ✅ US-1, US-2, US-3, US-4, US-5 cumpridas com critérios listados em §3.
- ✅ Commander flip Mac→iPhone→Mac em <2s cada lado.
- ✅ Input do não-commander é descartado silenciosamente; UI reflete estado.
- ✅ Reconexão com rede caindo 30s recupera sem perder linhas (seq match).
- ✅ Reconexão com rede caindo 10min recupera via reset + capture-pane (aceitável perder últimas 500 linhas se buffer rolou).
- ✅ Encerrar conversa em device A some em device B em <5s.
- ✅ Claude Code rodando perfeitamente; shell puro funcionando.
- ✅ Thread Sanitizer limpo em todos os flows.

**Estimativa:** 11 dias focados após Fase 0.

**Total Fase 0 + 1 = 14 dias.**

## 8. Fase 2 — Workspaces + panes macOS + broker + Claude Teams

### 8.1 — Schema extendido

```sql
CREATE TABLE workspaces (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    type TEXT NOT NULL,              -- 'adhoc' | 'team' | 'worktree-team'
    template_id TEXT,                -- FK workspace_templates (quando type != adhoc)
    communication_mode TEXT NOT NULL, -- 'display' | 'broker' | 'native'
    layout_json TEXT,                -- Mac-only: tree split/grid
    created_at TIMESTAMP
);

ALTER TABLE conversations ADD COLUMN workspace_role TEXT;
-- role = 'lead' | 'sub' | 'reviewer' | 'coder' | 'shell' | null

CREATE TABLE workspace_templates (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    type TEXT NOT NULL,
    communication_mode TEXT NOT NULL,
    spec_json TEXT NOT NULL          -- conversations array, sidebar config, etc.
);
```

### 8.2 — Endpoints novos

| Método | Path | Propósito |
|---|---|---|
| `GET/POST/DELETE` | `/workspaces` | CRUD |
| `POST` | `/workspaces/:id/conversations` | Adicionar conversa ao workspace |
| `GET` | `/workspaces/:id/layout` | Layout tree atual |
| `PUT` | `/workspaces/:id/layout` | Salvar layout (debounced do cliente Mac) |
| `POST` | `/conversations/:id/inject-input` | Broker: injeta bytes como se fossem input de tecla |
| `GET` | `/workspace_templates` | Lista disponível |
| `POST` | `/workspaces/from_template` | Instancia template (body: `{template_id, vars}`) |

### 8.3 — Broker: `inject-input`

Simples endpoint:

```
POST /conversations/:id/inject-input
body: { "data": "<base64>", "add_newline": true }
```

Server escreve direto no PTY master. **Não** precisa ser commander (é o app fazendo, não o usuário). Para segurança, rate-limit e auth check.

Cliente usa:
- **`@nome texto`** no input box → regex intercepta → resolve nome no workspace → POST inject-input no pane destino.
- **"Enviar pra @X"** (botão/long-press no bloco selecionado) → seleção + POST.

### 8.4 — macOS: panes/tabs estilo cmux

**Antes:** limpar tmux-prefix hardcoded em `TerminalApp/SoyehtMac/SoyehtInstance/MacOSWebSocketTerminalView.swift:483`. Atalhos `⌘⇧|` e `⌘⇧-` devem operar sobre **layout do workspace**, não mandar prefix pro tmux.

**Depois:** `NSSplitViewController` recursivo ou `NSTabView` em grid. Cada leaf = `WebSocketTerminalView` + `TerminalSessionModel`. Layout serializado em tree e sincado via `PUT /workspaces/:id/layout` (debounced 500ms).

iPhone não implementa layout — lista linear de conversas do workspace, swipe horizontal entre elas.

### 8.5 — Claude Teams (native)

Template:

```json
{
  "id": "claude-teams",
  "name": "Claude Code Teams",
  "type": "team",
  "communication_mode": "native",
  "spec": {
    "conversations": [
      { "role": "lead", "agent_kind": "claude", "args": ["--team-lead"], "layout_hint": "left-full" },
      { "role": "sub",  "agent_kind": "claude", "args": ["--subagent"], "dynamic": true, "layout_hint": "right-stack" }
    ],
    "sidebar": { "endpoint": "/workspaces/:id/claude-teams-state" }
  }
}
```

Server instancia criando N conversas no mesmo workspace. Sidebar é um endpoint que lê estado do team (se o CLI do Claude expuser; senão parse básico dos últimos bytes do capture-pane).

### 8.6 — KVS como push layer (opcional)

Agora adiciona iCloud KVS:
- Key `activeConversations` = JSON array compacto (id, agent_icon, last_activity, workspace_id, commander)
- Key `workspaces` = JSON array
- Cliente escreve ao criar/fechar; observa `didChangeExternallyNotification` pra update imediato sem fetch.

Valor real: abrir iPhone com app cold → lista renderiza instantânea antes do REST responder.

### Critério de aceite Fase 2

- ✅ US-6 funcional (Mixed Review Claude + Codex via broker manual: botão "Enviar pra @reviewer")
- ✅ US-7 funcional (N Claudes + shell panes no mesmo workspace Mac)
- ✅ Mac: tabs/panes em grid, layout persiste no server, iPhone vê os mesmos panes como lista linear
- ✅ Claude Teams template cria 1+N conversas com sidebar mostrando metadata
- ✅ Mentions `@name` funcionam em qualquer workspace broker
- ✅ iPhone app cold-start com lista cacheada em <500ms

**Estimativa:** ~3 semanas.

## 9. Fase 3 — Worktrees, drawer, GH integration, otimizações

### 9.1 — Worktrees (US-8)

Endpoints:
```
POST   /worktrees          { repo, branch, base, create_branch }
GET    /worktrees?repo=X
DELETE /worktrees/:id      { keep_branch }
GET    /conversations/:id/git
```

Path default: `~/soyeht-worktrees/<repo-slug>/<branch-slug>/`.

UI Mac: palette `⌘⇧P` → "Workspace paralelo" → escolhe repo + checkbox branches. Server cria worktrees em paralelo + spawna agente em cada.

Sidebar git por pane: branch, dirty, ahead/behind, botões commit/diff/merge.

### 9.2 — Shared drawer

Workspace tem volume `/workspace/scratch/` compartilhado entre tmux sessions. Implementa via bind mount ou symlink. UI drawer lateral pra editar notas, upload arquivos.

### 9.3 — GitHub integration

`gh` CLI no servidor; cliente invoca via endpoints:
- Criar PR da branch atual
- Listar PRs abertos
- Comentar em PR
- Merge

### 9.4 — Transcript adapters (outros agentes)

- `codex_jsonl` (quando Codex CLI expuser transcript)
- `openclaw_yaml` (spec a definir)
- `hermes_*` (idem)

### 9.5 — tmux `-C` control mode (se medição justificar)

Só se logs de produção mostrarem custo de capture-pane sendo gargalo. Caso contrário, ring buffer basta.

## 10. Pontos abertos

1. **Preview na lista de conversas** — MVP mostra só "há X min"; preview de última mensagem vem em Fase 2 via TranscriptAdapter. OK?
2. **Autenticação multi-server** — hoje `SessionStore` já gerencia isso; conversas herdam server. Confirmar que novos endpoints usam mesmo auth middleware.
3. **Retenção de conversas encerradas** — tmux session morreu + transcript salvo: quanto tempo mantemos a linha em `conversations`? Proposta: 30 dias ou quota.
4. **Rate limit de `inject-input`** — prevenir loop infinito de mentions (@A manda pra @B que manda pra @A). Proposta: dedupe por texto + rate limit por conversa.
5. **Detecção automática de "plano pronto pra review"** (US-6 auto) — fica explicitamente fora do MVP; voltar na Fase 2 com heurística.
6. **Versão do tmux no servidor** — `window-size latest` exige tmux ≥ 2.9. Validar servers de produção.

## 11. Arquivos a criar / modificar

### Cliente (Fase 0)
- `Packages/SoyehtCore/Sources/SoyehtCore/Terminal/TerminalSessionModel.swift` (novo)
- `Sources/SwiftTerm/iOS/iOSTerminalView.swift` (annotations + remover altBufferScrollPan)
- `TerminalApp/Soyeht/WebSocketTerminalView.swift` (annotations + remover forwards tmux + usar model)
- `TerminalApp/Soyeht/TerminalHostViewController.swift` (annotations + weak captures)
- `Packages/SoyehtCore/Sources/SoyehtCore/Store/SessionStore.swift` (activeConversations, activeCommanders)

### Cliente (Fase 1)
- `TerminalApp/Soyeht/Conversations/ConversationsListView.swift` (novo)
- `TerminalApp/Soyeht/Conversations/NewConversationSheet.swift` (novo)
- `TerminalApp/Soyeht/Conversations/CommanderBanner.swift` (novo)
- `TerminalApp/SoyehtMac/SoyehtInstance/ConversationsSidebarView.swift` (novo)
- `TerminalApp/Soyeht/SoyehtAPIClient.swift` (novos métodos: listConversations, createConversation, claimCommander, etc.)

### Servidor (Fase 1)
- Schema migration: tabela `conversations`
- Endpoints REST listados em §7.2
- WS streaming com seq + broadcast events (§7.3, §7.4)
- Commander gate (§7.5)
- Templates JSON (§7.8)
- Config tmux (§7.9)

## 12. Ordem de execução

1. **Fase 0** (3 dias) → refactor + build verde + TSan clean
2. **Fase 1 server** (4 dias) → schema + REST + WS + ring buffer + commander gate
3. **Fase 1 cliente iOS** (4 dias) → lista + attach + mirror/commander + reconnect
4. **Fase 1 cliente Mac** (2 dias) → publicar conversa + banner receiver + sidebar lista
5. **Fase 1 integração** (1 dia) → testes ping-pong Mac↔iPhone, polish
6. **Fase 2** → planejamento separado após MVP rodar.

---

## Referências

- Plano v1 (antecessor): `docs/terminal-without-tmux-plan.md`
- Contrato tmux sessions atual: `docs/api-contract-tmux-sessions.md`
- Audits usados neste plano: `axiom:concurrency-validator`, `axiom:swiftui-architecture-auditor`
- cmux (referência de UX de panes): https://github.com/gsans/cmux (se aplicável)
