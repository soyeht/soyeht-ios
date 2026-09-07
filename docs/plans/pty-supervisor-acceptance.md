# Aceite do supervisor PTY e da troca de engine — 2026-09-07

Estado: implementação e aceite no perfil Dev concluídos em 2026-09-07.
Produção não foi migrada; este registro não autoriza publicação nem descarte
de sessões legadas.

## Artefatos

- Cliente final: `6deb4da81ea1dcebc983bd07da06330703e3b4d7`.
- SHA-256 do executável do cliente instalado:
  `2de53f408e38bce0d5042deea99a79b3d119eb5ebf4f0b9c39fac65d4202ad2c`.
- Engine B: `94d38e8203949468d1a5d5949caf693a3252a8bc`.
- Imagens A/B: `623999971afb300bb7b670ebf7a352c7` →
  `bda01218414a3bcb8cd6cfbbc6b280e3`, ambas versão `0.1.30`.
- App Dev assinado: sete helpers, `codesign --verify --deep --strict`,
  proveniência e recibo pós-assinatura conferidos contra os bytes do bundle.

UUID identifica a imagem carregada; assinatura/hash e o passo controlado de
empacotamento sustentam a integridade. Supervisor compatível de outra imagem
permanece vivo de propósito, preservando as sessões que possui.

## Produto instalado

As medições de interface/serviço foram executadas por [blaire]. [jaime] leu
independentemente os JSONs F0, os estados A/B e as fitas de troca e ausência
prolongada. Também conferiu commit/hash/recibo do cliente final instalado e
consultou o engine, o supervisor e a identidade dos shells depois da última corrida.
Os ensaios de processo e arquivos também rodam isolados; seu verde não foi
usado para substituir medição do app instalado.

| Fronteira | Medida | Resultado |
|---|---|---|
| Migração legada | Consentimento pela UI na fixture, supervisor próprio, engine novo, readback e journal limpo | Passou |
| Bootout só do engine | 2 shells com jobs longos + TUI; PID/início/TTY/PGID, nonce não exportado, desafio de I/O | 3/3 preservados |
| Saída durante ausência | Processo e porta ausentes por 8 s; escritores terminam antes da carga; 64 linhas por shell, exatamente uma vez | Passou |
| SIGKILL só do engine | Mesma carga e reattach | 3/3 preservados; não prova produção durante ausência |
| Morte do supervisor | Mesma carga do positivo | 0/3 preservados, controle negativo |
| Pane real | Resize medido no PTY; Ctrl-Z/fg/Ctrl-C medidos no kernel | Passou |
| Relaunch do app | Mesmo shell/início/pai/instância; UTF-8 termina com app fechado, replay remonta sem substituição | Passou |
| Troca supervisionada A→B | Engine muda PID/imagem; supervisor mantém PID/boot; 2 shells/instâncias e scrollback mantidos | Passou, `readyWithContinuity` |
| New Conversation | Listagem pelo contexto canônico local, instância apresentada sem erro | Passou |
| Atualizar somente o cliente | v5→v6 mantém engine, supervisor e sessões | Passou, `readyNoReplacement` |
| Ausência com app aberto | 50 s fora, incluindo 37 s após a primeira perda registrada; recusas reais antes do retorno | Passou; duas panes recuperadas automaticamente, sem relaunch |

No SIGKILL, o launchd voltou antes do término dos escritores. O JSON registra
`engine_absence_output_proven=false`; a prova de ausência vem do bootout.
O controle negativo confirmou o domínio de falha: a arquitetura preserva contra
morte do engine, não contra morte do supervisor, logout ou reboot do Mac.

A fita prolongada contém 32 recusas retentáveis de attach em loopback, seguidas
de duas restaurações, com o mesmo PID do app e nenhuma menção a NativePTY.
A medição prova recuperação após falhas reais durante ausência prolongada;
não afirma intervalos exatos de backoff 1+2+4 s. A primeira corrida, de cerca
de 10 s, havia alcançado o retorno antes de exercitar tentativas recusadas.

As evidências privadas são `f0-bootout-2.json`, `f0-sigkill.json`,
`f0-supervisor.json`, `ab-before.txt`, `ab-after.txt`, `ab-swap.log` e
`f3-absence-run.log`, preservadas na bancada. Identificadores e logs brutos
não são copiados para este registro.

