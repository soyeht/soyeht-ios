# Persistent Panes — "o trabalho nunca se perde" (plano de implementação UX)

**Status:** proposta / pré-implementação (2026-07-22). Investigação por 4 agents de exploração; todos os `file:line` verificados contra a `main` (commit da mac-v0.1.30).

## Princípio-norte
> **A conversa é sagrada. O usuário nunca a perde por uma ação de _janela_.**

Uma conversa de agente é o ativo caro (contexto longo, trabalho em andamento). A régua de satisfação é uma só: o usuário **nunca deve pensar "será que perdi meu trabalho?"**. Fechar janela, minimizar, quit, atualizar, crash — tudo recuperável. A **única** ação que encerra uma conversa é o usuário dizer explicitamente "encerra esta" — e mesmo essa com rede de segurança (undo/histórico). Filosofia: **undo > confirmação** (confirmação é atrito repetido; undo é reversível sem fricção). Modelo mental já conhecido pelo usuário: **tmux** (detach/attach; nada morre até `kill`) e **browser** (⌘⇧T reabre o que fechou).

### A linha que define o escopo: *reconectar* (sólido) vs *ressuscitar* (capenga)
Há duas mecânicas MUITO diferentes escondidas na ideia de "recuperar":

- **Reconectar (reattach)** — o processo **continua vivo** no engine; o app só religa o pane nele. **100% confiável**, sem token, sem replay. É o que o persistent-panes já faz no restart.
- **Ressuscitar (respawn `--resume`)** — o processo **morreu**; tenta-se trazer de volta relendo o `.jsonl`. **Não-confiável por construção:** é por-agente (`claude --resume` é por-projeto e falha em cwd errado; shell/droid não têm resume), custa token e replay. "Às vezes funciona, às vezes não."

**Decisão (Caio, 2026-07-22):** o produto só entrega o que é **reconectar**. Nada de auto-ressuscitar — é onde mora a experiência quebrada. Hierarquia enxuta:

| Estado | Quando | Processo | Recupera |
|---|---|---|---|
| **Ativo** | pane visível | rodando + WS | já aberto |
| **Estacionado** | janela fechada / minimizada (W1) | **rodando**, sem WS | Dock → **reattach** instantâneo (W2) |
| **Em undo** | X do pane, janela de undo (W3) | **ainda rodando** (kill adiado) | ⌘Z → **reattach** |
| **Encerrado** | X do pane + undo expirou (W3) | morto | histórico no `.jsonl` (resume manual via CLI, se o usuário quiser) |

Ações do usuário: **fechar janela/minimizar = esconder** (estaciona, processo vivo); **X do pane / fechar workspace = encerrar** (a "tesoura" explícita, com undo). Enquanto o processo vive, tudo é reattach — sólido. O usuário só perde uma conversa quando **ele** manda encerrar e deixa o undo expirar.

> **Cortado do escopo (W4/W5):** qualquer coisa que dependa de ressuscitar um processo morto — hibernação por TTL/teto e o ⌘⇧T que respawna sessão já encerrada. Motivo: 100% construído sobre `--resume`, que é o caminho não-confiável. Processos vivos são a *feature*, não um vazamento a ser coletado; se um dia virar pressão real de recurso, o cap de sessão do engine é o backstop. Ver "Fora de escopo" abaixo.

## O gap atual (comprovado ao vivo no Soyeht Dev 0.1.30)
| Ação | Hoje | Deveria |
|---|---|---|
| 🔴 Fechar janela | Workspace vira **órfão**; ⌘N/Dock/restart abrem **fresco** | Estaciona; reabrir traz idêntico |
| Clicar no Dock (sem janela) | **Nada** | Reabre a última janela |
| ⌘Q / Atualizar | ✅ restaura (guard já existe) | (manter) |
| ❌ X do pane | **Mata o processo na hora**, sem confirm/undo | Undo + rede de segurança |
| Reabrir conversa fechada | **Impossível** (removida do store, sem tombstone) | ⌘⇧T + histórico |

## Modelo de dados relevante (o que a investigação encontrou)
- **Membership janela↔workspace** vive em 3 mapas no `WorkspaceStore` (`Store/WorkspaceStore.swift`), não no `Workspace`:
  - `workspaceOrderByWindow: [String:[Workspace.ID]]` (:78) — **autoritativo**: "workspace W está na janela X".
  - `activeByWindow: [String:Workspace.ID]` (:58) — workspace ativo por janela.
  - `windowOrder: [String]` (:81) — ordem/z das janelas.
  - `order: [Workspace.ID]` (:38) — inventário global, janela-agnóstico.
