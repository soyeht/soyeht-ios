// Cada linha é uma promessa da Fase 2b. O resultado esperado está ao lado.
const LINHAS = [
  ["a ponte existe nesta pane", "existe"],
  ["metrics.read declarado → concedido", "concedido"],
  ["comando desconhecido", "recusado"],
  ["chave injetada no corpo", "recusado"],
  ["corpo acima do limite", "recusado"],
  ["corpo malformado", "recusado"],
  ["limite de taxa dispara", "recusado após N"],
  ["iframe chamando a ponte", "NEGADO"],
];

const t = document.getElementById("t");
const cel = {};
for (const [nome, esperado] of LINHAS) {
  const tr = t.insertRow();
  tr.insertCell().textContent = nome;
  const c = tr.insertCell();
  c.className = "r wait";
  c.textContent = "…";
  cel[nome] = c;
  tr.insertCell().innerHTML = '<span class="note">' + esperado + "</span>";
}
const marca = (nome, ok, texto) => {
  const c = cel[nome];
  c.className = "r " + (ok ? "ok" : "bad");
  c.textContent = texto;
};

// O nome do handler vem do contrato; se a ponte não estiver registrada
// neste mundo, `bridge` é undefined — que é o comportamento correto para a
// pane web da Fase 1 e para qualquer subframe.
const ponte = window.webkit?.messageHandlers?.soyehtBridge;

marca(LINHAS[0][0], !!ponte, ponte ? "existe" : "AUSENTE");

const chamar = (corpo) => {
  if (!ponte) return Promise.reject(new Error("ponte ausente"));
  return ponte.postMessage(corpo);
};

// 1. o caminho feliz: capacidade declarada, comando conhecido.
chamar({ v: 1, id: "m1", command: "metrics.read" })
  .then((r) => {
    const m = r?.result?.["metrics.read"];
    marca(LINHAS[1][0], !!m, m ? `cpu ${m.cpuLoadPercent}% · up ${m.uptimeSeconds}s` : "sem resultado");
  })
  .catch((e) => marca(LINHAS[1][0], false, "RECUSOU: " + e.message));

// 2..5 — o que tem de ser recusado. Recusa é sucesso aqui.
const recusaEsperada = (i, corpo) =>
  chamar(corpo)
    .then(() => marca(LINHAS[i][0], false, "PASSOU"))
    .catch((e) => marca(LINHAS[i][0], true, "recusado: " + e.message));

recusaEsperada(2, { v: 1, id: "m2", command: "fs.read" });
recusaEsperada(3, { v: 1, id: "m3", command: "metrics.read", INJETADA: 1 });
recusaEsperada(4, { v: 1, id: "m4", command: "metrics.read", pad: "x".repeat(8192) });
recusaEsperada(5, "isto não é um objeto");

// 6. limite de taxa: dispara em rajada e espera que alguma seja recusada.
(async () => {
  let recusadas = 0;
  for (let i = 0; i < 40; i++) {
    try { await chamar({ v: 1, id: "r" + i, command: "metrics.read" }); }
    catch { recusadas++; }
  }
  marca(LINHAS[6][0], recusadas > 0, recusadas > 0
    ? `recusou ${recusadas} de 40`
    : "NENHUMA recusada em 40");
})();

// 7. o resultado do iframe chega por postMessage. Se ele conseguir falar
// com o nativo, a fase falhou — mesmo sendo de mesma origem que este
// documento, porque o direito é do frame principal, não da origem.
window.addEventListener("message", (ev) => {
  if (ev.data?.tipo !== "resultado-iframe") return;
  const conseguiu = ev.data.conseguiu;
  marca(LINHAS[7][0], !conseguiu, conseguiu ? "PASSOU — iframe falou com o nativo" : "negado: " + ev.data.motivo);
});
