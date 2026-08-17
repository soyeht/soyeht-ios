# Fase 2a — runbook de E2E

Complementa `docs/app-identity-phase2a.md` (contrato) e reusa o runbook da
Fase 1 (`docs/web-pane-phase1-e2e.md`) para build e isolamento do Dev app.
Aqui está só o que é próprio desta fase.

## Antes de tudo: as regras que não mudam

Valem as mesmas da Fase 1, e a mais importante é que
`/Applications/Soyeht.app` é o app de trabalho real e **nunca** é tocado.
Encerrar apenas o Dev, por bundle id; `-configuration Debug` é toda a
fronteira de isolamento; e o cliente de automação precisa do diretório do Dev
pinado, senão dirige o app de produção.

## O que esta fase tem de diferente para testar

A Fase 1 podia ser validada perguntando "a pane abriu?". Aqui isso não basta:
**as promessas da 2a são todas negativas.** Um app que abre e renderiza pode
estar violando as quatro defesas ao mesmo tempo sem que nada apareça na tela.

Por isso o E2E usa um app cuja única função é **tentar o que a fase proíbe**:
`QA/fixtures/app-probe-phase2a/`. Ele carrega script externo, faz requisição
para outra origem, tenta navegar para fora, tenta abrir janela, e pede uma
fonte do próprio bundle. Cada linha reporta *bloqueado* ou **PASSOU** — e
`PASSOU` é falha do produto, não do teste.

## Instalação do app de teste

O caminho de instalação é o da fatia B (`AppInstallStore`), manual nesta
fase. Instalar apontando para `QA/fixtures/app-probe-phase2a/`, depois abrir
a pane pelo caminho da fatia C (`openAppPane`).

Registrar no resultado: o **fingerprint** calculado na instalação e a
**procedência**, que nesta fase só pode ser "local, não verificada". Se a UI
não disser isso ao usuário, é achado — o contrato exige que a ausência de
verificação seja explícita, não implícita.

## Aceite — o que olhar, e onde

1. **Build assinado verde** e testes de domínio **executados** (suíte
   inteira, nunca filtrada: o filtro esconde o efeito colateral em outro
   lugar, que é justamente o que a suíte existe para pegar).
2. **As quatro defesas**, lidas na tabela do probe. Todas devem dizer
   *bloqueado*. Qualquer `PASSOU` interrompe o aceite.
3. **O console é parte do teste, não decoração.** Violação de CSP aparece lá
   com o nome da diretiva. É o console que distingue "o pedido foi barrado
   pela política" de "o pedido saiu e falhou por outro motivo" — e os dois
   parecem iguais na tabela.
4. **Fonte do próprio bundle**: o contrato não declara `font-src`, então ela
   deve cair no `default-src 'none'`. Medir, não supor. Se for bloqueada
   **e** isso doer para um editor com ícones em fonte, é mudança de contrato
   com dado na mão — `font-src 'self'` é defensável, porque é conteúdo do
   bundle já revisado e não abre caminho de saída.
5. **Armazenamento**: reabrir a pane e depois relançar o app; as duas linhas
   de storage devem dizer "persistiu". Confirma no Dev app o que o spike já
   mediu isoladamente.
6. **Isolamento entre apps**: instalar o probe duas vezes com ids diferentes
   e confirmar que as origens diferem — é o que faz a política de mesma
   origem separar um app do outro sem código nosso.
7. **A pane web da Fase 1 continua igual.** Regressão aqui é o risco mais
   provável desta fase, porque ela mexe no mesmo switch de conteúdo de pane.
8. **Relançar o app**: a pane de app restaura, e a procedência continua
   "não verificada" — nada de estado de confiança sobrevivendo por acidente.

## O que esta fase NÃO prova

Registrado para ninguém supor o contrário mais tarde: não há verificação
criptográfica, não há raiz de confiança, não há revogação remota e não há
responsabilização de publicador. Um app instalado aqui é código local não
verificado, contido pela CSP e pela ausência de qualquer ponte — não por
identidade comprovada. Isso é Fase 3, e é o que a decisão de deixar qualquer
usuário pagante publicar vai exigir.
