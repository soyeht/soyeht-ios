# Apps na interface — runbook de E2E

Complementa `docs/app-identity-phase2a.md` e `docs/capability-bridge-phase2b.md`.
Aqui está só o que é próprio de uma interface que instala e abre apps.

## Isolamento, e ele é a parte que se erra

`-configuration Debug` **é** a fronteira inteira: Debug → `Soyeht Dev` /
`com.soyeht.mac.dev`. Sem o flag o build vira o app de produção e disputa
portas com o engine real. Confirmar o bundle id do artefacto, não confiar no
nome da pasta.

Encerrar **só** o Dev, por bundle id — nunca `killall Soyeht`, que casa com o
app de produção:

```sh
osascript -e 'quit app id "com.soyeht.mac.dev"'
```

Gate antes de instalar ou lançar, verificando o **artefacto** e não a saída do
filtro:

```sh
test -x "$APP/Contents/MacOS/Soyeht Dev" || { echo "abortado"; exit 1; }
```

O build Debug precisa de `CODE_SIGN_IDENTITY='Apple Development'` **e**
`DEVELOPMENT_TEAM` — sem o team a assinatura falha nos três alvos de uma vez.
Lançar o binário direto do `DerivedData`; `open` pode reativar uma instância
velha e o teste corre contra o build errado.

## A app de teste

Um bundle é uma pasta com `manifest.json` e o HTML. **Três armadilhas medidas**,
todas na fixture e nenhuma no produto:

1. **Script inline não executa.** A CSP da 2a é `script-src 'self'`, logo o JS
   tem de estar num ficheiro próprio. Uma fixture com `<script>` embutido
   renderiza o HTML e nunca corre — e parece um defeito da ponte.
2. **O relay escuta em `window`, não em `document`.** Despachar
   `soyeht.bridge.request` no `document` não chega a lado nenhum.
3. **O resultado é chaveado pela capacidade**: `d.result["metrics.read"]`, não
   `d.result`. Ler o caminho errado dá `NaN` em toda a interface, o que parece
   um defeito de métricas e é um defeito de leitura.

Campos reais do snapshot: `cpuLoadPerCorePercent` (**um inteiro**, não um array
por núcleo), `memoryUsedMiB`, `memoryFreeMiB`, `uptimeSeconds`.

## Aceite

1. Build assinado e suítes **executadas** (inteiras, nunca filtradas).
2. **A gaveta abre** por ⌥⌘A e lista o que está instalado, com o selo de
   capacidade certo por app — um app sem capacidade mostra ausência, um app com
   `metrics.read` mostra a capacidade.
3. **Instalar em duas etapas**: escolher a pasta mostra o que o manifesto
   declara, e nada é copiado até aceitar. Confirmar no disco que a pasta de
   instalação só aparece **depois** do aceite.
4. **Abrir** põe o app numa pane e ele recebe métricas reais pela ponte.
5. **Os dois estilos**: repetir 2–4 com `soyeht.design.style` em `classic` e em
   `neomorphic`. A gaveta tem de render em ambos a partir do mesmo caminho de
   código — plana num, elevada no outro.
6. O app de produção fica intocado durante toda a execução.

## Resultado da execução — 2026-08-18

Todos os passos verdes, nos dois estilos.

| passo | resultado |
|---|---|
| menu ⌥⌘A abre a gaveta | abre |
| lista com selos por capacidade | correta (`METRICS.READ` vs ausência) |
| escolher pasta → folha de declarações | mostra nome, versão, publisher, entry |
| nada copiado antes do aceite | confirmado no disco |
| aceitar → instala | pasta nova com o `installID` cunhado |
| abrir → pane | app corre |
| ponte concede `metrics.read` | CPU 26% · 81,3 GB usados · 46,7 GB livres · 506 h |
| estilo `classic` | plano, sem sombras |
| estilo `neomorphic` | painel arredondado, panes em cartão |

**Um defeito real encontrado e corrigido pelo E2E**: os botões de ícone da
gaveta não respondiam a clique. Causa: um `Circle().stroke()` decorativo em
`.overlay` fica **por cima** do botão e engole o clique. O botão "Install app…"
funcionava porque desenha a sua forma com `.background`. Um modificador de
diferença entre funcionar e não funcionar, e nada no build o denuncia —
`.allowsHitTesting(false)` na decoração.

## O que este E2E NÃO prova

Não há teste automatizado de nada disto: a suíte de domínio não compila AppKit
nem WebKit, e o repositório não tem CI. Este runbook é o teste, e ele só corre
quando alguém o corre.
