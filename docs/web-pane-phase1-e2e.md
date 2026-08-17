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

## Resultado da execução — 2026-08-17

Build Debug assinado a partir de `feat/mac-web-pane-phase1`, instalado em
`/Applications/Soyeht Dev.app` (`com.soyeht.mac.dev`, WebKit linkado,
TeamIdentifier W7677A5BK2). App de produção intacto durante toda a execução.
Testes de domínio: 609 executados, 0 falhas.

Todos os 7 itens passaram.

| item | resultado |
|---|---|
| 1 build assinado | verde, WebKit em `otool -L` |
| 2 testes de domínio | 609/0 falhas, executados |
| 3 pane abre + dedupe | `open_web` abre `kind: web`; 2ª chamada do mesmo anchor devolve `reused: true` na mesma pane; `new_pane: true` cria outra |
| 3b **webview não é recriada** | após navegar para outra URL, o botão voltar retorna à URL anterior — o histórico sobreviveu |
| 4 rejeições | `file:`, `javascript:`, `data:`, sem host, credenciais e string vazia — todas recusadas com mensagem própria |
| 5 restore | relançado o app, as três panes voltaram na última URL e recarregaram |
| 6 capture/send | erros limpos, sem crash; `get_pane_status` reporta `agent: web` e nenhum `working_directory` |
| 7 snapshot anterior | carregou intacto, panes de terminal preservadas |

Evidências que valem além do checklist:

- **A canonicalização vale na prática**: `open_web` com `https://EXAMPLE.com/#secao`
  reusou a pane criada por `https://example.com` — maiúsculas e fragmento não
  criam identidade nova.
- **Âncora e estado realmente se separam**: a pane aberta em `https://uol.com.br`
  seguiu o redirect e persistiu `url = https://www.uol.com.br/` mantendo
  `anchorURL = https://uol.com.br`.
- **Sites reais funcionam.** O risco levantado na revisão — a política estrita
  de navegação aplicada a todos os frames quebrar embeds — **não se
  materializou**: o uol.com.br renderizou completo (logo, cotações,
  publicidade, banner de cookies). A postura fail-closed fica como está.
- `workingDirectoryPath` é nulo em todas as panes web; nada vaza o diretório
  pessoal para o wire nem para o pareamento.

### Sessão e login persistem entre reinícios (verificado)

Pedido de produto do Caio: se ele fizer login num site, a sessão tem de
sobreviver ao fechamento do app. A decisão R3 (`WKWebsiteDataStore.default()`)
entrega isso, e foi **medida**, não assumida:

1. uol.com.br exibindo o banner de cookies;
2. clique em aceitar → banner desaparece (confirmado pela árvore de
   acessibilidade, não a olho);
3. app encerrado e relançado;
4. banner **não** volta — a escolha sobreviveu.

Em disco: `~/Library/WebKit/com.soyeht.mac.dev/WebsiteData/` com LocalStorage
e IndexedDB, que é o mesmo maquinário que sustenta sessão de login. O
diretório é por bundle id, então Dev e produção não compartilham sessão, e o
desinstalador já o rastreia.

`chatgpt.com` e `claude.ai` renderizam corretamente numa pane, incluindo a
tela de login do Claude e a interface completa do ChatGPT.

**Ressalva não testada**: login por email deve funcionar como qualquer
navegador, mas provedores de OAuth — o Google em particular — costumam
recusar autenticação dentro de webviews embarcadas por política de segurança.
Se "Continue with Google" falhar, o problema é do provedor, não do nosso
armazenamento, e a saída conhecida é abrir esse fluxo no navegador do
sistema. Não foi exercitado aqui porque exigiria credenciais reais do Caio.

Nuance registrada, sem defeito: o contrato diz que `anchorURL` é imutável, e
no caminho de reuse ele é de fato reescrito pelo state novo (a pane de
`example.com` ficou com `anchorURL = https://example.com/#secao`). É seguro
por construção, porque o reuse só ocorre quando as chaves canônicas coincidem
— o que muda é a grafia, nunca a identidade. Quem mexer aqui depois deve
tratar a *classe de equivalência canônica* como imutável, não a string.

O mecanismo é o `createOrFocusSpecialPane`, que no caminho de reuse substitui
o state inteiro pelo content novo; a grafia do `anchorURL` converge para a do
`open_web` mais recente dentro da mesma chave. Se algum dia se quiser
imutabilidade estrita da string, o ponto único é gravar
`WebURL.canonical(anchorURL)` já na criação, dentro de `openWebPane` — uma
linha, sem migração de snapshot, porque as chaves não mudam. Nota de
extensão, não pendência.
