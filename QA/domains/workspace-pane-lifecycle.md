---
id: workspace-pane-lifecycle
ids: ST-Q-WPL-001..058
profile: standard
automation: assisted
requires_device: false
requires_backend: mac
destructive: false
cleanup_required: false
---

# macOS Workspace + Pane Lifecycle

## Objetivo

Mapear todos os caminhos de abertura, fechamento, split, foco e navegação
de workspaces e panes no Mac app, e validar que cada botão faz exatamente
o que o rótulo promete. A hipótese do usuário é que a arquitetura atual
tem inconsistências onde **o mesmo botão se comporta diferente em lugares
diferentes** — este domínio existe pra confirmar quais caminhos estão
quebrados antes de decidir o refactor.

## Contexto de arquitetura

```
WorkspaceStore ─(notif)─► SoyehtMainWindowController
                           └── containerCache[id] → WorkspaceContainerViewController
                                                     └── PaneGridController
                                                           └── PaneSplitFactory.cache[id]
                                                                 └── PaneViewController(+ header)
```

Dois pontos que escrevem nos callbacks do header (`onSplitVerticalTapped`,
`onCloseTapped`, …):

1. `PaneViewController.wireHeaderActions` (em `viewDidLoad`): chama
   `dispatchToGrid { … }` que faz `grid.paneDidBecomeFocused(conversationID)`
   antes da ação.
2. `PaneGridController.wireHeaderActions` (após cada `reconcile`): **reescreve**
   os callbacks de todos os panes em `factory.cache`, capturando `id` do laço
   `for (id, pane) in factory.cache`.

O overwrite (2) é o caminho efetivo em produção. Se a cache contiver entradas
stale, o `id` capturado aponta pra pane que não existe mais na árvore →
comportamento incorreto.

## Risco

- `PaneGridController.closePaneOrWindow` chama `view.window?.performClose(nil)`
  quando `tree.leafCount <= 1`, **fechando a janela inteira** em vez de
  transicionar o workspace pra empty-state.
- `PaneSplitFactory.cache` é purgada por diff entre `retained` (leaves da
  nova árvore) e `cache.keys`, mas se um split falhar no meio (malformed
  node, race), a cache e a árvore podem ficar fora de sincronia.
- Contador de panes na tab (`"Default 3"`, `"Workspace 2 1"`) é renderizado
  grudado no nome, fácil de confundir como parte do nome.
- Não há botão X pra fechar workspace — só via right-click no tab.
  Discoverability zero.

## Preconditions

- Mac app rodando, pelo menos 1 workspace com 1 pane ativo.
- Logs visíveis: `log stream --predicate 'subsystem == "com.soyeht.mac" AND
  (category == "pane.grid" OR category == "pane.reconcile" OR category ==
  "workspace.container")'`.

## Test Cases

### Grupo WS — Workspaces

| ID | Passo | Expected | Severidade |
|----|-------|----------|-----------|
| ST-Q-WPL-001 | Clicar `+` no titlebar | Novo workspace "Workspace N" aparece, ativo, com 1 pane vazio em select-agent | P1 |
| ST-Q-WPL-002 | Criar 4 workspaces seguidos | 4 tabs na ordem de criação, última ativa, sem dupes | P1 |
| ST-Q-WPL-003 | Clicar uma tab inativa | Workspace ativa alterna, conteúdo troca, sessão anterior preservada em background (shell não morre) | P0 |
| ST-Q-WPL-004 | Right-click numa tab → Close Workspace | Tab sumiu, próxima ativa, arquivo de persistência atualizado | P1 |
| ST-Q-WPL-005 | Right-click na única tab → Close Workspace | Item "Close Workspace" desabilitado (guard no menu) | P2 |
| ST-Q-WPL-006 | **Procurar um botão X explícito na tab** | Botão X visível (ativo: sempre; inativo: hover; única tab: oculto). **CORRIGIDO** | P2 |
| ST-Q-WPL-007 | Right-click → Rename, digitar novo nome | Nome da tab atualiza, persistência atualizada, sessões intactas | P2 |
| ST-Q-WPL-008 | Quit app (`cmd+Q`), reabrir | Todos workspaces restaurados na ordem, panes com conteúdo preservado ou placeholder | P1 |

