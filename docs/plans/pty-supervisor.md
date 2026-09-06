# Sessões que sobrevivem à troca do engine

**Objetivo, em uma frase:** trocar o engine passa a ser desconectar e reconectar
um transporte, em vez de matar todos os terminais.

**Escopo: terminais LOCAIS do Mac.** Terminais dentro de VM ficam de fora (§7):
guardar o PTY local não mantém uma VM viva, e o lifecycle de VM/bridge precisa
de auditoria própria.

**Decisão:** caminho A — um supervisor de PTYs separado, dono exclusivo dos
terminais, iniciado pelo launchd, com o engine falando com ele por socket Unix.
Sem passagem de descritores. Revisado por [jaime]; a análise dele corrigiu três
premissas minhas e achou um acoplamento que eu não tinha visto.

---

## 1. Por que hoje cai

Os PTYs vivem **dentro do processo do engine**: `server-rs` usa
`terminal_rs::pty::PtyManager` como biblioteca (`state.rs:61`,
`handlers_terminal.rs:666`). Cada `bash` é filho direto do engine. Matar o
engine mata todos, por construção.

Medido em 2026-09-05 na produção do Caio: `launchctl bootout` do engine levou
11 sessões de agente, e o `load` seguinte falhou por corrida — a máquina ficou
36 s sem engine nenhum.

### O que NÃO é o motivo

