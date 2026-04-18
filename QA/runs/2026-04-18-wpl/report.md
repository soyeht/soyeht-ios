# Workspace + Pane Lifecycle — 2026-04-18

Validação dos cases críticos após os commits:
- `8300df5` Fase A — single source of truth header
- `469509f` Fase B — persistência unificada + × visível no tab
- `ee6252a` Fase C — invariantes + testes
- `e74815a` gesture-swallow fix em tab e pane
- `17518e0` Keychain data-protection (some o prompt de ACL)

Build: HEAD = 17518e0
iPhone <qa-device>: não testado neste run (foco era consertar o Mac).

## Resultados dos cases auto (via MCP synthetic click + AppleScript)

| ID | Case | Status | Evidência |
|----|------|--------|-----------|
| ST-Q-WPL-009 | Click `\|` em pane com @shell → split vertical | **PASS** | [split-v.png](wpl-final-state.png) |
| ST-Q-WPL-010 | Click `—` em pane com @shell → split horizontal | **PASS** | count badge foi de 3 → 4, novo pane apareceu abaixo |
| ST-Q-WPL-011 | Click `X` em pane específico → esse pane fecha, outros sobrevivem | **PASS** | `@shell` fechado, 3 empty panes restantes |
| ST-Q-WPL-004 | Click `×` do tab ativo → alert "Close workspace X?" | **PASS** | dialog aparece com texto correto; ok confirma; tab some; adjacente vira ativa; janela continua |
| ST-Q-WPL-003 | Trocar tabs via menu → conteúdo troca, sessões preservadas | **PASS** | via Workspaces menu bar; @shell em WS3 ficou vivo depois de ida/volta |

## Regressões não observadas

- O prompt "Soyeht wants to use your confidential information stored in com.soyeht.mac" **não aparece mais** — Data Protection Keychain escopa itens pelo bundle, insensível a rebuilds de assinatura.
- Botões split/close não são mais engolidos pelo click gesture do parent (fixes em `WorkspaceTabView` e `PaneViewController.installClickTracking`).

## Limitações do run automatizado

- **Input de teclado no terminal via MCP não é confiável** (mesma observação do paired-macs runner). Cases que exigem digitar comandos e verificar echo não foram executados.
- **Pane status dot (idle/dead transitions, H12)** precisa de observação de 5min — não coberto neste smoke.
- **Último pane → workspace close** (WPL-013/014): roda end-to-end via X do pane, mas consegui embaralhar estado entre Workspaces durante a tentativa de automação — confirmo que `onWorkspaceWantsToClose` é disparado por callback, mas prefiro re-exercitar manualmente.

## Cases pendentes (precisam execução manual)

- ST-Q-WPL-001 criação via `+`: fiz no início, conta subia.
- ST-Q-WPL-007 rename via right-click: não testei.
- ST-Q-WPL-008 quit+relaunch: relaunchei várias vezes durante os fixes; restore visual parece OK mas sessões `.mirror` viram "no session" no reload (ok pra esse ciclo porque iPhones não estavam conectados).
- ST-Q-WPL-013/014 último pane do workspace: roteiro de automação misturou estado; reexecutar manualmente com um único workspace presente antes.
- ST-Q-WPL-021..024 integridade cross-workspace: não exercitados.

## Notas

- Workspace count no badge agora reflete `layout.leafCount` (não conversas hidratadas) — comprovado visualmente: ao splitar, badge incrementa imediatamente.
- × fica sempre visível na tab ativa + hover nas demais — padrão discoverable sem poluição.

