# F1 — as duas decisões que [jaime] marcou como bloqueadoras

Antes de escrever o supervisor: o formato do log e a identidade de instância.
Ele pediu que estas fechassem no desenho, não no F4, porque nenhuma delas se
conserta depois sem refazer o resto.

---

## A. Formato do log

### O que hoje existe, medido

`rotate_file` (`pty.rs:344-369`): quando o arquivo passa do teto, copia a
segunda metade **sobre** a primeira, em blocos de 64 KB, **no mesmo arquivo**, e
só ao fim chama `set_len`.

Duas consequências, ambas verificadas:

1. **Morrer no meio deixa mistura.** Blocos já copiados são novos, os demais
   ainda são velhos, e não há como saber onde parou. O lock impede leitor
   concorrente; não torna a operação recuperável.
2. **`base_offset` não sobrevive ao processo.** O comentário em `pty.rs:109` é
   explícito: *"Resets to 0 on process restart"*. Hoje isso é inofensivo porque
   o dono do log morre junto com quem lê. Num supervisor, é fatal: o cliente
   guardou um cursor lógico e, depois de um restart, esse número passa a
   apontar para outro lugar.

Ou seja: mover o `ConversationLog` como está não entrega o F4. A garantia tem
que nascer aqui.

### Desenho adotado — segmentos append-only

```
conversations/<conversation_id>/<session_instance_id>/
  meta.json                 ← instância corrente, primeiro offset retido
  000000000000000000.seg    ← nome = offset lógico do primeiro byte
  000000000000524288.seg
  000000000001048576.seg    ← o único aberto para escrita
```

**Regras:**

- **Nunca se escreve sobre byte já escrito.** Append só, e só no último
  segmento. Retenção = **apagar segmento fechado inteiro**, nunca deslocar
  bytes válidos.
- **O nome do arquivo é o offset lógico.** É o que faz o offset sobreviver a
  reinício sem precisar de estado em memória — o defeito do `base_offset` some
  por construção, não por cuidado.
- **Recuperação lê a cauda do último segmento** e descarta o registro
  incompleto no fim. Só a cauda; tudo antes já é imutável.
- **Registro com moldura verificável**: `len` + `crc32` + payload. Uma cauda
  cortada no meio é detectada, não adivinhada.
- Tamanho de segmento e orçamento de retenção contam **bytes físicos**,
  incluindo cabeçalhos. Append pode exceder temporariamente o orçamento por
  um cabeçalho e um registro limitado; falha de retenção é resultado separado
  do append já confirmado, nunca convite para reenviar os mesmos bytes.
- Cabeçalho de segmento com magic, versão e offset inicial; formato antigo,
  checksum inválido e buraco entre segmentos são erros, não log vazio. Só
  registro incompleto no último segmento admite truncamento automático.
- Diretório por instância e lock exclusivo de escritor: uma nova execução
  nunca reutiliza o cursor de uma sessão anterior. Replay captura um limite
  de leitura e não segura lock durante envio de rede.
- **`meta.json` é escrito por troca atômica** (tmp + rename), e mesmo assim
  não é a autoridade: os nomes dos segmentos são. Ele acelera, não decide.

### O que a garantia diz, exatamente

> Morte do **processo** (SIGKILL incluído) não corrompe o log: a leitura
> recupera todos os bytes até o último registro íntegro.

Não digo nada sobre **queda de energia**: `write_all` aceito não é durabilidade
no dispositivo (isso exigiria `sync_all` por registro, e o custo não se
justifica para saída de terminal). A distinção fica escrita, não implícita.

### Como isso é testado (falha dirigida, não SIGKILL na sorte)

Ponto de injeção nomeado dentro do append e da retenção; o teste corta ali e
reabre. SIGKILL aleatório quase nunca acerta a janela — testaria o acaso.

---

## B. Identidade de instância

### O furo, de ponta a ponta

- `session_instance_id` = **UUID novo por spawn**, imutável até aquele PTY
  morrer. Não "epoch do supervisor": criar A → fechar A → criar B com o mesmo
  `conversation_id`, sem reiniciar o serviço, deixaria o epoch igual e o DELETE
  atrasado de A mataria B.
- `broker_boot_id` existe **só para diagnóstico** — nunca para decidir.
- Reanexar, e reiniciar o engine, **não** mudam o `session_instance_id`.

### Onde ele precisa aparecer

O ponto que eu tinha errado: adiantava nada guardar a identidade só no
supervisor. Verificado — o Mac hoje chama
`deleteLocalTerminal(conversationId:)` (`SoyehtAPIClient+LocalTerminals.swift:129`),
**sem geração**. O engine consultaria a instância corrente e mataria a nova.

Então a identidade atravessa até o app:

| onde | o que muda |
|---|---|
| `POST /api/v1/terminals/local` | resposta passa a trazer `session_instance_id` |
| `GET` (get/list) | idem |
| `DELETE .../{conversation_id}` | precondição `If-Match: <session_instance_id>`; sem ela, **412** |
| WS `attach` | vinculado à instância; instância errada não anexa |

**Cliente sem precondição:** mutação no backend novo é recusada. Leitura legada
pode ser compatível; backend legado durante migração é explícito. Não existe
fallback silencioso que selecione a instância atual para um DELETE antigo.

### Regras de concorrência

- `close` compara `expected_session_instance_id` e retira a instância **sob a
  mesma sincronização do registro**. Comparar, soltar o lock, e depois fechar
  por `conversation_id` é a corrida que estamos tentando eliminar.
- `write` e `resize` também ligados à instância: input atrasado de um TUI não
  pode cair num shell novo.
- Repetir `close` de instância já encerrada: inofensivo, e **nunca** seleciona
  "a atual" para satisfazer a repetição.
- Repetir `CREATE` depois do fechamento **não ressuscita**: chave de
  idempotência da intenção + tombstone com prazo documentado. "Reanexar à
  instância esperada" e "criar nova execução" são operações diferentes.

### Contrato de criação — F4a, protocolo UDS versão 2

O supervisor emite `intent_id` por `IssueIntent`. Não aceita UUID escolhido
pelo cliente como autorização de CREATE. Emitir não executa nada: perder a
resposta pode desperdiçar uma reserva, mas nunca duplica um comando.
O app recebe o ticket, persiste a intenção com argv/cwd/env e dimensões antes
do POST, e não troca esse ticket automaticamente após uma resposta incerta.

Repetir uma intenção viva devolve a mesma instância; alterar seus parâmetros
devolve `intent_mismatch`. CREATE só aceita um registro previamente emitido.
Registro ausente, coletado ou perdido não volta a autorizar execução:
`intent_expired` é definitivo. Registro consumido, legado ou corrompido também
não executa. O app oferece erro que pede uma nova sessão deliberada; não
reinterpreta expiração como prova de que nenhum comando chegou a rodar.

A transição para `consumed` ocorre sob a trava do registro, antes do spawn:
grava `.next`, sincroniza o arquivo, renomeia e sincroniza o diretório **depois**
da troca. Qualquer erro impede spawn, inclusive erro após rename. `sync_all`
na plataforma Apple usa `F_FULLFSYNC`. A garantia depende de filesystem e
dispositivo honrarem a barreira; os testes dirigidos provam ordem e recusa,
não uma queda física de energia. Isso é mais forte que o contrato do scrollback,
que não paga sincronização por registro de saída.

Há no máximo 4096 tickets armazenados. Ao atingir o limite, a emissão coleta
os mais antigos até liberar um oitavo do orçamento, excluindo tickets de
sessões vivas. Idade só decide a vítima; nenhum relógio pode restaurar uma
autorização ausente. A recolha sincroniza o diretório antes de confirmar.
Se todas as reservas forem protegidas, há recusa explícita, sem reiniciar o
supervisor. CREATE e cancelar o mesmo ticket continuam usando uma reserva.

O elo sessão/intenção vive no registro do supervisor enquanto a sessão existe.
A garantia é sobreviver à troca do **engine**. Reiniciar o próprio supervisor
não readota PTYs e não preserva sessões; tickets consumidos continuam impedindo
reexecução após esse reinício.

`CancelCreate(conversation_id, intent_id)` é distinto de CLOSE por instância.
Sincroniza `consumed` sob a mesma trava de CREATE antes de responder, em vez de
usar unlink como confirmação de revogação. Ausente, corrompido e legado são
sucesso idempotente; erro real de leitura ou conversa divergente continuam erro.
Se existe sessão com esse ticket no registro, fecha somente ela, mesmo se o
arquivo já não existir. Nunca seleciona uma nova instância da conversa.
O cancelamento impede sobrevivência e execução posterior daquela intenção;
não desfaz efeitos de inicialização que ocorreram antes dele.

A mudança exige UDS versão 2: incompatibilidade no handshake é erro de protocolo,
sem retry. O gate cruzado começa pela emissão HTTP real no Rust; Swift usa essa
resposta para construir o CREATE e os frames de teclado que Rust executa.

O stream de attach é dedicado à saída. WRITE/RESIZE/CLOSE usam conexão de
comandos e identificam a instância. ACK perdido de WRITE é resultado incerto:
o cliente não repete automaticamente a escrita. EOF não equivale a EXIT.
`ReplayRead::Gap` não contém bytes; o transporte envia GAP antes de avançar.

Disco indisponível durante append encerra a sessão e informa `log_write_failed`.
Retenção falha é diagnosticada separadamente e não encerra sessão. O ensaio
dirigido recusa a criação do próximo segmento, confere EXIT com o offset exato
dos bytes gravados e reabre o log preservando esse prefixo.

### Orçamentos físicos de F4