Eu havia lido o comentário em `terminal-rs/src/bin/terminal_ipc.rs` ("o
subsistema de PTY passou a viver in-process… o fd master não atravessa
fronteiras de IPC de forma limpa") como prova de uma tentativa fracassada de
tirar o PTY de lá.

**Verifiquei e a leitura era falsa:** no commit **pai** de `602c161e`
(22/04/2026), o `pty_mgr` **já estava** no `state.rs` do engine. Havia duas
superfícies convivendo e uma foi removida por simplificação.

O que isso prova, exatamente: **este** comentário e **este** commit não
sustentam a história de uma tentativa fracassada. Não prova que nunca houve
outra tentativa em outro lugar — [jaime] apontou que minha frase original
("nunca houve tentativa arquitetural derrubada") era mais forte que a
evidência, e ele está certo.

---

## 2. O desenho

```
launchd
  ├── soyeht-ptyd        ← dono exclusivo dos PTYs; nunca reinicia numa troca de engine
  │     └── bash -i      ← as sessões vivem aqui
  └── theyos-engine      ← HTTP/WS, auth, negócio; reconecta ao ptyd por UDS
```

**O supervisor é dono, não cofre.** Ele cria os shells, mantém os masters,
**drena continuamente** a saída, registra os bytes e atende
`create/get/list/attach/write/resize/close`. O engine nunca vê um master.

Dois motivos, ambos do [jaime], ambos que eu não tinha considerado:

1. **Dois leitores roubam bytes um do outro.** Se o engine também lesse o
   master, cada byte iria para um dos dois, não para ambos.
2. **Um cofre de descritores trava o programa.** Sem alguém drenando o master, o
   buffer do kernel enche e o processo do usuário bloqueia na escrita.

Por isso **não** há `SCM_RIGHTS` neste desenho. (Ele existe no macOS — está no
XNU — só não é necessário aqui.)

### Por que não B (handoff na troca)

`bootout` manda SIGTERM antes do SIGKILL, e o engine tem desligamento gracioso
(`main.rs:662`), então existe janela. Mas:

- Janela não é garantia, e **não cobre crash nem SIGKILL**.
- O fluxo atual **remove a label velha antes de carregar a nova** — não há
  receptor pronto para receber nada.
- `SCM_RIGHTS` não transfere parentesco, `Child`, nem direito de `waitpid`.

B protegeria só o caso educado — e mesmo esse ele não protege hoje, porque não
há receptor. Registro a correção do [jaime]: o incidente de 2026-09-05 **foi**
uma parada administrada por `bootout`, então dizer que "o caso educado não
derrubou ninguém" é falso. Ele derrubou. O que B não cobre é crash e SIGKILL, e
não cobre nem o educado enquanto o fluxo destruir a label antes de ter para
onde entregar.

---

## 3. O que atravessa a fronteira

Medido: `pty.rs` 2096 linhas, `handlers_terminal.rs` 1590, 21 usos de `pty_mgr`
em 4 arquivos do engine.

| peça | onde está hoje | por que precisa mudar de lado |
|---|---|---|
| **replay + rotação** | `handlers_terminal.rs:906-1137` | o engine abre o arquivo direto (`File::open(log.path())`) mas coordena com a rotação por `replay_guard`/`base_offset` **em memória**. Lock em memória não existe entre processos. Deixar como está = corrida real na rotação. **Achado do [jaime].** |
| **ownership/lifecycle** | `PtySession` em `pty.rs` | guarda `Child`, thread de leitura, `closed`, tamanho, `slave_tty_path`, PGID, cwd. `close()` enumera processos da TTY, classifica helpers MCP, escala HUP→TERM→KILL. Tem que ficar com o dono, incluindo `wait`/reap. |
| **create/list/delete** | `handlers_terminal.rs` | preservar create idempotente por `conversation_id`, `reconnected` real, mapeamento TTY→pane do MCP. Precisa de **identidade de instância** — ver §3.1. |
| **manutenção** | `main.rs:543-552` | `cleanup_stale`, `gc_orphaned_conversation_logs`, teto de sessões. Cliente lento não pode bloquear a drenagem. |
| **política de erro** | `pty.rs:894-907` | erro de append em disco hoje chama `sess.close()`. Mover isso tem que ser deliberado, não acidental. |

### 3.1 Identidade de instância (e o furo que ela tinha)

Eu havia proposto "epoch monotônico do supervisor". [jaime] mostrou que não
basta: se o epoch muda só no boot, então criar A → fechar A → criar B com o
MESMO `conversation_id`, sem reiniciar o supervisor, deixa um DELETE atrasado
de A casando com B.

**Desenho adotado:** `session_instance_id` = UUID aleatório novo **por spawn**,
imutável até aquele PTY terminar. Mais `broker_boot_id` só para diagnóstico.
Reanexar, ou reiniciar o engine, nunca muda o `session_instance_id`.

Regras que vêm junto:
- `close` compara `expected_session_instance_id` e retira a instância **sob a
  mesma sincronização do registro** — não vale comparar, soltar o lock e depois
  fechar por `conversation_id`.
- `write`, `resize` e `attach` também ficam ligados à instância: input atrasado
  de um TUI não pode cair num shell novo.
- Repetir o `close` de uma instância já encerrada é inofensivo, e **nunca**
  seleciona "a atual" para satisfazer a repetição.
- Repetir `CREATE` depois do fechamento não pode ressuscitar: separar "reanexar
  à instância esperada" de "criar nova execução", com chave de idempotência da
  intenção, tombstone e prazo de repetição documentado.

**O furo de ponta a ponta.** Minha frase do F2 — "HTTP/WS permanecem iguais" —
estava errada. Verificado: o Mac hoje faz `deleteLocalTerminal(conversationId:)`
(`SoyehtAPIClient+LocalTerminals.swift:129`), **sem geração nenhuma**. Se o
engine receber esse DELETE velho e consultar a instância ATUAL para montar o
RPC, mata B do mesmo jeito — a identidade no supervisor não teria servido para
nada.

Então: as URLs podem continuar, mas `session_instance_id` passa a aparecer nas
respostas de `create/get/list` e nas **precondições** de `attach`/`delete`
(`If-Match` no DELETE). O Mac guarda a identidade que recebeu; uma conexão WS
fica ligada àquela instância. Cliente antigo precisa de política de
compatibilidade explícita — ele não tem a mesma garantia contra requisições
atrasadas, e isso tem que estar escrito, não implícito.

**Fica no engine:** auth, ownership das conversas, SQLite de negócio,
`touch_activity`, HTTP/WS voltado ao cliente.

**Detalhe que não muda:** `LocalSpawnSpec` já manda argv/cwd/env completos e usa
`env_clear()`, então o shell não depende de herdar ambiente do engine.

### Armadilhas nomeadas

- **`IpcClient` mata o filho no `Drop`** (`core-rs/src/ipc/client.rs:282`) e o
  harness morre no EOF do stdin. **Não reutilizar** para falar com o supervisor
  — ele morreria junto com o engine, que é exatamente o que queremos evitar.
- **Atualizar o engine nunca pode dar `bootout` no supervisor.**
- **Incompatibilidade de protocolo não pode reiniciar o supervisor** com panes
  vivas — tem que degradar, não matar.
- **O cliente Mac** (`EnginePaneAttacher`, `MacOSWebSocketTerminalView`) precisa
  distinguir *transporte indisponível* de *sessão encerrada*.

  **Correção:** minha primeira versão dizia que o Mac "emitiria `session_ended`"
  numa falha de transporte. Isso era hipótese escrita como medida — o mesmo erro
  que me custou o dia. Verificado: `session_ended` é um marcador que o Mac
  **recebe do backend** (`MacOSWebSocketTerminalView.swift:773`); falha de
  recepção tem retry, limitado por `maxReconnectAttempts = 3`.
  O que precisa de revisão e teste é portanto **o limite de retry, os callbacks
  de falha e o fallback**, não uma emissão que não existe.
- **Segurança:** o endpoint executa argv no host. Socket com permissão restrita,
  diretório restrito, peer local autenticado, IPC versionado, e label/socket
  próprios por perfil (Dev vs produção).

---

## 4. Fatias, em ordem

Cada fatia termina com commit local e **E2E medido**. Nenhuma vai para produção
antes da anterior estar provada no Dev.

### F0 — Instrumentos (sem mudança de comportamento)
Um roteiro reproduzível que abre N panes com shell, TUI (`htop`) e processo
longo, e um verificador que mede — **colhendo do SO, não do `list` do próprio
supervisor**, senão ele testemunha a si mesmo.

Identidade (necessária, não suficiente): **PID + start-time + TTY**. No mesmo
boot isso já distingue PID reciclado; TTY sozinha não, porque o nome pode ser
reusado.

O que [jaime] acrescentou, e que separa "mesma sessão" de "sessão recriada de
forma convincente":
- **nonce aleatório em variável NÃO exportada**, atribuído só antes da falha
  (`X=1` é fraco: um roteiro de recuperação pode reexecutá-lo);
- **PID/start-time do processo longo e do TUI**, além do shell;
- **PGID e foreground process group**, para provar job control. `ps -o sess=`
  devolve zero neste macOS; esse campo não serve como prova de SID;
- **desafio de I/O depois do reattach** — processo vivo pode estar travado;
- **saída numerada e determinística durante a ausência**, conferida por
  conteúdo e intervalo no replay, não "apareceu alguma coisa";
- **novo PID/start-time do engine e MESMA identidade do supervisor**, provando
  que matei o componente certo e que ele ficou fora por um tempo conhecido.

Matriz de falha: `bootout` da label exata do engine **e** SIGKILL direto no
engine (esse segundo faltava no meu plano). Manter o engine fora **além da
janela de retry atual** e então restaurar — a pane tem que voltar sozinha.

**Aceite:** todos os itens acima são medidos no Dev, incluindo nonce, desafio
de I/O e conteúdo produzido durante a ausência. `identity_only` não fecha F0
nem o aceite do supervisor. Controle negativo mede o baseline de hoje; se
não der 0%, o relatório mostra o número real e eu investigo — não forço a
expectativa.

### Protocolo UDS — semântica fechada antes do F1

[jaime] propôs a forma; adoto. Envelope com prefixo de tamanho (teto **antes**
de alocar), tipo, `request_id`/`stream_id`, inteiros com largura e endianness
definidas; metadados em CBOR, `DATA` com bytes crus (nada de conversão UTF-8).
Leitura/escrita parcial é responsabilidade do transporte.

- `HELLO {supported_versions, capabilities}` → `WELCOME {selected_version,
  broker_boot_id, limits}`. Versão incompatível **encerra a conexão**; não toca
  em sessão.
- `ATTACH {conversation_id, session_instance_id, next_offset}` →
  `ATTACHED {session_instance_id, base_offset:B, replay_end:W, cols, rows}`.
- `DATA {stream_id, session_instance_id, start_offset, payload}` — intervalo
  `[start_offset, start_offset+len)`, offsets **lógicos**, nunca posição física.
- `REPLAY_END {offset:W}` — o live continua de W, sem buraco nem repetição.
- `GAP {from, to, reason:retention}` quando os bytes já foram descartados.
  **Nunca** um seek silencioso para B.
- `RESYNC_REQUIRED {base_offset, end_offset, reason:subscriber_lagged}` —
  não declara morte do PTY nem perda garantida.
- `EXIT {session_instance_id, final_offset, exit_status}`; `CLOSE_RESULT` e
  `ERROR` são mensagens distintas. **EOF do socket é perda de transporte, nunca
  EXIT** — é exatamente a confusão que apagaria a pane.

No attach: registrar a assinatura e capturar W em ordem consistente com o
append. **Nunca** segurar o lock de rotação durante o envio. Filas por assinante
são limitadas; cliente lento não segura a drenagem do PTY nem outro cliente.

`WRITE` precisa de regra para ACK perdido: `request_id` correlaciona resposta,
não deduplica execução. Ou `(client_id, input_seq)` com deduplicação no
supervisor e janela explícita, ou não repetir escrita de resultado incerto.
**Não prometo exactly-once** através da morte do próprio supervisor.

E um ponto que eu não tinha visto: **offset no UDS deduplica supervisor↔engine,
não prova "sem duplicata na pane"**. O cursor de retomada da UI tem que
significar bytes aceitos pelo estado que ela ainda guarda. Se o app reiniciou e
perdeu esse estado, é reconstrução explícita — e log truncado não é snapshot de
um emulador VT. Ou defino essa capability no WS agora, ou reduzo a promessa do
aceite. **Rotação deliberada e "scrollback integral para sempre" não podem ser
garantias simultâneas.**

### F1a — Log recuperável, independente do socket
Formato segmentado, versionado, recuperação por registro e retenção por
segmento inteiro. O ensaio usa arquivos reais em diretórios temporários e
falhas dirigidas em cada corte de append e entre remoções de retenção. Não
depende de launchd nem de PTY. O formato e sua prova vêm antes do serviço.

### F1b — O supervisor existe e serve, sem ninguém usar
Novo binário `soyeht-ptyd`, LaunchAgent próprio, socket UDS versionado.
Implementa `create/get/list/attach/write/resize/close` sobre o `PtyManager`
movido, **com replay e rotação junto** (não dá para separar).
**Aceite (E2E, não só unitário — a primeira versão dizia "testes do crate" e
contradizia a regra da §6; [jaime] pegou):** um cliente de teste UDS contra o
**processo real**: cria PTY, mata só o cliente, produz saída sem nenhum
assinante, reanexa e valida o estado. Mais: iniciar o serviço duas vezes — a
segunda não pode remover o socket da primeira nem criar um segundo dono.
O engine continua no caminho antigo; nada muda para o usuário.

**Coexistência, com a regra que [jaime] fixou:** dois processos oferecendo PTYs
é aceitável; dois donos da MESMA sessão, ou dois escritores do MESMO log, não.
Cada sessão tem um dono escolhido uma vez. Sem "shadow traffic" replicando
create/write/resize nos dois caminhos. `terminal-rs` continua biblioteca dos
dois executáveis — não há fork de código.

### F2a — Contrato e reconexão do Mac (antes da ativação)
[jaime] recomendou partir o F3: o contrato e a preparação do cliente vêm antes
da ativação, e o acabamento depois. Motivo: se o aceite do F2 usar panes reais,
ele depende da reconexão correta do app — e não se ativa rota nova com fallback
destrutivo ainda possível. Aqui entram `session_instance_id` nas respostas e
precondições, e o retry/fallback do Mac revisados.

Mutação no backend novo exige a precondição que identifica a instância.
Cliente sem ela é recusado; nunca há fallback silencioso para matar a sessão
atual. Leituras compatíveis podem continuar. O backend legado, se habilitado
durante a transição, é explícito e não possui a garantia do supervisor.

Inclui atualizar e verificar as fixtures entre repositórios, o pin em
`scripts/cross-repo-contract.sha` e os literais governados de release, com
comparação byte a byte contra a fonte. Mudar versão não substitui essa prova.

### F2b — O engine passa a falar com o supervisor
O engine usa o UDS para sessões locais; PTYs de VM continuam no gestor antigo.
As URLs permanecem, mas o contrato acrescenta identidade e precondições.
**Aceite E2E no Dev:** abrir 3 panes, `launchctl bootout` **só na label do
engine**, e depois do reattach: mesmo PID/start-time/TTY, nonce não exportado
preservado, `jobs` preservado e conteúdo numerado da ausência no replay.

### F3 — O cliente Mac aguenta a ausência (acabamento)
`EnginePaneAttacher`/`MacOSWebSocketTerminalView` distinguem transporte de
sessão; nada de `session_ended`, de recriar shell, nem de cair para `NativePTY`
numa troca.
**Aceite E2E:** durante o bootout do engine a pane mostra "reconectando" e
volta sozinha, com o scrollback íntegro. Ctrl-C / Ctrl-Z / `fg`, resize e UTF-8
partido entre chunks continuam corretos.

### F4 — Robustez e limites
Rotação sob cliente lento, truncamento explícito, cap de sessões, `cleanup_stale`
e gc de órfãos no supervisor. Crash do supervisor (SIGKILL) é domínio de falha
próprio: as sessões morrem — mas o log tem que ficar íntegro e a UI dizer a
verdade.
**Aceite E2E:** falhas DIRIGIDAS em pontos conhecidos da rotação e do append
(não SIGKILL aleatório torcendo para acertar a janela) não corrompem o log nem
travam a UI. Disco cheio tem política definida e testada.

**Bloqueador que [jaime] achou, e que muda o F1:** o formato de hoje não permite
essa promessa. `rotate_file` (`pty.rs:344-369`) copia a segunda metade sobre a
primeira em **várias escritas no mesmo arquivo**, e só depois chama `set_len`.
Verifiquei: é exatamente isso. Um SIGKILL no meio deixa mistura de conteúdo
velho e novo, e o lock só impede leitor concorrente — não torna a operação
recuperável. `base_offset` também vive só em memória.

Portanto a **escolha do formato entra no F1**, não no F4: segmentos append-only
com offsets e instância identificáveis, registros verificáveis, recuperação que
descarta só a cauda incompleta, e retenção que remove segmentos fechados em vez
de deslocar bytes válidos in-place. O F4 endurece e testa; ele não pode ser o
lugar onde a garantia nasce.

E a garantia precisa ser dita com precisão: **morte do processo ≠ queda de
energia**. `write_all` aceito não é durabilidade no dispositivo (`sync_all`).

### F5 — A virada em produção
Ver §5.

---

## 5. Transição das sessões legadas

Eu havia escrito "a última queda é inevitável, cabe avisar". [jaime] discordou em
dois pontos e aceito os dois.

**Primeiro: inevitável, não.** Migrar ao vivo aqueles masters não faz parte de A
— mas disso não segue que o trabalho tenha de ser perdido. O caminho barato é
**drenagem planejada**: terminar os trabalhos e fechar as sessões legadas
voluntariamente, confirmar zero sessões legadas vivas, e só então trocar o
engine. Máquina com CPU ociosa **não** quer dizer sessão descartável — um shell
esperando input ainda guarda estado.

**Segundo, e mais importante: avisar não autoriza.** Se sobrar sessão e o Caio
preferir descartá-la numa janela, isso é decisão **dele** sobre aquelas sessões,
tomada com o inventário na frente — não algo que eu anuncio e executo.

Padrão adotado: **drenagem**. Entrego antes um inventário verificável (quais
sessões, o que roda em cada uma, há quanto tempo) e ele decide.

Se um dia for preciso abrir sessões novas no ptyd enquanto as antigas seguem
vivas por dias, existe o caminho de dois engines (portas/labels distintas,
panes antigas no antigo, novas no novo). Custa proprietário por pane,
credenciais e discovery de TTY coerentes, e isolamento de logs/DBs/manutenção —
só pago isso se a drenagem simples for impraticável.

**F5 não está autorizado nesta revisão.** Primeiro o inventário e o resultado
verificável.

### O que a garantia diz, exatamente

Não "nunca mais cai". A frase honesta é:

> **Reiniciar, substituir ou derrubar o engine não encerra os PTYs locais que
> já pertencem ao supervisor.**

Morte do próprio supervisor, VM e reboot ficam fora — o próprio F4 prevê a
primeira.

---

### Sequência (recomendação do [jaime], adotada)

`F0` → `F1a` log com falhas dirigidas → `F1b` prova real por UDS →
`F2a` contrato/reconexão do Mac → `F2b` ativado no Dev → `F3`
completo + `F4` com falhas dirigidas → `F5` só por drenagem, ou descarte
escolhido expressamente pelo Caio.

---

## 6. E2E é o critério de aceite

Regra: **nenhuma integração é dada como pronta por teste unitário verde.**
F1a tem ensaio próprio de arquivos e falhas dirigidas; o serviço e o produto
exigem processo real e ensaio no Dev, medido, com controle negativo.

Ensaio completo antes de encostar em produção:

| o que | como se mede |
|---|---|
| sobrevive ao bootout do engine | mesmo PID + start-time + TTY após reattach |
| estado do shell intacto | variável em memória, `jobs`, cwd |
| saída durante a ausência | aparece no replay, sem buraco e sem duplicata |
| rotação sob cliente lento | sem corrida no `base_offset` |
| job control | Ctrl-C, Ctrl-Z, `fg` |
| resize e UTF-8 | redimensionar; caractere multibyte partido entre chunks |
| delete explícito | encerra de verdade; DELETE atrasado não mata a sessão nova |
| versões diferentes de engine | protocolo velho x supervisor novo degrada, não mata |
| separadamente | logout/login, e o codesign/keychain |

**Não vou rodar teste destrutivo nas panes de produção do Caio.** Tudo no Dev,
com panes descartáveis criadas pelo roteiro do F0.

---

## 7. O que fica de fora

- **Codesign/keychain**: separar o supervisor **não** devolve a sessão gráfica.
  O sintoma de hoje é de keychain (bloqueado / ACL / sem interação), não
  necessariamente TCC — eu concluí "TCC" cedo demais e o [jaime] me corrigiu. O
  desenho certo para o que exige interação é um ajudante na sessão Aqua, chamado
  sob demanda. Item próprio.
- **Trabalhadores por sessão** (um processo por pane, em vez de um supervisor
  comum): reduz o raio de um crash do supervisor. Evolução possível do A, com
  mais lifecycle. Não agora.
- **Terminais dentro de VM**: se a promessa incluir isso, o lifecycle de VM/bridge
  precisa de auditoria própria — guardar o PTY local não mantém uma VM viva.
