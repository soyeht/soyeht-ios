# Fase 2b — runbook de E2E

Complementa `docs/capability-bridge-phase2b.md` (contrato) e reusa os
runbooks das fases anteriores para build e isolamento do Dev app. Aqui está
só o que é próprio de uma ponte.

## Gate antes de instalar (herdado, e aprendido do jeito caro)

Build e instalação **nunca** no mesmo comando encadeado; verificar o
**artefato**, não a saída do filtro:

```sh
test -x "$APP/Contents/MacOS/Soyeht Dev" || { echo "abortado"; exit 1; }
```

E jamais encostar no app de produção: encerrar só o Dev, por bundle id.

## O que muda nesta fase

As fases anteriores validavam **ausência** de poder. Esta valida **poder
concedido com precisão** — o que é mais difícil de ler numa tela, porque o
sucesso e a falha se parecem: nos dois casos a pane renderiza normalmente.

Por isso o E2E é dirigido por dois apps que diferem **apenas na capacidade
declarada** (`QA/fixtures/app-bridge-probe` e `app-nocap-probe`). O mesmo
código percorre o caminho de concessão e o de negação, então uma diferença
de resultado só pode vir da política — não do app.

## O caso que define a fase

Um **subframe de mesma origem** tentando falar com o nativo. Ele importa
mais que todos os outros somados, por um motivo estrutural:

- handlers de mensagem são instalados em **todos os frames, sempre** — não
  existe restrição a frame principal para eles;
- `about:blank` e `srcdoc` **herdam a origem do pai**, e um subframe do
  próprio bundle **é** a mesma origem;
- portanto a comparação de origem, sozinha, **aprova o subframe**.

O que tem de barrá-lo é o direito pertencer ao frame principal. No probe,
"handler ausente neste frame" e "handler recusou" contam os dois como
negado: o que importa é o efeito, não por qual porta ele foi barrado. Só
receber métrica conta como falha.

**Se esse teste passar, verificar por que passou.** Passar por acidente — o
relay não ter sido injetado por outro motivo — tem o mesmo aspecto de passar
por construção, e só a leitura do código distingue.

## Aceite

1. Build assinado e suítes **executadas** (inteiras, nunca filtradas).
2. App **sem** capacidade declarada → chamada negada, e a **negação aparece
   na auditoria**. Um log que só registra sucesso não detecta ataque.
3. App **com** capacidade → métricas dentro do schema fechado, e os valores
   **variam** entre chamadas. Valor plausível e constante é o modo de falha
   que já nos pegou: zero pertence à faixa válida.
4. **Subframe negado** (acima).
5. Comando desconhecido, chave injetada, corpo acima do limite e corpo
   malformado → cada um com sua recusa própria.
6. Limite de taxa dispara sob rajada e o disparo é registrado.
7. **A pane web da Fase 1 não tem ponte**: `window.webkit.messageHandlers`
   não expõe o handler. É a checagem que prova que a ponte vive na
   configuração de app e não na de web — a ausência é o controle.
8. As defesas da 2a seguem válidas: script externo, requisição externa,
   `window.open` e navegação continuam bloqueados no app com ponte.

## Como ler o resultado

O probe reporta linha a linha, e **recusa é sucesso** na maioria delas. O
console continua sendo parte do teste: é onde uma violação de política se
distingue de uma falha por outro motivo.

Erros exibidos ao app **não podem** conter caminho, host, nome de usuário ou
existência de recurso — um app malicioso não deve conseguir usar a mensagem
de erro como oráculo. Conferir isso ao ler a tabela, não só o veredito.

## Resultado da execução — 2026-08-17

Build Debug assinado, app de produção intacto durante toda a execução.
**Todas as linhas com resposta explícita; nenhum silêncio.**

| linha | app COM `metrics.read` | app SEM a capacidade |
|---|---|---|
| relay atende | atende | atende |
| capacidade | **concedido**, com dados reais | **`not_granted`** |
| comando desconhecido | `unknown_command` | idem |
| chave injetada | `malformed` | idem |
| corpo acima do limite | `too_large` (4096 bytes) | idem |
| corpo malformado | `malformed` | idem |
| limite de taxa | 3 atendidas, 37 recusadas | 0 atendidas, 40 recusadas |

A prova da política é a **diferença controlada**: o mesmo probe, o mesmo
código, o mesmo momento — só o manifesto difere, e o resultado inverte. E o
relay atende nos dois casos, o que separa "não tenho ponte" de "não tenho
permissão", que eram indistinguíveis antes.

Nenhuma mensagem de erro vaza caminho, host ou existência de recurso.

**A única linha sem resposta é o iframe**, e a razão está no contrato: a CSP
o barra antes da ponte. A checagem de frame da ponte é coberta por teste do
validador puro, incluindo o subframe de origem **idêntica** — o vetor real —
e a ordem das verificações.

Nota para quem repetir: o atributo de prontidão é escrito no
`DOMContentLoaded`, então **na carga do script do app ele ainda não existe**.
Isso é o esperado, não anomalia: o que o app deve observar na carga é
*resposta em vez de silêncio*. O atributo serve a quem chega depois.

## O que esta fase NÃO prova

Não há acesso a arquivos, consentimento do usuário, revogação de concessão
nem qualquer forma de o app enviar dados para fora. Exfiltração exige disco
**e** rede, e nenhum dos dois existe aqui. A capacidade de disco — onde o
consentimento nativo passa a importar — é fase própria.