- **A causa do órfão:** `windowWillClose` (`MainWindow/SoyehtMainWindowController.swift:3880`) chama `store.clearActiveWindow(windowID:)` (:3887) que **apaga a janela dos 3 mapas** (WorkspaceStore.swift:855-861) sem deletar os `Workspace` — eles ficam em `workspaces`/`order` mas nenhuma janela os referencia. `restorableWindowSessions()` (:192-202) só enxerga janelas que ainda estão nesses mapas → a fechada some.
- **O mecanismo de preservação JÁ EXISTE**, só que exclusivo do quit: guard `isTerminatingForWindowRestoration` (SoyehtMainWindowController.swift:3882-3885) faz o `windowWillClose` **retornar sem limpar** quando o app está terminando. Por isso quit/atualizar restauram (foi o que salvou a migração de hoje). Só o **fechar-janela-explícito** orfaniza.
- **Sessões do engine sobrevivem a fechar-janela e quit** (confirmado): `windowWillClose` e `applicationWillTerminate` **nunca** chamam `endEngineSessionIfNeeded`. O `DELETE /terminals/local/{id}` (mata o processo) só é alcançado via `prepareForClose` (PaneViewController.swift:1221-1223 → :1245-1260), invocado só em: **pane close** (SoyehtMainWindowController.swift:2178), **split collapse** (PaneSplitFactory.swift:239), **workspace close** (SoyehtMainWindowController.swift:3829).
- **API pronta e não-usada:** `GET /api/v1/terminals/local` (LIST) já existe — `listLocalTerminals` (Packages/SoyehtCore/.../SoyehtAPIClient+LocalTerminals.swift:115-125) devolve todas as sessões vivas com `conversationId`, `cwd`, `pgid` e **`isConnected`**. **Sem caller de produção** (só um teste). É o building-block de "quais conversas são recuperáveis".
- **Sem tombstone:** no close, a conversa é removida inteira (`ConversationStore.remove`, ConversationStore.swift:115-119; chamada em SoyehtMainWindowController.swift:2180 e via `setLayout`→`removeConversations` WorkspaceStore.swift:759/803-805). "Fechado" e "nunca existiu" ficam indistinguíveis. Só há undo **transiente em memória** (Fase 2.3 UndoManager, WorkspaceStore.swift:762-795) que morre no quit.
- **Restauração do AppKit desligada de propósito** (`applicationSupportsSecureRestorableState → false`, AppDelegate.swift:189; `window.isRestorable = false`, SoyehtMainWindowController.swift:492) pra evitar bug de janelas duplicadas / double-register do `LivePaneRegistry`. Qualquer reabertura deve ir pelo `WorkspaceStore`, **não** pela restoration do AppKit.

---

## Workstreams (ordenados por impacto na satisfação)

### W1 — Fechar janela = **estacionar**, não orfanizar  ·  esforço **M**  ·  PR1
**Problema:** botão vermelho → `clearActiveWindow` destrói a membership → não restaura.
**Abordagem:** introduzir um bucket **persistido** de janelas fechadas-mas-restauráveis, espelhando o que o guard-de-terminação já faz de graça.
- `WorkspaceStore`: novo campo `closedWindowSessions: [ClosedWindowSession]` (windowID, [workspaceIDs], activeWorkspaceID, closedAt), capado a ~20 recentes. Novos métodos `stashClosedWindow(windowID:)`, `popClosedWindow() -> ClosedWindowSession?`, `restorableClosedWindows()`.
- `windowWillClose` (SoyehtMainWindowController.swift:3887): trocar `clearActiveWindow` por `stashClosedWindow` no caminho não-terminando (o guard `isTerminatingForWindowRestoration` continua preservando as janelas ativas no quit).
- `stashClosedWindow` **move** `workspaceOrderByWindow[windowID]` + `activeByWindow[windowID]` pro bucket e remove de `windowOrder` (a janela deixa de ser "ativa"), depois persiste. Os workspaces NÃO vazam pra janelas ativas porque saem de `workspaceOrderByWindow`.
- **Decisão de design:** fechar-janela + **restart NÃO auto-reabre** a janela fechada (senão reabriria tudo que você fechou de propósito). Ela fica no bucket, recuperável por W2/⌘⇧T. (Igual ao browser: restart restaura a sessão que estava _aberta_; o que você fechou vai pro "recently closed".)
- Schema: `Snapshot` v4→**v5** (WorkspaceStore.swift:978-987, `currentVersion` :87). Migração: v4 sem o campo → `[]` (backward-compatible; nunca falha o load).
**Riscos:** workspace do bucket deletado no meio-tempo → filtrar contra `workspaces` ao restaurar. Bucket ilimitado → cap + poda por `closedAt`.
**Testes:** unit — `stashClosedWindow`→`restorableClosedWindows` roundtrip; migração v4→v5 (carregar um workspaces.json v4 antigo); snapshot idempotente. E2E — teste-rei de janela: workspace com pane → fechar janela → `restorableClosedWindows()` contém → reabrir → mesma membership.

