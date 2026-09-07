# F2b — instalação, identidade e recuperação

Desenho da integração ainda em implementação. Os ensaios de processos do F0
não são aceite do launchd instalado. Nenhum comando deste documento foi
executado sobre os serviços Dev ou de produção por esta faixa.

## O resultado que precisa ser observado

A troca só termina quando o endpoint autenticado do engine responde com a
identidade da imagem esperada **e** o backend supervisor selecionado, e o
supervisor conserva o `broker_boot_id` observado antes da troca. Copiar um
arquivo, concluir um comando e encontrar uma label são três etapas anteriores.

`program` e argumentos do launchd verificam configuração, mas o caminho do
executável permanece igual durante uma substituição atômica. Semver e git SHA
também não distinguem dois builds locais diferentes do mesmo commit.

No macOS, `--build-info` e `artifact` em `/api/v1/version` usam o UUID Mach-O da
imagem carregada, lido do dyld. Não leem o arquivo que ocupa o caminho de
instalação. O UUID identifica a imagem produzida pelo linker; **não** autentica
o binário e não substitui a verificação de assinatura/hash do pacote. Ausência
de identidade é desconhecimento, nunca igualdade. O campo legado `version`
dessa API continua existindo, mas não é o verificador da troca.

O readback também compara `terminal_supervisor_boot_id`, observado pelo próprio
engine através do cliente configurado, com o boot consultado pelo instalador.
Selecionar o backend não prova qual daemon ele alcança. Erro nessa consulta
produz ausência de prova (`null`), não identidade nem inventário inventados.
O PID da consulta direta vem de `peer_cred()` do kernel; leituras antes/depois
do `launchctl print` devem concordar em PID e boot. Divergência é observação
incerta e permite outra consulta com prazo, não prova incompatibilidade.

`soyeht-ptyd --contract` informa o protocolo do helper no pacote.
`soyeht-ptyd --status --socket PATH` negocia com o daemon existente e lê seu
inventário na mesma conexão. Não inicia serviço, não emite ticket e não fecha
sessão. Falha de leitura não pode produzir contagem zero. Esse comando permite
ao instalador consumir o protocolo Rust sem escrever outro codec CBOR no Mac.

## Dois ciclos de vida

- O supervisor tem label, plist, socket, estado e log próprios por perfil,
  derivados de `SoyehtInstallProfile`. O plist usa caminhos absolutos e o
  processo é filho do launchd. Não há wrapper que mate o supervisor ao sair.
- Instalar um supervisor ausente e consultar um supervisor existente são
  operações distintas. Um supervisor existente compatível é preservado,
  inclusive se houver helper mais novo no pacote. Atualizar o arquivo para
  um boot futuro não autoriza reiniciar o processo atual.
- Supervisor existente incompatível produz diagnóstico e impede ativar um
  engine que não consegue conversar com ele. Não há bootout automático como
  reparo de protocolo, nem retorno ao backend legado.
- A operação de trocar engine recebe apenas a label do engine. Sua interface
  não recebe uma lista genérica de serviços para reiniciar. O teste exige
  zero comandos destrutivos dirigidos ao supervisor em todos os desfechos.

## Preparação antes de qualquer parada

Uma operação serial por perfil prepara e verifica o conjunto de artefatos:
engine, helper do supervisor, demais helpers necessários e plists. Uma falha
intermediária não autoriza a parada. Temporários têm nomes exclusivos e ficam
no mesmo filesystem dos destinos para substituição atômica.

A configuração do novo engine só seleciona o socket depois de verificar o
helper embarcado, a compatibilidade do daemon e os caminhos privados. Não se
aceita um pacote antigo por ter o mesmo número de versão no cache. A entrega
precisa incluir o helper; um build incompleto falha antes da mudança de serviço.

Uma atualização de engine já supervisionado pode manter os PTYs vivos. A
primeira migração do backend legado é outra operação: aqueles PTYs continuam
sendo filhos do engine antigo. Inventário ilegível não é inventário vazio.
Uma consulta de zero sessões também não bloqueia um CREATE concorrente.
Portanto a primeira ativação não herdará uma promessa de troca sem perdas:
exige fechar a entrada de novos lançamentos e verificar a condição de migração
na faixa de entrega. Até isso estar integrado e medido, não ativar a rota nova
por uma simples comparação de versão ou por relaunch do app.

## Troca e recuperação são estados diferentes

A operação registra destino (UUID da imagem e digest do plist), identidade
do processo anterior, boot do supervisor e fase. O estado pendente sobrevive ao
relaunch. O coordenador serial impede que uma segunda tentativa sobrescreva
o destino enquanto a primeira ainda está sem confirmação. A leitura distingue
registro ausente, válido, corrompido e ilegível. Os dois últimos impedem iniciar
ou sobrepor uma troca; nunca são interpretados como ausência. Falha ao persistir
a intenção impede o bootout. A recuperação do próprio registro danificado deve
ser explícita e verificar os processos atuais antes de abandonar a intenção.

1. Preparar e validar tudo. Conferir as precondições de sessão/compatibilidade.
2. Registrar a intenção antes de pedir a remoção do job do engine.
3. Registrar a fase de remoção antes de pedir bootout. O retorno do comando
   não prova que o processo acabou ou que a label foi liberada. Um crash entre
   o registro e o comando deixa resultado incerto; o journal não afirma que
   o comando ocorreu. Não existe transação exactly-once com o launchd.
4. Observar a liberação com prazo. Se o prazo acabar, registrar troca pendente;
   não chamar a label antiga de instalação bem-sucedida.