Cada log protegido retém até 32 MiB; segmentos têm alvo de 512 KiB físico.
Há 64 posições de sessão, incluindo instâncias encerradas ainda drenando ou
servindo replay. Arquivos coletáveis têm orçamento separado de 256 MiB e
64 instâncias. Portanto o conteúdo de log gerenciado ocupa até **2,25 GiB**,
mais tickets/metadados e a escrita transitória de um registro por log.
Isso não é uma quota de filesystem nem conta conteúdo externo ao formato.

A coleta roda antes de nova execução e a cada 60 segundos, inclusive ocioso.
Protege as instâncias no registro e a trava real do escritor. Layout desconhecido
fica preservado, fora da coleta e de seu orçamento, com `ptyd.archive.unmanaged`;
uma pasta inesperada não é tratada como falha transitória de disco. Erro real
de E/S impede nova execução sem encerrar as sessões existentes.

Ensaios com o daemon: 80 instâncias encerradas deixam 64 arquivos de instância,
preservando o shell vivo; um leitor que não consome não impede 40 MiB de saída,
a retenção física fica em 32 MiB e reattach recebe GAP antes dos bytes restantes.
Os testes do podador usam o tamanho dos arquivos e verificam separadamente
proteção por registro, por flock e isolamento de layout desconhecido.

---

## O que ainda não prometo

**Estado do emulador após reiniciar o app.** F2a separa `received` de
`applied` e avança `applied` somente após o parser consumir a fatia de bytes.
Reconectar a mesma view retoma de `applied`; descartar backlog rebobina apenas
`received`. O cursor não é persistido: uma nova view começa em zero e recebe
GAP explícito se a retenção já removeu história. Isso não promete recuperar um
estado de emulador que foi perdido. **Rotação deliberada e
"scrollback integral para sempre" não podem ser garantias simultâneas** — e a
segunda é a que vai embora.

## Checkpoint F2a — integração sem ativação

O adapter HTTP/WS e o consumidor Mac estão implementados. A variável
`THEYOS_PTY_SUPERVISOR_SOCKET` seleciona o backend; ausente mantém o legado,
presente e indisponível retorna erro sem fallback. Nenhum plist instalado
foi alterado por esta fatia.

O gate `scripts/check-terminal-contract.py` exige os dois checkouts: o Swift
gera CREATE e teclado JSON; Rust executa HTTP/UDS/PTY; Swift decodifica a
resposta e os frames reais. Quatro defeitos deliberados precisam reprovar:
prefixo de saída, instância, tipo de teclado e chave de intent. Compilação
falhada e teste ignorado não contam como controle negativo válido.

O teste do adapter recria o servidor HTTP mantendo o daemon e a identidade
da sessão; não mata o processo completo do engine. O ensaio de cancelamento
exercita as duas ordens, repetição e intent antigo diante de instância nova.
Ainda faltam morte/troca do engine instalado, ciclo de vida launchd e migração
de sessões legadas para o aceite final. Os limites/GC de
F4 descritos acima já têm ensaios locais, sem ativação do backend instalado.

Antes de entregar o supervisor como componente instalado, seus eventos precisam
entrar no diagnóstico coletado com procedência verificada. A lista governada
`scripts/ci/engine-safe-stages.txt` cobre hoje o engine; não se presume que ela
inclua `ptyd.archive.unmanaged` ou os demais eventos do novo processo.

## Ensaio de processo — shell, TUI e job

`server-rs/tests/support/local_terminal_process_survival.rs` executa o adapter
HTTP real em processo descartável, separado do processo que hospeda o supervisor.
SIGKILL no adapter é confirmado pelo SO e pelo HTTP indisponível. Só então a
TUI em terminal alternativo produz 64 linhas; a nova instância HTTP só é iniciada
depois de a produção terminar. Reattach pede o cursor anterior e confere cada
linha uma vez, seguido de desafio aleatório novo. Shell, TUI, job de longa duração
e supervisor mantêm PID/start/TTY/grupo; o nonce continua não exportado e a saída
da TUI devolve o primeiro plano ao shell. O controle negativo mata o dono do PTY
com a mesma carga armada e exige que shell, TUI e job desapareçam.

Isso não executa `main` completo do engine, não altera launchd e não testa a
renderização do app. O ensaio mede a arquitetura nova, com dono e HTTP em
processos separados. O engine publicado ainda hospeda ambos no mesmo processo;
seu controle negativo de 0/2 continua válido e não contradiz este positivo local.
A sobrevivência instalada só será afirmada após entregar essa separação e medir
sua troca sob launchd no Mac. A sonda Dev foi incorporada de `fdcb922b`, corrigida para
chamar `kickstart -k` pelo nome certo, usar desafio novo por tentativa e decodificar
o protocolo supervisionado. Seu relatório distingue saída sem attach de saída
com engine ausente; não se atribui a ela a cobertura adicional do ensaio Rust.