### Grupo PN — Panes dentro de um workspace

| ID | Passo | Expected | Severidade |
|----|-------|----------|-----------|
| ST-Q-WPL-009 | Num workspace com 1 pane shell, clicar `\|` no header | Split vertical: pane original à esquerda, pane vazio (select-agent) à direita | P0 |
| ST-Q-WPL-010 | Clicar `—` no pane inferior de uma split horizontal | Split vira 3 linhas, novo pane abaixo do que tinha o botão | P0 |
| ST-Q-WPL-011 | Num split de 2, clicar X no pane **direito** | Apenas o pane direito fecha, esquerdo fica com o espaço todo, sessão esquerda viva | P0 |
| ST-Q-WPL-012 | Num split de 2, clicar X no pane **esquerdo** | Apenas o pane esquerdo fecha, direito fica com o espaço todo, sessão direita viva | P0 |
| ST-Q-WPL-013 | Num workspace com 1 único pane, clicar X | Pane fecha e workspace volta pra empty-state (`select agent`). **Janela NÃO fecha** | P0 |
| ST-Q-WPL-014 | Num workspace com 1 único pane, clicar X com **múltiplas workspaces** existindo | Pane fecha → workspace vira empty-state, tab continua ativa, janela continua aberta | P0 |
| ST-Q-WPL-015 | Split, depois split do novo, depois close do do meio | Árvore reduz pra 2 leafs restantes, ambos sobreviventes mantêm sessão | P1 |
| ST-Q-WPL-016 | Sequência: split \| → split — no novo → close X no original | Árvore fica só com os 2 novos, no layout correto | P1 |
| ST-Q-WPL-017 | Clicar no corpo do terminal de um pane não-focado | Foco muda pra aquele pane (borda verde migra), first responder também | P1 |
| ST-Q-WPL-018 | Clicar em QR (`qrcode`) num pane focado | Popover de QR abre com o deep link correto | P1 |
| ST-Q-WPL-019 | Clicar em QR num pane **não**-focado | Foco migra pro pane clicado E popover abre com QR desse pane | P1 |
| ST-Q-WPL-020 | Clicar em "Open on iPhone" sem iPhone pareado conectado | Alert "Nenhum iPhone conectado" | P2 |

### Grupo IN — Integridade cross-workspace

| ID | Passo | Expected | Severidade |
|----|-------|----------|-----------|
| ST-Q-WPL-021 | Workspace A com shell em execução, trocar pra B, voltar pra A | Shell ainda rodando, scrollback intacto, WS (se mirror) ainda aberta | P0 |
| ST-Q-WPL-022 | Workspace A com shell, split em A, trocar pra B, voltar pra A | Split permanece, sessão intacta | P1 |
| ST-Q-WPL-023 | Dois workspaces com o mesmo agent (ex: shell) | IDs de conversation diferentes, sessões independentes (digitar em A não afeta B) | P1 |
| ST-Q-WPL-024 | Fechar workspace B enquanto A está ativa, abrir C | C aparece, A continua ativa, tab de B some | P1 |

### Grupo FP — Fase 1 (Foundations & Quick Wins, 2026-04-19)

Cobre o refactor de persistência dual-store + activePaneID + rename pane + drag de divisória + schema v2/version-guard. Rodar depois de reset de `~/Library/Application Support/Soyeht/workspaces.json` para estado limpo.