5. A recuperação observa primeiro: se o engine esperado já responde, confirma;
   se está ausente, tenta carregar o destino já preparado. Não repete bootout
   para recuperar um load. Na fase de remoção incerta, uma nova tentativa exige
   revalidar a identidade do processo original e as precondições de sessão e
   compatibilidade **com a entrada de novos lançamentos novamente fechada**.
   A barreira pertence também à retomada; consultar uma contagem zero não a
   substitui. Não pode derrubar um processo novo só porque ocupa a mesma
   label. Se essas identidades não puderem ser provadas, permanece pendente.
6. Após o load, verificar a configuração do job e o endpoint do executável
   realmente carregado. A label sozinha não confirma o resultado.
7. Distinguir engine pronto de continuidade comprovada. Imagem/protocolo errados
   ou timeout mantêm a troca sem confirmação. Mesmo boot do supervisor confirma
   continuidade. Se a máquina ou o supervisor reiniciou, revalidar o namespace,
   o programa e o estado do supervisor: um boot novo na mesma instalação permite
   concluir como `readyAfterSupervisorRestart`, sem alegar preservação dos PTYs
   antigos. Instâncias antigas recebem término explícito; não são recriadas.
   Esse caso não pode bloquear novos terminais indefinidamente.

Cada rodada de recuperação tem prazo e orçamento de tentativas; esgotar o
orçamento oferece retomar a mesma operação, não apagá-la ou matar outro
processo. **O custo possível é ficar sem engine por tempo indeterminado** entre
a remoção e a confirmação de uma carga bem-sucedida. A ação de retomar precisa
estar disponível na mesma execução do app, sem exigir relaunch; um relaunch
também recupera a intenção e oferece essa ação. A UI não fica bloqueada
enquanto observa o launchd. O preflight pode
provar arquivo/plist/protocolo; não pode provar liberação futura de uma label.

A exclusão de uma rodada termina com seu resultado. Isso é separado da
elegibilidade para abrir panes: relançar o app ou soltar o lock não autoriza
CREATE no engine legado que ainda pode ser alvo de remoção em voo. Um pendente
precisa ser visível e oferecer retomada; abandonar só pode liberar lançamentos
em um destino revalidado como seguro, nunca apenas esquecer a intenção.

`pending.next` impede leitura normal até uma retomada explícita. A retomada
valida primeiro `pending.json`; pode terminar staging válido da mesma operação
ou descartar staging com JSON sintaticamente truncado, que não passou pelo
rename nem autorizou comando. Registro autoritativo corrompido, esquema
desconhecido, arquivo ilegível/tipo inesperado e alvo divergente continuam
recusados. Não há limpeza cega do journal como recuperação.

## Provas exigidas antes da ativação

- Comandos injetados: timeout da remoção nunca resulta em sucesso por uma
  observação da label antiga; recuperar um load nunca repete remoção.
  Repetir uma remoção incerta exige identidade original e barreira renovada.
- Falha de preparação não emite bootout; falha de load permanece diagnosticada;
  carga tardia do destino correto pode confirmar a operação pendente.
- Processo com imagem antiga, path e semver iguais continua diferente depois
  de substituir o arquivo; identificação ausente/malformada é desconhecida.
- Supervisor indisponível não vira inventário vazio; consulta repetida preserva
  boot, PID e instância dos PTYs. Incompatibilidade não dispara reinício.
- Dev instalado: mesmo ensaio shell/TUI/job, bootout verdadeiro só da label do
  engine, ausência comprovada, saída nessa ausência e reattach no Mac. Verificar
  também crash, relaunch do app e nenhuma queda para NativePTY.
- Empacotamento e diagnóstico: helper presente, plists dos dois perfis
  coerentes, tokens `ptyd.` selecionados e procedência do contrato atualizada.

Os primitives de observação e os testes isolados não liberam publicação,
instalação nem a migração de sessões existentes por si mesmos.

## Pacote e identidade sem executar candidatos

O manifesto `SoyehtCore/Resources/embedded-engine-helpers.json` contém
`executables` e `artifactReceipt`. Swift e os scripts de fetch/embed leem esse
mesmo arquivo. O recibo `engine-build-info.json` viaja dentro do tarball e contém
`artifact` (`version`, `git_sha`, `image_uuid`, `pty_supervisor_protocol`) e
`executable_sha256`. O pin autentica o tarball; o recibo liga metadados aos bytes.

O instalador nunca chama `--build-info` no candidato: o engine 0.1.30 ignora a
opção e inicia o servidor. Só o produtor consulta o executável recém-compilado
do snapshot conhecido. No pacote Phase0, a identidade vem de `engine_artifact`
na atestação cujo hash já está ligado ao manifesto. A ausência desse campo
recusa o pacote antigo. O consumidor lê o arquivo, exige Mach-O arm64 magro
com um único UUID e verifica SHA-256 antes de copiar.

O embed re-assina o executável, o que muda seus bytes. Depois de validar a
entrada, faz codesign e atualiza o recibo para a saída, exigindo UUID constante.
UUID é identidade de link, não prova de integridade: essa passagem depende do
passo de assinatura controlado. O hash da saída identifica aquela saída exata,
não promete assinatura reproduzível. O validador Python tem uma cópia vendorizada
no consumidor; `check-engine-package-contract.py --theyos-repo <checkout>`
exige igualdade byte a byte e exercita emissão, leitura e recusa de campo alterado.

Estado desta fatia: gate do recibo e build de compilação do Mac passaram;
o instalador independente do supervisor tem testes de operações injetadas.
A integração desse instalador com o coordenador e a UI ainda falta. O pacote
publicado 0.1.30 não contém supervisor nem recibo e é recusado deliberadamente.
Não integrar o requisito ao main sem o pacote correspondente e o pin juntos.
Os workflows ausentes e os pins de integridade Phase0 desatualizados no produtor
continuam impedindo alegar validação integral de release; não foram contornados.