## Correções orientadas pela bancada

- Resposta legada `version=unknown` com forma explícita e ausência dos campos
  novos é reconhecida; consentimento continua preso ao processo/configuração.
- Ausência no domínio GUI é classificada pela mensagem, label, UID e código
  correspondentes. Formas desconhecidas continuam desconhecidas.
- Subida do engine usa prazo monotônico de 30 s. Uma chamada que acaba depois
  do prazo não autoriza outro comando de remoção/carga; Resume permanece válido.
- Prontidão confirmada reconsulta panes retidas, inclusive migração nativa que
  falhou antes do ticket. Instância conhecida nunca vira CREATE de substituição.
- O diálogo reutiliza o resolvedor canônico; contexto da listagem acompanha
  criação e WebSocket. Mudança do servidor ativo não muda a escolha da operação.
- Emissão e criação compartilham tratamento de recusa; falha tardia observa a
  mudança de prontidão. O POST de workspace não é repetido automaticamente.

## Fontes de verdade e limites da revisão

A fatia de Keychain anterior (`cbe9ec47`) centralizou as operações Security do
`KeychainHelper`, substituiu delete-before-add por update-first e separou ausência de falha de
leitura. CRL ilegível não vira lista vazia na admissão; os testes migrados usam
backend em memória.

No cliente, o manifesto de helpers é compartilhado entre Swift e scripts;
o resolvedor canônico decide o contexto administrativo local; os métodos de
workspace em Core conservam esse contexto durante a operação. Identidade de
sessão, ticket de criação, cursor aplicado e prontidão são valores distintos,
com contratos e negativos que atravessam Rust e Swift. Isso descreve as
fronteiras revisadas, não uma auditoria integral de todos os subsistemas.

## Verificações executadas

- 1080 testes XCTest do domínio Mac, 5 skips ambientais, 0 falhas; mais 6 casos
  de renderização Swift Testing. Os skips são inteligência/embedding e PathScope.
- Core: 26 testes de roteamento de API e 7 de resolução do contexto Mac,
  incluindo GET/POST no servidor escolhido quando outro servidor já está ativo.
- Gate cruzado: requests Swift executados em Rust, HTTP/PTY e identidade lidos
  no Swift; 7 alterações deliberadas recusadas. Skip/compilação não contam como
  recusa válida do controle negativo.
- Contrato de pacote: 9 casos e igualdade dos leitores produtor/consumidor.
- Sonda: 9 calibrações; recusa ausência incompleta, erro de consulta, processo
  transitório, executável parecido e seleção ambígua de daemon.
- 14 ensaios isolados do processo supervisor; clippy com warnings negados.
  Rotação/recuperação têm testes dirigidos de escrita, limites físicos e GAP.
- App Mac compilado e assinado; iOS simulador arm64 compilado após mover os
  métodos compartilhados para Core. A tentativa genérica x86_64 não ligou com
  a biblioteca Rust FFI existente, que só contém arm64; não houve release iOS.

Testes de barreiras de durabilidade provam ordem e recusa de estados
intermediários, não corte físico de energia. O orçamento gerenciado de logs é
64 × 32 MiB para sessões vivas + 256 MiB de arquivos; entradas estrangeiras
preservadas não são uma quota absoluta de disco.

## Entrega pública separada

Os commits e o bundle Dev estão prontos para a entrega coordenada. O pacote
público antigo não contém supervisor/recibo e é recusado pelo consumidor novo.
Pacote produtor, pins, contrato governado e diagnóstico `ptyd.` precisam avançar
juntos antes de integrar/publicar. As listas do produtor no branch já incluem
`soyeht-ptyd`; a release correspondente ainda não existe. O gate cruzado foi
executado nesta fatia, mas sua ligação automática ao portão governado de release
continua pendente da entrega pública. Workflows de integridade ausentes no produtor
não foram contornados nem apresentados como checks executados.

A primeira migração de produção exige inventário e drenagem das sessões legadas,
ou consentimento explícito sobre seu encerramento. Sessões legadas não herdam
retroativamente a garantia de continuidade do supervisor.