| ID | Passo | Expected | Severidade |
|----|-------|----------|-----------|
| ST-Q-WPL-025 | Workspace com 2 panes, focar o pane direito, `cmd+Q`, reabrir, clicar na tab do workspace | Pane direito volta a ser o focado (borda + first-responder). Boot inicial abre no primeiro workspace ordenado — foco dentro do workspace é preservado ao revisitar | P1 |
| ST-Q-WPL-026 | 2 workspaces, focar pane direito em A, ir pra B, voltar pra A | Pane direito de A ainda focado (revisita de container cacheado também re-foca) | P1 |
| ST-Q-WPL-027 | Right-click no header de um pane, `Rename…`, digitar `meunome`, OK | Handle do pane vira `@meunome`. Persiste em `~/Library/Application Support/Soyeht/workspaces.json` sob `conversations[]` (snapshot v3) | P2 |
| ST-Q-WPL-028 | Rename pane usando handle já existente no mesmo workspace | Handle aplicado vira `@nome-2` (auto-suffix). Sem erro, sem crash | P2 |
| ST-Q-WPL-029 | Split vertical, arrastar divisória pra ~30/70, `cmd+Q`, reabrir | Divisória restaurada em ~30/70 (delegate NSSplitView capturou o user drag e persistiu via `settingRatio(atPath:)`) | P1 |
| ST-Q-WPL-030 | Inspecionar `~/Library/Application Support/Soyeht/workspaces.json` após uma mudança | `"version": 3`, array `conversations` populado com handles/agents/commander — ConversationStore agora persiste via bridge, não só in-memory | P1 |
| ST-Q-WPL-031 | Editar o JSON manualmente trocando `"version": 99` (version futuro), relaunch | Arquivo original renomeado para `workspaces.json.bak-<unixts>`, app abre com workspace Default reseed. Log visível em `os_log` subsistema `com.soyeht.mac` | P1 |
| ST-Q-WPL-032 | Corromper o JSON (inserir `{{{}`), relaunch | Mesmo backup + reseed path. App não crasha nem silencia dados legais | P1 |

### Grupo UX — Fase 2 (UX Features, 2026-04-19)

Cobre drag de tab, drag de pane entre workspaces, undo, zoom, swap/rotate, multi-select.

| ID | Passo | Expected | Severidade |
|----|-------|----------|-----------|
| ST-Q-WPL-033 | Criar 3 workspaces A, B, C. Com A ativa, rodar `Workspaces > Move Active Workspace Right` duas vezes (`⌃⌘]` / `⌃⌘]`) | Ordem visual vira B, C, A. `order` no JSON reflete a nova posição. Teste de **shortcut** isolado — drag de mouse é WPL-056 | P1 |
| ST-Q-WPL-034 | Arrastar tab pra posição inválida (fora da barra) | Drag volta sem mudança. Se o gesto escalar para window-drag do macOS, o app cancela o reorder. Sem crash | P2 |
| ST-Q-WPL-035 | Pane em workspace A com agent/commander. Arrastar o header do pane e soltar na tab do workspace B | Pane some de A, aparece em B. Handle preservado (auto-suffix se colisão em B). Workspace B ativa | P1 |
| ST-Q-WPL-036 | Arrastar pane para a tab do próprio workspace | No-op, sem beep | P2 |
| ST-Q-WPL-037 | Arrastar o único pane de um workspace | Rejeita (beep). Workspace origem continua intacto | P1 |
| ST-Q-WPL-038 | Fechar um pane (split com 2 → 1). ⌘Z | Pane fechado volta à árvore, Conversation restaurada | P1 |
| ST-Q-WPL-039 | Fechar um workspace com ⌘⇧W, depois ⌘Z | Workspace reinserido na posição original, conversations restauradas, active workspace pula pra ele | P1 |
| ST-Q-WPL-040 | Fechar pane, ⌘Z (undo), ⌘⇧Z (redo) | Redo fecha o pane novamente. Toggle clean | P2 |
| ST-Q-WPL-041 | Arrastar divisória de um split. Conferir se ⌘Z volta | Ratio change NÃO é undo-registered (alto volume). ⌘Z só desfaz ops estruturais | P2 |
| ST-Q-WPL-042 | Workspace com 2 panes. Focar pane direito. ⌘⇧Z | Pane direito fullscreen, outro pane oculto mas vivo. ⌘⇧Z de novo restaura layout. Session do pane oculto intacta | P1 |
| ST-Q-WPL-043 | No zoom, pressionar Esc | Sai do zoom | P2 |
| ST-Q-WPL-044 | Split 3 panes. Focar um. ⌥⇧→ (ou similar) | Swap com vizinho direita; foco segue o pane swapped | P2 |
| ST-Q-WPL-045 | Split vertical com 2 panes. Focar um. ⌥⇧R | Split vira horizontal (axis rotated); conteúdo dos panes preservado | P2 |
| ST-Q-WPL-046 | Criar 4 workspaces. Click na tab 1, ⌘-click nas tabs 3 e 4. Right-click em uma delas | Menu mostra "Close 3 Workspaces". Confirmar → todas fecham, ordem restante mantida. Active escolhe uma remanescente | P1 |

