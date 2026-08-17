# Fase 1 — runbook de E2E no Soyeht Dev.app

Complementa `docs/web-pane-phase1.md` (contrato). Aqui está **como** rodar o
aceite sem encostar no app real do Caio. Tudo abaixo foi medido nesta
máquina, não inferido.

## Regras que não se negociam

1. `/Applications/Soyeht.app` é o app de trabalho real do Caio e **está
   rodando**. Nunca sair dele, matar, reinstalar ou sobrescrever.
2. **Nunca `killall Soyeht`** — o padrão casa com o app de produção. Para
   encerrar só o Dev:
   `osascript -e 'quit app id "com.soyeht.mac.dev"'`.
3. `-configuration Debug` **é a fronteira de isolamento inteira**. Sem esse
   flag o build vira `com.soyeht.mac`, passa a escrever na árvore de
   produção e disputa as portas 8892/8091 com o engine real. Não existe
   scheme separado para Dev — é só a configuração.

## Isolamento Dev vs produção (medido)

O app resolve tudo a partir do bundle id
(`Packages/SoyehtCore/.../Install/SoyehtInstallProfile.swift:91,110`):

| | Produção | Dev |
|---|---|---|
| bundle id | `com.soyeht.mac` | `com.soyeht.mac.dev` |
| nome | `Soyeht` | `Soyeht Dev` |
| App Support | `~/Library/Application Support/Soyeht/` | `~/Library/Application Support/SoyehtDev/` |
| automation | `…/Soyeht/Automation/` | `…/SoyehtDev/Automation/` |
| snapshot | `…/Soyeht/workspaces.json` | `…/SoyehtDev/workspaces.json` |
| engine launchd | `com.soyeht.engine` | `com.soyeht.engine.dev` |
| portas | 8892 / 8091 | 8902 / 8101 |

O app é seguro por construção: `AppSupportDirectory.developerEnvironmentOverride`
só honra `SOYEHT_AUTOMATION_DIR` no build Dev, e recusa qualquer valor que
aponte para dentro da árvore de produção.

### A armadilha: os CLIENTES apontam para produção

`scripts/soyeht` e `scripts/soyeht-mcp` usam
`~/Library/Application Support/Soyeht/Automation` quando
`SOYEHT_AUTOMATION_DIR` não está definido. Ou seja: buildar o Dev não basta —
se o driver não for pinado, os comandos de E2E vão bater no app de produção.
**Pinar sempre**, na shell do E2E (não em config global de agente, senão
panes abertas pelo Dev perdem o próprio canal):

```sh
export SOYEHT_AUTOMATION_DIR="$HOME/Library/Application Support/SoyehtDev/Automation"
```

Nome canônico é `SoyehtDev`, sem espaço. (O `~/Library/Application Support/Soyeht Dev/`
que existe no disco é resíduo de junho de 2026; o README apontava para ele e
foi corrigido junto desta fase.)

## Sequência

```sh
cd /Users/macstudio/soyeht-worktrees/apps-web-pane-phase1
export SOYEHT_AUTOMATION_DIR="$HOME/Library/Application Support/SoyehtDev/Automation"
export DD="$(mktemp -d "${TMPDIR:-/tmp}/soyeht-web-pane-dd.XXXXXX")"

xcodebuild build \
  -project TerminalApp/SoyehtMac.xcodeproj \
  -scheme SoyehtMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  DEVELOPMENT_TEAM=W7677A5BK2 \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY='Apple Development' \
  -skipPackagePluginValidation \
  -derivedDataPath "$DD"
```

`CODE_SIGN_IDENTITY='Apple Development'` não é enfeite: o default de Debug é
assinatura ad-hoc, que troca o hash do binário a cada build e faz o macOS
repetir os prompts de TCC — o que atrapalha justamente um E2E dirigido por UI.

Encerrar a instância Dev antiga **antes** de instalar (senão `open` reativa a
velha, e o teste roda contra o build errado — falso-negativo clássico):

```sh
osascript -e 'quit app id "com.soyeht.mac.dev"'
rm -rf "/Applications/Soyeht Dev.app"
ditto "$DD/Build/Products/Debug/Soyeht Dev.app" "/Applications/Soyeht Dev.app"
open -a "/Applications/Soyeht Dev.app"
```

Testes de domínio (não precisam do app, podem rodar em paralelo ao build):

```sh
( cd TerminalApp/SoyehtMacTests && swift test )
```

## Aceite — os 7 itens

A lista canônica está em `docs/web-pane-phase1.md` (seção Aceite). Notas de
execução para os que têm pegadinha:

- **Item 3, o que realmente prova a correção do `anchorURL`**: abrir a pane,
  rolar a página, navegar para outra URL e verificar que a webview **não foi
  recriada** — scroll e estado preservados. Se a webview for recriada a cada
  navegação, é exatamente a regressão que a revisão previu.
- **Item 4 (rejeições)**: testar pelas duas portas, MCP e barra de endereço,
  além de redirect e `window.open`. Uma porta esquecida anula as outras.
- **Item 5 (restore)**: relançar o Dev app e conferir que a pane volta na
  última URL navegada — usa o snapshot de `SoyehtDev/workspaces.json`, então
  não há risco para os workspaces reais.
- **Item 7**: confirmar que um snapshot anterior à fase (sem panes web)
  carrega intacto.

Capturas de tela, quando necessárias, por **window id**
(`screencapture -o -x -l <WID>`), não por coordenada de tela — a janela se
move e coordenada mente.

Casos novos de `open_web` pertencem a `QA/domains/soyeht-mcp-automation.md`.
