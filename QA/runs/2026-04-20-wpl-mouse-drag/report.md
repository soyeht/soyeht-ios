# Workspace Tab Mouse Drag — 2026-04-20

Follow-up ao run de 2026-04-19 depois que o usuário reportou que **drag
de mouse em tab de workspace não funcionava**. WPL-033 rebaixado para
shortcut-only; WPL-056..058 criados para cobrir drag de mouse.

## Causa raiz REAL

O problema não era lógica de reorder — era AppKit interceptando o drag
para mover a janela inteira. A janela é criada com:

```swift
styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
```

A combinação `.titled + .fullSizeContentView` faz a faixa do titlebar (y=0
a y~28 do content view) ser uma **drag region** para o AppKit. Mouse
events nessa faixa iniciam o drag loop nativo da janela **antes** de
chegarem às views, ignorando:

- `WindowTopBarView.mouseDownCanMoveWindow = false`
- `WorkspaceTabsView.mouseDownCanMoveWindow = false`
- `WorkspaceTabView.mouseDownCanMoveWindow = false`
- `window.isMovableByWindowBackground = false`
- `window.isMovable = false` setado dentro de `mouseDown` (tarde demais)

Como consequência, o drag da tab movia a janela, e o código de reorder
(em `WorkspaceTabView.mouseDragged`) nunca rodava. Clicks funcionavam
porque existia um `titlebarClickMonitor` que fazia fallback no mouseUp.

Duas falhas secundárias encontradas durante a investigação:

1. `WorkspaceTabView.hitTest(_:)` usava `bounds.contains(point)` mas
   `point` chega em coordenadas da **superview** (não do próprio view).
   Para toda tab com `frame.origin.x ≠ 0`, hitTest retornava `nil`.
2. `applyLiveReorder` só rodava na fase `.ended` do drag customizado,
   sem feedback visual durante o movimento.

## Fix aplicado

### 1. `window.isMovable = false` (permanente)
```swift
// SoyehtMainWindowController — window builder
window.isMovable = false
```
Única forma confiável de impedir o drag loop do AppKit na faixa do
titlebar. Impacto: usuário não consegue mais arrastar a janela pelo
titlebar. Traffic lights (close/min/zoom) continuam funcionando. Para
mover a janela, usar Mission Control ou cmd-drag.

### 2. Monitor global de `.leftMouseDragged`
```swift
// SoyehtMainWindowController.installTitlebarClickFallback
NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
```
- `.leftMouseDown` em tab → claim + consume (retorna nil)
- `.leftMouseDragged` → rota para `routeTabReorderDrag(.started | .moved)` + consume
- `.leftMouseUp` → finaliza com `.ended` ou dispara click fallback

### 3. Transform-based drag (redesign para casar com Pencil s5y0b)

**Primeira tentativa** chamava `store.reorder` em cada `mouseDragged`,
o que fazia o `storeChanged` notification disparar `rebuild()` a cada
evento. Cada rebuild removia + reinseria tabs no NSStackView, causando
**flicker visível** (cores piscando, layout jumping).

**Redesign**: `store` não muda durante o drag. Só no `.ended`.

```swift
// WorkspaceTabsView — TabDragState + handleTabReorderDrag
case .started: beginTabDrag → capture originalFrames + shiftAmount, lift
case .moved:
  // 1. Dragged tab segue o cursor 1:1 via CATransaction disableActions
  //    (sem animação — lag é inaceitável para cursor-tracking)
  draggedTab.layer.setAffineTransform(CGAffineTransform(translationX: dx, y: 0))
  // 2. Compute target baseado no visual center do dragged tab vs originalFrames dos outros
  // 3. animateSiblingShifts — slides outros tabs para abrir espaço no target,
  //    animados via NSAnimationContext 0.16s easeOut
case .ended:
  // Re-run updateTabDrag com cursor final (handles sparse events)
  // Clear transforms, commit store.reorder once, animate snap-to-slot
```

O detalhe crítico de **zero jump nas siblings**: durante o drag, cada
sibling tem `transform.tx = ±shiftAmount` (ou 0). Após o `store.reorder`
na fase `.ended`, o rebuild dá a cada sibling um novo `frame` que é
exatamente `origFrame + transform`. Limpar transform para identity é
visualmente idêntico — nenhum pulo.

### 4. Lifted state match Pencil `s5y0b/nXETi`
```swift
// WorkspaceTabView.setDragLifted(true)
layer.zPosition = 100
alphaValue = 0.92
layer.shadowColor = black, opacity 0.73
layer.shadowOffset = (0, -8)
layer.shadowRadius = 24
layer.masksToBounds = false
```
Cartão flutuante com drop-shadow casando a referência do design.

