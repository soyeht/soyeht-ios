# Workspace + Pane Lifecycle — 2026-04-18

Validação dos cases críticos após 14 commits de refactor arquitetural
(Fase A–C + gesture fixes + Keychain DP migration).

Build: `a985e7f` + subsequent gesture/keychain fixes at HEAD.
iPhone <qa-device>: não testado neste run (foco era Mac).

## Resultados — 8 de 24 cases executados automaticamente via synthetic click

| ID | Case | Status | Notas |
|----|------|--------|-------|
| ST-Q-WPL-003 | Trocar entre workspaces via menu preserva sessões | **PASS** | Menu Workspaces, posicional "Workspace N" |
| ST-Q-WPL-004 | × do tab ativo → confirmation → workspace removida, adjacente ativa | **PASS** | [wpl-final-state.png](wpl-final-state.png) |
| ST-Q-WPL-005 | Único workspace: × não deve aparecer na tab | **PASS** | Após fechar todas menos 1, guard `isOnlyWorkspace` oculta o × |
| ST-Q-WPL-006 | Botão × existe em tab (discoverability) | **PASS** | Sempre visível na tab ativa, hover nas outras |
| ST-Q-WPL-009 | Click `\|` em pane com @shell → split vertical | **PASS** | Badge conta sobe, novo pane aparece direita |
| ST-Q-WPL-010 | Click `—` em pane com @shell → split horizontal | **PASS** | Pane novo abaixo do original |
| ST-Q-WPL-011 | Click X em pane específico → fecha esse pane, outros sobrevivem | **PASS** | @shell fechou, 3 empty panes restantes |
| ST-Q-WPL-013 | Último pane do workspace (com outros) → alert "Close workspace X?" | **PASS** | Cascade completo: closeFocusedPane → onWouldCloseLastPane → container.onWorkspaceWantsToClose → closeWorkspace(id:) |
| ST-Q-WPL-013 | Último pane + único workspace → NSSound.beep, NADA fecha | **PASS** | [wpl-013-single-workspace-beep.png](wpl-013-single-workspace-beep.png) |

## O que motivou o refactor (confirmado resolvido)

Reclamação original do usuário:
> "alguns locais funcionam outros não … fechar o último pane fechou minha janela"

Root causes fixadas:
- **RC1** (double-wire do header): `PaneGridController.wireHeaderActions` reescrevia callbacks capturando `id` de laço, podia apontar pra cache stale. Agora fonte única em `PaneViewController.wireHeaderActions` via `dispatchToGrid`.
- **RC3** (close fecha janela): `closePaneOrWindow` conflava close-pane/close-workspace/close-window. Agora `closeFocusedPane` + callback `onWouldCloseLastPane` explícito.
- **RC2** (drift `conversations` vs `layout.leafIDs`): novo `Workspace.make` factory + `WorkspaceStore.setLayout` + reconcile em `load`. Drift eliminado tanto na criação quanto na mutação.
- **RC4** (sem × visível): botão × sempre na tab ativa, hover nas outras, oculto quando é o único workspace.
- **RC5** (count colado no nome): badge com bg/border separada, fonte `layout.leafCount` (panes reais).
- **Bug bônus gesture swallow**: `NSClickGestureRecognizer` do parent engolia clicks dos botões filhos. Delegate rejeita quando hit lande em NSButton.
- **Bug bônus Keychain prompt**: migração pro Data Protection Keychain escopa items pelo bundle, elimina prompt em rebuilds.

## Não cobertos automaticamente (e por quê)

- **ST-Q-WPL-001/002** criação via `+`: testados implicitamente (novos workspaces apareceram quando disparados).
- **ST-Q-WPL-007** rename via right-click: requer digitar no NSTextField modal; não crítico agora.
- **ST-Q-WPL-008** quit + relaunch restore: relaunchei ≥6× durante os fixes. Workspaces e layouts restauram visualmente. Sessões `.mirror` sem iPhone conectado viram "no session" (esperado — placeholder aguardando presence).
- **ST-Q-WPL-015/016** sequências complexas split/close: cobertas no nível `PaneNode` pelos testes unit adicionados em Fase C.
- **ST-Q-WPL-017** click no corpo do terminal migra foco: requer verificação visual fina; não testado.
- **ST-Q-WPL-018..020** QR / Open-on-iPhone: QR foi validado em runs anteriores (paired-macs-flow); Open-on-iPhone precisa iPhone conectado.
- **ST-Q-WPL-021..024** integridade cross-workspace: requer entrada de teclado no terminal, limitação conhecida do SwiftTerm via Appium/MCP.

## TCC "Documents folder" prompt

O prompt "Soyeht would like to access files in your Documents folder" aparece
no dev rebuild (macOS TCC invalida grants quando signature muda). **Não foi
fixado** porque a tentativa de estabilizar signing via `CODE_SIGN_IDENTITY =
"Apple Development"` falha — a máquina não tem o cert do team `<MAC_TEAM_ID>`
(Developer account do usuário). Fix definitivo requer:

```
# No Xcode, com o Developer account logado:
# Build Settings → Debug → Code Signing Identity → Apple Development
# DEVELOPMENT_TEAM já está correto
```

Em produção (cert único de Developer ID ou App Store) o prompt não aparece.

## Arquivos de evidência

- `wpl-final-state.png` — state final após WPL-004 (tab `Workspace 3` removida, Default ativa).
- `wpl-013-single-workspace-beep.png` — único workspace com @shell-2 vivo após tentativa de X no pane (beep silencioso, nada fechou).

## Cross-workspace split consistency — exhaustive check

Motivado pelo feedback original "funciona em uns, não em outros",
executei `|` + `—` em **todos os 4 workspaces criados** (Default,
Workspace 2, Workspace 3, Workspace 4), via AX click:

| Workspace | Inicial | Após bash | Após `\|` | Após `—` | Resultado |
|-----------|---------|-----------|-----------|----------|-----------|
| Default      | 1 (empty) | 1 (@shell) | 2 | 3 | PASS |
| Workspace 2  | 1 (empty) | 1 (@shell) | 2 | 3 | PASS |
| Workspace 3  | 1 (empty) | 1 (@shell) | 2 | 3 | PASS |
| Workspace 4  | 1 (empty) | 1 (@shell) | 2 | 3 | PASS |

AX hit count foi `1` em cada click (1 botão encontrado + clicado),
confirmando que o mesmo path funciona em TODOS os workspaces. Zero
inconsistência pós-refactor.

Evidência: [wpl-cross-workspace-split.png](wpl-cross-workspace-split.png)
