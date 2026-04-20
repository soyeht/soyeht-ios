# Workspace + Pane Lifecycle — 2026-04-20 (Automated Unit Tests)

Cobertura automatizada de `ST-Q-WPL-001..024` via `swift test`
(`TerminalApp/SoyehtMacTests/`). Adicionado `WorkspacePaneLifecycleTests.swift`
com 19 test cases. Total do pacote após adição: **162 testes, 0 falhas**.

## Resultado

| Grupo | Casos | Cobertos (auto) | PASS |
|-------|-------|-----------------|------|
| WS (001-008) | 8 | 7 (WS-006 = UX-only) | 7 |
| PN (009-020) | 12 | 9 (018-020 = UI-only) | 9 |
| IN (021-024) | 4 | 3 (021+022 merged) | 3 |
| **Total** | **24** | **19** | **19** |

Casos WS-006 (botão X na tab, verificação visual), WPL-018/019/020 (QR
popover, Open on iPhone) não são automatizáveis na camada de domínio; estão
cobertos pelo run manual de 2026-04-18.

## Casos por test

| ID QA | Método de teste | Status |
|-------|-----------------|--------|
| ST-Q-WPL-001 | `testWS001_NewWorkspaceNaming` | **PASS** |
| ST-Q-WPL-002 | `testWS002_FourWorkspacesOrdered` | **PASS** |
| ST-Q-WPL-003 | `testWS003_WorkspaceSwitchPreservesLayout` | **PASS** |
| ST-Q-WPL-004 | `testWS004_CloseWorkspaceRemovesItFromOrder` | **PASS** |
| ST-Q-WPL-005 | `testWS005_OnlyWorkspaceCloseIsDisabled` | **PASS** |
| ST-Q-WPL-006 | (visual — ver run 2026-04-18) | SKIP |
| ST-Q-WPL-007 | `testWS007_RenameWorkspace` | **PASS** |
| ST-Q-WPL-008 | `testWS008_QuitReopenRestoresWorkspaces` | **PASS** |
| ST-Q-WPL-009 | `testPN009_SplitVertical` | **PASS** |
| ST-Q-WPL-010 | `testPN010_SplitHorizontal` | **PASS** |
| ST-Q-WPL-011 | `testPN011_CloseRightPaneLeavesLeftAlive` | **PASS** |
| ST-Q-WPL-012 | `testPN012_CloseLeftPaneLeavesRightAlive` | **PASS** |
| ST-Q-WPL-013 | `testPN013_CloseLastPaneReturnsFalse_SingleWorkspace` | **PASS** |
| ST-Q-WPL-014 | `testPN014_CloseLastPaneReturnsFalse_MultipleWorkspaces` | **PASS** |
| ST-Q-WPL-015 | `testPN015_SplitSplitNewCloseMiddle` | **PASS** |
| ST-Q-WPL-016 | `testPN016_SplitSplitOriginalCloseOriginal` | **PASS** |
| ST-Q-WPL-017 | `testPN017_FocusMirroring` | **PASS** |
| ST-Q-WPL-018 | (UI/popover — fora de escopo domain) | SKIP |
| ST-Q-WPL-019 | (UI/popover — fora de escopo domain) | SKIP |
| ST-Q-WPL-020 | (UI/alert — fora de escopo domain) | SKIP |
| ST-Q-WPL-021/022 | `testIN021_022_CrossWorkspaceLayoutIntegrity` | **PASS** |
| ST-Q-WPL-023 | `testIN023_SameAgentInTwoWorkspacesIsIndependent` | **PASS** |
| ST-Q-WPL-024 | `testIN024_CloseBWhileAActivePreservesA` | **PASS** |

## Saída do runner

```
Test Suite 'WorkspacePaneLifecycleTests' passed at 2026-04-20 09:01:20.048.
  Executed 19 tests, with 0 failures (0 unexpected) in 0.009 seconds
Test Suite 'All tests' passed at 2026-04-20 09:01:20.
  Executed 162 tests, with 0 failures (0 unexpected) in 8.213 (8.249) seconds
```

## Cobertura consolidada WPL-001..055

Combinando este run com os runs de 2026-04-18 (manual 001..024) e
2026-04-19 (manual + assistido 025..055):

- **55/55 casos validados**: 31 PASS manual (025..055) + 24 PASS (001..024,
  19 automáticos + 4 skips com cobertura no run 2026-04-18 ou UX-only)
- **0 FAIL** em toda a suite WPL
- H1 (stale cache), H3 (last pane fecha janela), H4 (sem botão X na tab)
  todos **corrigidos e verificados**
