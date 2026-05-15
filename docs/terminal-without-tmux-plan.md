# Terminal sem tmux — discussão de implementação

> Documento pra abrir em sessão fresca do Claude Code e planejar a troca
> de arquitetura. Branch atual: `feature/unify-terminal-screen`.

## Contexto

O app **Soyeht** é hoje um cliente de terminal que roda em cima de um servidor
que mantém sessões **tmux** (uma sessão por pane, multiplexadas).

O caso de uso principal é rodar **Claude Code** (CLI do Claude) nas instâncias:
- Começar uma sessão no Mac.
- Pausar.
- Continuar no iPhone vendo exatamente a mesma tela.
- No Mac, ter várias Claudes abertas lado a lado (panes).

## Problema que apareceu hoje (iOS)

Tentei unificar a tela do terminal (live + scrollback) usando o scrollback
nativo do `SwiftTerm` (`UIScrollView`). Funcionou no shell, mas **quebrou dentro
do tmux**: tmux roda em alternate screen buffer, então o buffer do SwiftTerm
não tem scrollback real — o tmux é dono do viewport.

Patch que implementei: interceptar pan no alt buffer, traduzir em
`Ctrl-b [` (entrar em copy-mode) + `PgUp`/`PgDn` (scrollar). Funcionar,
funciona — mas o feel **não é nativo** e não vai ficar:

- Copy-mode do tmux é paginado por keypress, **sem inertia**, sem rubberband,
  sem direção invertida suave. Dá pra rolar, mas cada "tick" é um salto.
- Direção fica confusa em relação ao comportamento iOS esperado
  (arrastar dedo pra baixo = conteúdo sobe = vê histórico acima).
- Nunca vai parecer com Terminal.app, Blink ou a-Shell — esses usam
  scrollback nativo da view.

Conclusão do usuário (correta): **tira o tmux do caminho da renderização**.
Pode continuar usando tmux no servidor por outros motivos, mas a UX
de scroll tem que vir do `UIScrollView` nativo do SwiftTerm.

## O que a gente quer (produto)

### iOS
- 1 tela = 1 sessão de shell.
- Scroll com inércia nativa, direção natural, rubberband — tipo Safari.
- Seleção de texto com long-press + arraste que sobrevive stream live
  (já implementado no `linefeed` fix).
- Voltar ao live com botão "↓ live" ou scroll manual até o fim.

### macOS
- Múltiplas panes lado a lado, igual tmux/iTerm2.
- Atalhos já programados:
  - `⌘⇧|` → split vertical
  - `⌘⇧-` → split horizontal
- Cada pane é uma sessão independente.
- Usuário controla várias instâncias de Claude ao mesmo tempo.

### Sincronização iOS ↔ macOS
- Começo uma sessão no Mac → pauso → abro no iPhone → vejo a mesma tela.
- Não é mirroring ao vivo (nem precisa): é **reconectar na mesma sessão**
  que tá viva no servidor e ter o scrollback completo disponível.

## Decisões de arquitetura pra debater

### 1. O que fazer com tmux no servidor?

**Opção A — Matar tmux completamente.**
- Servidor expõe cada "sessão" como um PTY SSH direto.
- Persistência vira problema: se SSH cair, shell morre.
- Mitigação: usar `mosh` (UDP, reconnect automático, reenvia scrollback)
  ou implementar reconexão + replay de scrollback no próprio servidor.

**Opção B — Manter tmux, mas não usar copy-mode.**
- tmux continua rodando no servidor por causa da persistência.
- Cliente captura scrollback via `tmux capture-pane -S -5000 -e -p` (já
  temos isso: `SoyehtAPIClient.capturePaneContent`) e alimenta no buffer
  do SwiftTerm **sem entrar em copy-mode**.
- Toda UX de scroll/seleção fica 100% no lado do cliente, SwiftTerm nativo.
- Trade-off: capture é síncrono, scrollback cresce, server precisa retornar
  rápido (já retorna).

**Opção C — Híbrido.**
- tmux só pra gerenciar panes/sessões.
- Cada pane que o cliente abre vira um PTY "passthrough" do tmux sem
  envolver copy-mode.
- Mais complexo; talvez overkill.

**Minha recomendação:** Opção B. tmux fica, mas sem copy-mode.
O cliente pede o scrollback uma vez no attach e recebe stream live
normal depois. Scroll/seleção = 100% cliente.

### 2. Panes no macOS

SwiftTerm macOS target já existe (`TerminalApp/SoyehtMac.xcodeproj`,
`TerminalApp/SoyehtMac/`). Panes podem ser:

- **`NSSplitViewController` recursivo** — split clássico do AppKit, mesmo
  modelo que Terminal.app / Xcode. Cada leaf é um `TerminalView`.
- Atalhos `⌘⇧|` / `⌘⇧-` inserem split no pane com foco.
- Fechar pane (`⌘W`) funde split irmão.