### W2 — Dock reopen + "Reabrir última janela"  ·  esforço **S**  ·  PR2  ·  depende de W1
**Problema:** `applicationShouldHandleReopen` não existe → clicar no Dock sem janela não faz nada.
**Abordagem:** implementar `applicationShouldHandleReopen(_:hasVisibleWindows:)` no `AppDelegate` (perto de :177):
- `hasVisibleWindows == true` → `return true` (AppKit traz à frente).
- senão → tentar `store.popClosedWindow()` (bucket do W1) e `openNewMainWindow(initialWindowID:initialWorkspaceID:)` (AppDelegate.swift:343); bucket vazio → `restoreMainWindowsOrOpenDefault()` (:368) ou `openNewMainWindow()` fresco. `return false` (nós tratamos).
- **Cuidado com o double-window bug:** esse hook é ortogonal à restoration do AppKit (que fica desligada); só reabrir via `WorkspaceStore` + checar `windowControllers` pra não duplicar.
- Bônus barato: menu **Window → Reopen Closed Window** (⌘⇧T) chamando o mesmo `popClosedWindow`.
**Riscos:** baixo. Garantir idempotência (dois reopens rápidos não abrem duas cópias).
**Testes:** unit no pop; smoke manual (fechar janela → Dock → volta).

### W3 — X do pane = **undo** (deferir o kill) + confirmação opcional  ·  esforço **L**  ·  PR3
**Problema:** o X mata o processo na hora — `endEngineSessionIfNeeded` (PaneViewController.swift:1245-1260) dispara um `Task` fire-and-forget de `deleteLocalTerminal`. O store **já tem undo** (WorkspaceStore.swift:762-795 reinsere a conversa), mas como o engine já morreu, o undo hoje produz um **pane zumbi sem sessão**.
**Abordagem:** o passo irreversível a adiar é **só o DELETE do engine**. Em vez de deletar na hora:
- `endEngineSessionIfNeeded`: mover a sessão pra um **RecentlyClosedPanes registry** (engineConversationID + slaveTTYPath + timestamp) e **agendar** o DELETE (**15 s**, ou "no próximo quit"), em vez do `Task` imediato. Preservar o mapeamento TTY (não fazer `EngineSessionTTYRegistry.remove` de imediato). Constante única/ajustável (`closeUndoWindow = 15s`).
- Fazer o **undo do store** (que já existe) também **cancelar o DELETE agendado** e reanexar: como o VC é destruído pelo factory (PaneSplitFactory.swift:242-243), o undo reconstrói via `makePane` e o reattach (`restoreEnginePaneIfNeeded`, PaneViewController.swift:698) reconecta — **funciona porque o engine não foi deletado**. Toast "Pane fechado · Desfazer".
- (Opcional, atrás de setting) Confirm-before-close para conversa viva: gate no `PaneGridController.closeFocusedPane` (:418) antes do `mutate` (:430) — funil compartilhado pelo X, pelo menu e pelo shim legado; o caminho de automação (`SoyehtMainWindowController.closePanes` :2132) **bypassa o grid**, então fica automaticamente isento (correto). A liveness já é computada em `endEngineSessionIfNeeded` (:1246-1247).
**Riscos (ALTO — respeitar os TOCTOU do código):**
1. **Split-brain**: no `mutate`, `reconcile()` (DELETE, PaneGridController.swift:525) roda **antes** de `onTreeMutated` (store+undo, :526). O deferral precisa acontecer **antes** de criar o `Task` de DELETE (fire-and-forget não é cancelável — PaneViewController.swift:1249).
2. **Ownership re-check**: antes do DELETE atrasado firar, re-checar `LivePaneRegistry.shared.pane(for:) === self` (padrão de `stillRestorableEngineConversation`, PaneViewController.swift:805) — senão pode deletar uma sessão que **um novo pane já adotou**, ou dobrar o DELETE.
3. **Engine-ID keying**: usar o `engineConversationID` guardado em `.engineLocal(conversationID:)` (Conversation.swift:17), nunca re-derivar de `Conversation.id.uuidString` (PaneViewController.swift:820-824).
**Testes:** unit no registry + agendamento/cancelamento; E2E — fechar pane com agente → undo em <15 s → mesma conversa reconecta (reconnected: true).

