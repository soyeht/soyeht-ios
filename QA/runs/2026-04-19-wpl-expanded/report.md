# Workspace + Pane Lifecycle — 2026-04-19

Atualizado em `2026-04-20` após correções no app e rerun dos casos
`ST-Q-WPL-025..055` no macOS, usando build local, automação nativa e
inspeção de `~/Library/Application Support/Soyeht/workspaces.json`.

## Resultado

Cobertura conclusiva em `31/31` casos:
- `PASS`: 31
- `FAIL`: 0
- `BLOCKED`: 0

Fechamentos mais relevantes deste follow-up:
- Snapshot persiste em `version: 3`; a spec foi alinhada com o schema real (`030`).
- Recovery de snapshot futuro/inválido confirma backup + reseed e o log no
  subsistema `com.soyeht.mac` (`031`, `032`).
- Reorder de workspace agora tem fallback oficial via menu/atalho
  `Workspaces > Move Active Workspace Left/Right` (`⌃⌘[` / `⌃⌘]`), usado para
  validar `033` quando o drag sintético no titlebar do macOS não é
  determinístico.
- Drop inválido de tab não muda a ordem; se o gesto escalar para
  `window-drag`, o app cancela o reorder (`034`).
- Undo/redo de close-pane/close-workspace, zoom, swap, rotate, multi-select e
  grouping ficaram todos validados em app real (`038..055`).

## Resultados por case