Cada pane mantém sua própria conexão SSH/WS independente. O "Claude×N"
é natural: 4 panes = 4 sessões Claude.

### 3. Sincronização iOS ↔ macOS

A sync que o usuário descreveu é essencialmente **resume de sessão**:

1. Cliente (Mac ou iOS) se conecta numa sessão **nomeada** no servidor.
2. Servidor garante que a sessão continua viva entre conexões (tmux
   cuida disso de graça, ou `systemd-run --user --scope` + `screen`).
3. No attach, cliente recebe:
   - Scrollback completo (capture inicial).
   - Estado corrente do cursor/cores.
   - Daí em diante, stream normal.
4. Múltiplos clientes attacheados = multiplexação (tmux attach-session -t
   X já suporta isso — inclusive é o que o app faz hoje).

Então: **tmux serve nesse caso**. Só não pode aparecer no caminho do scroll.

### 4. Scrollback: até onde?

- Servidor: `tmux set-option history-limit 100000` (~memória modesta
  por pane).
- Cliente: 5000 linhas cached em memória (já implementado:
  `computedScrollback()` com cap dinâmico por RAM).
- Backfill no attach: pedir as últimas 5000 via `capture-pane` e feedar
  no terminal do cliente antes de conectar o stream live.

## Arquivos / código relevantes

### Já mexidos nesta branch (feature/unify-terminal-screen)
- `Sources/SwiftTerm/iOS/iOSTerminalView.swift`
  - `updateScroller()` — gated tail-follow (preserva intent do commit `64a96cca`).
  - `linefeed()` — mouseMode gate (seleção sobrevive `tail -f`).
  - `contentOffset.didSet` — redraw hint.
  - `altBufferScrollPan` + `AltBufferPanDelegate` — **reverter se Opção B**,
    já que tmux copy-mode forwarding deixa de ser necessário.
- `TerminalApp/Soyeht/WebSocketTerminalView.swift`
  - `forwardTmuxScroll` / `forwardTmuxExitCopyMode` — **reverter se Opção B**.
- `TerminalApp/Soyeht/TerminalHostViewController.swift`
  - `scrollToLive()` — remover chamada de `forwardTmuxExitCopyMode`.

### A criar
- `TmuxBackfill` (já previsto no plano antigo) — chamar no attach, feedar
  scrollback no buffer nativo.
- macOS: `SplitPaneController` (`NSSplitViewController` recursivo).
- iOS: garantir que o scrollback nativo com 5000 linhas funciona sem
  forward pro tmux.

### Relacionados / source of truth
- `Packages/SoyehtCore/Sources/SoyehtCore/Preferences/TerminalPreferences.swift`
- `TerminalApp/Soyeht/SoyehtAPIClient.swift:509` — `capturePaneContent`
- `TerminalApp/SoyehtMac/` — target macOS
- `Sources/SwiftTerm/Terminal.swift:5424` — `changeScrollback(_:)`

## Perguntas abertas pra próxima sessão

1. Se entramos na **Opção B**, qual o mecanismo pra sinalizar pro tmux
   "não me mande eventos de scroll, eu cuido disso"? Precisamos de
   `set-option mouse off` no attach? Ou isso já não acontece porque
   SwiftTerm não reporta eventos de mouse a menos que o app peça?

2. Como o servidor gerencia **múltiplas conexões** na mesma sessão
   tmux sem conflito de input? (Dois clientes digitando ao mesmo
   tempo = race no PTY.) Talvez precisamos de lock/active-client.

3. A API do servidor (`~/Documents/SwiftProjects/iSoyehtTerm/docs/api-contract-tmux-sessions.md`) já suporta capture + stream ou
   precisamos adicionar endpoint?

4. No Mac, sessões múltiplas: abrir N conexões WS simultâneas pro mesmo
   servidor é OK? Rate limit? Autenticação compartilhada?

5. Resume de sessão iOS↔Mac: como identificar "mesma sessão"? Nome do
   pane tmux? UUID no app-side armazenado em iCloud?

6. Fallback pra quando o servidor não tem tmux (SSH direto): o Soyeht
   ainda precisa funcionar? Ou tmux é requisito do servidor Soyeht?

## Next action sugerida pro Claude na próxima sessão

1. Ler este documento + `docs/api-contract-tmux-sessions.md`.
2. Ler o plano antigo em `~/.claude/plans/sim-ultrathink-wobbly-newell.md`
   (continua relevante pra a parte iOS nativa — só a parte de tmux
   copy-mode precisa ser revertida).
3. Confirmar Opção B com o usuário.
4. Escrever plano novo:
   - Reverter forward de scroll pro tmux copy-mode.
   - Implementar `TmuxBackfill` de verdade (capture + feed nativo).
   - Arquitetura de panes no macOS.
   - Contrato de resume de sessão.