### W-honestidade / História 4 — reboot = agente fresco (modelo-navegador), não shell zumbi  ·  esforço **M**  ·  dobra no PR1
**O que é o `reconnected:false` de verdade** (PaneViewController.swift:763-768): o engine é idempotente por `conversation_id`; se a sessão **não existe mais** no engine, `create` devolve um **shell vazio** no mesmo id. Isso só acontece quando o engine **morreu e voltou** — i.e. **reboot do Mac / update / crash do engine** (aí *todos* os PTYs somem de uma vez; não há o que reatacar). Ou seja, esse caminho é "o que acontece depois de reiniciar o Mac", não um edge raro.
**Problema:** hoje o app deixa o shell vazio de pé **fingindo** que restaurou — mentira silenciosa (parece a conversa, é um bash em branco).
**Abordagem (modelo-navegador, decisão Caio 2026-07-22):** tratar reboot como o browser trata "reabrir abas" — cada pane de agente sobe um **agente fresco no mesmo cwd** (não um bash vazio, não um erro). O transcript antigo continua no `.jsonl`; um controle **discreto e opt-in** ("retomar conversa anterior") oferece o resume — que é o único caminho flaky, então **nunca roda sozinho**, só no clique, e degrada pra fresco se falhar ("relê a conversa, pode demorar; se não der, começa fresco").
- Implementação: no branch `reconnected:false`, em vez de aceitar o shell vazio, **relançar o comando do agente** daquele pane (mesmo caminho da criação normal de pane) no cwd certo. Shell puro (`.shell`) permanece bash fresco no cwd (comportamento esperado de terminal).
- O "retomar anterior" resolve o resume-id via o mesmo método da migração (claude: `~/.claude/projects/<proj>/<id>.jsonl`; codex: rollout) e roda `--resume`; per-agente (claude/codex sim; shell/droid não mostram o controle).
**Testes:** forçar sessão morta (matar engine) → reabrir → pane sobe agente fresco na pasta certa (não bash vazio, não erro); clicar "retomar anterior" → volta a conversa; agente sem resume → controle não aparece.

---

## Fora de escopo (cortado 2026-07-22)

**W4 (Recently Closed / Recovery via ⌘⇧T-respawn) e W5 (Hibernação + GC por TTL/teto) — NÃO serão feitos.**

Motivo: ambos dependem de **ressuscitar um processo morto** com `--resume`, que é o caminho não-confiável (per-agente, por-projeto, custa token, inexistente em shell/droid). Entregar isso seria vender "às vezes funciona, às vezes não" — o oposto do princípio-norte.

- A **metade boa** do W4 ("recuperar sessão que o engine ainda tem viva") já acontece hoje: o restart do persistent-panes faz reattach das sessões vivas. Não precisa de PR.
- O medo que o W5 resolvia ("mundaréu de órfãos vivos") **não é problema**: processos vivos são a *feature*. Se um dia virar pressão real de recurso, o **cap de sessão do engine** é o backstop — não a hibernação com respawn.
- Registro do que se aprendeu (pra não reabrir a discussão): resume é **por-agente** — claude `--resume` (por-projeto), codex `resume`, opencode `--session`/`--fork` (a confirmar), droid não testado, **shell nunca**. Como é intrinsecamente frágil, fica **fora do produto**; resume continua sendo só uma ferramenta **manual** de CLI (foi o que usamos na migração da 0.1.30).

---

## Sequência, flags, migração
1. **PR1 (W1 + W-honestidade)** — estacionar janela **e** trocar o `reconnected:false`→shell-vazio por estado honesto. Maior impacto, ação mais comum, cirúrgico. Base pro resto.
2. **PR2 (W2)** — dock reopen. Pequeno, fecha o loop de janela.
3. **PR3 (W3)** — deferir o kill + undo do pane. Protege contra o erro mais destrutivo.

Só isso. Tudo aqui é **reattach** (processo vivo) — zero `--resume`, zero flakiness. W4/W5 ficaram fora (ver "Fora de escopo").

- **Cada PR atrás de flag** (padrão do app, ex. `SoyehtFeatureFlags`), default OFF→Dev→ON como o persistent-panes.
- **Schema v4→v5** entra no PR1 e deve ser aditivo (v4 carrega com defaults). Um só bump para os campos de W1/W3.
- **Sem tocar** o caminho de automação (`closePanes`) nem o guard de terminação (já corretos).

## Riscos globais
- **Migração de schema** (v4→v5): tem que ser backward-compatible e testada com um `workspaces.json` real v4.
- **Concorrência do W3** é o ponto mais delicado — os 6 hazards de TOCTOU/lifecycle mapeados acima são load-bearing; PR3 exige revisão adversarial (é candidato natural a `/code-review ultra`).
- **Double-window** (W2): manter a restoration do AppKit desligada; reabrir só via store.

## Impacto esperado
W1+W2 tornam **a janela** redonda (nunca perde workspace por reflexo). W3 torna **o X do pane** reversível (undo enquanto o processo ainda vive). Somado ao persistent-panes já shipado (atualizar não mata), o resultado é o princípio-norte cumprido **onde ele é sólido**: enquanto o processo vive, tudo é reattach e o usuário nunca perde trabalho por uma ação de janela. A única perda possível é deliberada (encerrar + deixar o undo expirar) — e o `.jsonl` ainda permite resume manual via CLI depois disso.
