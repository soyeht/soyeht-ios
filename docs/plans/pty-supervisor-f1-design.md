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

### Contrato inicial do F1b

`intent_id` é UUID de uma intenção de criação, congelada com argv/cwd/env e
dimensões iniciais. Repetir a mesma intenção viva devolve a mesma instância;
alterar os parâmetros devolve `intent_mismatch`. Depois do fim ou de um
restart do supervisor, a intenção consumida não executa novamente.

A reserva da intenção é persistida antes do spawn. Nesta primeira versão os
tombstones não expiram: há teto explícito de 4096 intenções e recusa
`intent_limit` ao atingir o teto. GC que permita reutilizar uma intenção antiga
não será introduzido implicitamente. Essa política precisa ser reavaliada com
a matriz de limites do F4 antes da ativação em produção.

O stream de attach é dedicado à saída. WRITE/RESIZE/CLOSE usam conexão de
comandos e identificam a instância. ACK perdido de WRITE é resultado incerto:
o cliente não repete automaticamente a escrita. EOF não equivale a EXIT.
`ReplayRead::Gap` não contém bytes; o transporte envia GAP antes de avançar.

Disco indisponível durante append mantém, por ora, a política explícita do
PTY existente: encerra a sessão e informa `log_write_failed`. Retenção falha
é diagnosticada separadamente e não encerra sessão. São falhas distintas da
troca do engine; F4 precisa exercitá-las antes do aceite final.

---

## O que ainda não prometo

**Cursor sem duplicata até a pane.** Offset no socket deduplica
supervisor↔engine; não prova que a pane não viu duas vezes, porque o app pode
ter reiniciado e perdido o estado do emulador. Ou a UI ganha uma capability que
diz "aceitei até aqui", ou o aceite do F2 promete menos. **Rotação deliberada e
"scrollback integral para sempre" não podem ser garantias simultâneas** — e a
segunda é a que vai embora.