### Grupo CP — Fase 3 (Command palette + Grouping, 2026-04-19)

| ID | Passo | Expected | Severidade |
|----|-------|----------|-----------|
| ST-Q-WPL-047 | `⌘P` (ou View → Go to Pane…) | Abre palette flutuante com lista de workspaces + conversations | P1 |
| ST-Q-WPL-048 | Digitar uma letra na palette | Lista filtra por substring (primary ou secondary); primeiro match selecionado | P1 |
| ST-Q-WPL-049 | Setas ↑↓ na palette, Enter em workspace | Workspace ativa, palette fecha | P1 |
| ST-Q-WPL-050 | Enter em uma conversation | Workspace da conversation ativa + pane focado. Equivalente ao sidebar click | P1 |
| ST-Q-WPL-051 | Esc na palette | Fecha sem ação | P2 |
| ST-Q-WPL-052 | Right-click numa tab → Group ▸ New Group… | Prompt de nome; após OK, novo group criado e workspace atribuída | P2 |
| ST-Q-WPL-053 | Em outra tab, Group ▸ <nome-criado> | Tab reatribuída ao group existente (checkmark na row) | P2 |
| ST-Q-WPL-054 | Tab com grupo atribuído → Group ▸ None | Tab vira ungrouped (checkmark volta pra "None") | P2 |
| ST-Q-WPL-055 | Criar group, atribuir workspace, `⌘Q`, reabrir | Snapshot v3: group e membership persistiram em workspaces.json | P1 |

### Grupo MS — Mouse drag (Fase 4.1, 2026-04-20)

Cobre o caminho de drag de mouse real em tabs (complementa WPL-033 que é
só shortcut). Antes de 2026-04-20 esse caminho não tinha feedback visual
e falhava silenciosamente quando o drop caía fora da área exata de um tab.

| ID | Passo | Expected | Severidade |
|----|-------|----------|-----------|
| ST-Q-WPL-056 | Criar 3 workspaces A, B, C. Clicar e arrastar a tab A com mouse/trackpad para depois de C | Durante o drag, tab A fica com opacity ~0.92 e z-acima das outras; B/C se deslocam para abrir espaço conforme A é arrastado. Ao soltar, ordem final B, C, A. `order` no JSON reflete a nova posição | P1 |
| ST-Q-WPL-057 | Clicar e arrastar a tab A passando por cima de B e depois voltar para origem | A acompanha o cursor visualmente (lifted); B desloca quando A passa pelo midpoint; voltando à origem, B volta ao lugar. Sem `order` mudado se o drop for na origem | P2 |
| ST-Q-WPL-058 | Clicar e arrastar a tab A e soltar **fora** da barra de tabs (e.g. 100pt abaixo) | A última posição válida durante o drag é mantida (live reorder já aplicou). Sem crash. Lifted state é limpo ao soltar | P2 |

## Hipóteses de root-cause (para bugs que o usuário observa)

### H1 — Botão não dispara em alguns panes ✅ CORRIGIDO
**Sintoma**: clicar `\|` ou `—` em certos panes não faz nada. Em outros funciona.
**Causa**: `PaneGridController.wireHeaderActions` reescrevia callbacks com `id`
capturado do laço sobre `factory.cache`, podendo ter entradas stale.
**Fix**: `wireHeaderActions` agora só define `onFocusRequested`; split/close
são ownershipados pelo próprio `PaneViewController` via `dispatchToGrid`.
`assertCacheMatchesTree()` valida invariant após cada reconcile (DEBUG).