### 4. hitTest corrigido
```swift
// WorkspaceTabView.hitTest
guard frame.contains(point) else { return nil }
let localPoint = convert(point, from: superview)
```
Defensive — mesmo com o monitor global interceptando tudo, o path de
view ainda existe e agora funciona corretamente.

### 5. Zonas de append e prepend
Drop à direita do último tab ou à esquerda do primeiro reordena
mesmo sem cursor exatamente sobre outro tab.

## Verificação

### Build
```
** BUILD SUCCEEDED **
```

### Unit tests
```
Executed 162 tests, with 0 failures (0 unexpected)
```

### Teste interativo via native-devtools (MCP)

| Teste | Setup | Ação | Esperado | Resultado |
|-------|-------|------|----------|-----------|
| Drag para direita | [Bravo, Alpha, Charlie], Bravo ativa | drag Bravo (x=1181) → x=1440 | [Alpha, Charlie, Bravo] | **PASS** — window origin não mudou, ordem correta |
| Drag para esquerda (reverse) | [Alpha, Charlie, Bravo] | drag Bravo (x=1415) → x=1150 | [Alpha, Bravo, Charlie] | **PASS** — window não moveu |
| Prepend zone | [Alpha, Bravo, Charlie] | drag Charlie (x=1408) → x=1100 | [Charlie, Alpha, Bravo] | **PASS** — Charlie pulou para posição 0 |
| Redesign (pós-Pencil) | [Charlie, Bravo, Alpha] Bravo ativa | drag Bravo (x=1305) → x=1550 | [Charlie, Alpha, Bravo] | **PASS** — sem flicker, snap-to-slot animado |

Antes do fix: todas as tentativas acima moviam a janela inteira
(delta drag = delta window origin) e a ordem nunca mudava.

## Observações

- O fix de `frame.contains(point)` no hitTest era necessário também
  para proteger o path de view (defensive), embora o monitor global
  agora intercepte tudo antes do AppKit.
- `window.isMovable = false` é um trade-off: usuário perde a
  affordance de arrastar a janela pelo titlebar. A alternativa seria
  refatorar para usar `NSTitlebarAccessoryViewController` — mais
  invasivo, deixado para fase futura.
- `applyLiveReorder` em `.ended` garante que mesmo com poucos eventos
  `mouseDragged` intermediários (ex.: automação sintética), o drop
  final ainda reordena. Drag real com mouse gera eventos contínuos
  e o reorder aparece progressivo.
- Event monitor consume do `.leftMouseDown` em tabs é crítico — sem
  isso, o AppKit entra no drag loop mesmo com `isMovable = false`
  setado dentro do handler (tarde demais para o loop).

## Casos QA

| ID | Foco | Status |
|----|------|--------|
| ST-Q-WPL-056 | Drag de A para depois de C via mouse | **PASS** (automação sintética) |
| ST-Q-WPL-057 | Drag e volta à origem | **PASS** (reverse drag PASS) |
| ST-Q-WPL-058 | Drop fora da barra de tabs | **PASS** (append + prepend zones validados) |
| ST-Q-WPL-059 | Drag janela pela área vazia do titlebar | **PASS** (automação: window origin mudou 100px de drag) |
| ST-Q-WPL-060 | Tab drag → window drag em sequência | **PENDING** (requer mouse real — automação sintética tem teleports) |
| ST-Q-WPL-061 | Window drag → tab drag em sequência | **PENDING** (mesmo motivo) |
| ST-Q-WPL-062 | Click/drag em tab NUNCA move janela | **PENDING** (cobre o fix de opacidade) |
| ST-Q-WPL-063 | Hover rápido sobre tabs + click área vazia | **PENDING** (cobre o `.mouseMoved` reset) |

## Fix final (após iterações nesta run)

A correção que realmente ficou:

1. **Bg opaco em `WorkspaceTabsView` e `WorkspaceTabView` inativa** (`MacTheme.surfaceBase`
   em vez de `NSColor.clear`). AppKit só honra `mouseDownCanMoveWindow=false`
   quando a view hit é opaca.
2. **`WindowTopBarView.mouseDownCanMoveWindow = true`** — área vazia do titlebar
   volta a ser drag region (user move a janela pela faixa vazia).
3. **`acceptsMouseMovedEvents = true` + monitor `.mouseMoved`** — belt-and-suspenders
   sincronizando `isMovable` com posição do cursor em tempo real (cobre
   casos de automação que saltam eventos normais).

Tentativas anteriores que NÃO ficaram (registradas como histórico):

- `window.isMovable = false` permanente → quebrou drag da janela
- Tracking area (mouseEntered/Exited) → falha em cursor-warps sintéticos
- Consume `.leftMouseDown` no monitor → AppKit já tinha decidido o drag
  (event monitor roda antes da dispatch, mas a decisão do titlebar-drag
  parece usar estado cacheado anterior)
- Setar `isMovable` dentro do handler de `.leftMouseDown` → tarde demais