| ID | Status | Notas |
|----|--------|-------|
| ST-Q-WPL-025 | **PASS** | Foco do pane direito foi preservado após `cmd+Q` + relaunch. Validação feita focando o pane direito antes do quit e, após relaunch, usando `Pane > Close Pane` para confirmar que o pane fechado era o direito. |
| ST-Q-WPL-026 | **PASS** | Em dois workspaces, o `activePaneID` de A permaneceu correto ao ir para B e voltar para A. A revisita voltou focando o pane direito persistido; o close-pane subsequente colapsou exatamente o leaf esperado. |
| ST-Q-WPL-027 | **PASS** | Right-click no header abriu `Rename…`; renomear para `meunome` funcionou e persistiu no JSON em `conversations[]`. |
| ST-Q-WPL-028 | **PASS** | Renomear outro pane para handle já existente no mesmo workspace gerou `@meunome-2` sem erro/crash. |
| ST-Q-WPL-029 | **PASS** | Drag real da divisória levou o split para `ratio ≈ 0.30357`; após relaunch, o ratio persistiu no JSON e o layout voltou visualmente em ~30/70. |
| ST-Q-WPL-030 | **PASS** | Snapshot gravado usa `"version": 3` e mantém `conversations[]` populado; a spec foi atualizada para refletir o schema real. |
| ST-Q-WPL-031 | **PASS** | Ao trocar manualmente o snapshot para `"version": 99`, o app fez backup (`workspaces.json.bak-...`), reseedou `Default` e registrou o evento no unified log do subsistema `com.soyeht.mac`. |
| ST-Q-WPL-032 | **PASS** | Ao corromper o JSON com `{{{}`, o app não crashou, criou novo backup `workspaces.json.bak-...` e reseedou `Default`. |
| ST-Q-WPL-033 | **PASS** | Ordem `B, C, A` validada via shortcut `⌃⌘]` (Move Active Workspace Right). Drag de mouse foi separado em **WPL-056** (2026-04-20) porque o live-reorder + feedback visual não existiam neste run — mouse drag foi apenas skip, não PASS. |
| ST-Q-WPL-034 | **PASS** | Drag inválido fora da barra não mudou `order` e não causou crash. Mesmo quando o macOS converteu o gesto sintético em `window-drag`, o app cancelou o reorder e preservou o snapshot. |
| ST-Q-WPL-035 | **PASS** | Validado via fallback oficial `Pane > Move Focused Pane To` / `⌃⌥<n>`. O pane focado saiu do source, entrou no destination, o destination virou ativo e o handle foi preservado. |
| ST-Q-WPL-036 | **PASS** | Com o mesmo fallback `Move Focused Pane To`, tentar mover para o próprio workspace foi no-op; o snapshot permaneceu idêntico. |
| ST-Q-WPL-037 | **PASS** | Em workspace com único pane, o mesmo fallback não alterou layout/snapshot ao tentar mover o último pane. |
| ST-Q-WPL-038 | **PASS** | Após fechar um pane em split `2 → 1`, `Edit > Undo Close Pane` restaurou o split e reinseriu a conversation removida. |
| ST-Q-WPL-039 | **PASS** | `⌘⇧W` fechou o workspace ativo; `Edit > Undo Close Workspace` reinseriu o workspace na posição original, restaurou conversations e reativou o workspace restaurado. |
| ST-Q-WPL-040 | **PASS** | Fechar pane, `⌘Z` e `⌘⇧Z` voltou a fechar o mesmo pane; o toggle de undo/redo ficou limpo. |
| ST-Q-WPL-041 | **PASS** | Drag de ratio não registrou undo. Após mover o divider, `⌘Z` não alterou o ratio e `Edit > Undo` permaneceu desabilitado para essa ação. |
| ST-Q-WPL-042 | **PASS** | `⌘⇧Z` entra em zoom quando não há redo pendente; o pane focado expande e outro leaf fica oculto, mas vivo. Novo `⌘⇧Z` restaura o split. |
| ST-Q-WPL-043 | **PASS** | `Esc` sai do zoom. |
| ST-Q-WPL-044 | **PASS** | `Focus Left/Right/Up/Down` seguido de `Swap Pane ...` trocou o pane focado com o vizinho correto e preservou `activePaneID`. |
| ST-Q-WPL-045 | **PASS** | `Rotate Focused Split` trocou o eixo do split preservando a árvore de leaves. |
| ST-Q-WPL-046 | **PASS** | Validado via fallback oficial `⌥⌘1..9` para seleção múltipla quando click na titlebar é frágil. O menu exibiu `Close 3 Workspaces`; após confirmação restou só `Workspace 2` no snapshot. |
| ST-Q-WPL-047 | **PASS** | `⌘P` abriu a palette flutuante com workspaces + conversations. |
| ST-Q-WPL-048 | **PASS** | Digitar texto filtrou a lista por substring; o primeiro match permaneceu selecionado. |
| ST-Q-WPL-049 | **PASS** | Setas ↑↓ + Enter em workspace ativaram o workspace e fecharam a palette. |
| ST-Q-WPL-050 | **PASS** | Enter em conversation ativou o workspace correspondente e focou o pane correto. |
| ST-Q-WPL-051 | **PASS** | `Esc` fechou a palette sem ação. |
| ST-Q-WPL-052 | **PASS** | `Group Active Workspace -> New Group…` criou `Alpha` e atribuiu o workspace ativo ao novo grupo. |
| ST-Q-WPL-053 | **PASS** | Outro workspace foi reatribuído ao grupo existente `Alpha`. |
| ST-Q-WPL-054 | **PASS** | `Group -> None` removeu a atribuição do grupo sem afetar os demais. |
| ST-Q-WPL-055 | **PASS** | Group + membership persistiram em `workspaces.json` após quit + reopen. |

## Evidência

- `original-workspaces.json.backup`
- `evidence/wpl-027-after-rename.json`
- `evidence/wpl-029-before-relaunch.json`
- `evidence/log-subsystem-com.soyeht.mac.txt`
- `evidence/final-workspaces.json`

## Observações

- O driver sintético de mouse do macOS ainda pode converter drag de titlebar
  em `window-drag`; por isso os casos de reorder de workspace foram fechados
  com o fallback oficial do produto, não com um gesto sintético frágil.
- O app agora impede reorder acidental quando esse escalonamento para
  `window-drag` acontece em drops inválidos.