### H2 — Close fecha pane errado
**Sintoma**: clicar X num pane fecha outro (geralmente o que estava focado
antes).
**Hipótese A**: o overwrite em (2) roda depois de `viewDidLoad` de (1),
mas se o PaneViewController for reusado de uma cache antiga (outro workspace),
seu `conversationID` pode estar correto mas `grid.focusedPaneID` ainda
aponta pra pane antigo — e o closure rewire (2) usa `id` **do laço**, não
o conversation ID real do pane. Se o laço iterou em ordem hash, `id` pode
não ser o esperado.
**Hipótese B**: corrida entre `storeChanged → setTree` e o click — enquanto
o tree está sendo substituído, botão dispara close contra tree antigo.
**Repro proposto**: ver ST-Q-WPL-011 e ST-Q-WPL-012 em workspace com 2 panes;
se qualquer falhar, mede.

### H3 — Last pane close fecha janela ✅ CORRIGIDO
**Sintoma**: fechar o único pane fecha a janela.
**Fix**: `closeFocusedPane` agora dispara `onWouldCloseLastPane` →
`closeWorkspace` (com confirmação se múltiplos workspaces) ou beep (workspace
único). `view.window?.performClose(nil)` removido do caminho.

### H4 — Ausência de botão close no tab ✅ CORRIGIDO
**Fix**: `WorkspaceTabView` renderiza botão X (visível em hover para tabs
inativas, sempre visível para a tab ativa, oculto quando única tab).

### H5 — Contador na tab confuso
**Causa confirmada**: `tab.setCount(3)` renderiza `"3"` grudado no título
sem separador visual. Solução: pill com bg/border separado, ou padding
explícito.

## Proposta de refactor (se hipóteses confirmarem)

### Fase A (low-risk, arrumam H3–H5 sem mexer no modelo)

1. **Close workspace button** na `WorkspaceTabView`: `✕` aparece no hover,
   clica → `onCloseWorkspace?(id)` (o callback já existe).
2. **Separar count do título** na tab: wrap em `NSTextField` com bg/border,
   ou usar Typography separada.
3. **Split close-pane vs close-workspace vs close-window** em
   `PaneGridController`:
   - Adicionar `onLastPaneClosedInWorkspace: (() -> Void)?`.
   - Remover `view.window?.performClose(nil)` do caminho.
   - Main window decide: se é o único workspace → empty state; senão →
     fecha só o workspace.

### Fase B (estrutural, arrumam H1–H2)

1. **Dropar o overwrite em `PaneGridController.wireHeaderActions`**. Deixar
   a `PaneViewController` ser dona dos seus próprios callbacks via
   `dispatchToGrid` (que já faz focus-then-action corretamente).
2. **Tornar `factory.cache` imutável entre reconciles**: construir uma nova
   cache no `build`, descartar a anterior só no fim. Hoje a cache é mutada
   durante o build, o que pode deixar PaneVCs órfãos se build lança.
3. **Asserção no teste**: após qualquer sequência de split/close, todas as
   leaves em `tree.leafIDs` têm entry em `factory.cache`, e cache não tem
   entries fora de `tree.leafIDs`. Roda depois de cada mutate.

### Fase C (long-term, model change)

Considerar migrar de **callback-based wiring** pra **action pattern**:
cada header emite `.split(from: conversationID, axis: .vertical)`, que o
grid consome via switch. Sem closures com `id` capturado → impossível de
ter `id` stale.

## Runner & evidências

**Primeiro ciclo**: passos 001-024 executados manualmente com screenshots
em `QA/runs/<date>-workspace-pane-lifecycle/`. Tela por caso. Anota qual
passou / qual falhou / qual não-aplicável.

**Depois**: automatizar os caminhos reproduzíveis via AppleScript (as
MCP synthetic clicks falham contra NSButtons nessa hierarquia — ver notas
no runner de paired-macs).

## Fora de escopo

- Comportamento de drag & drop de panes entre workspaces (feature futura).
- Atalhos de teclado para split/close (depois de estabilizar a base).
