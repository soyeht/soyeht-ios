// O app NÃO fala com o handler nativo diretamente: o handler vive num mundo
// isolado que o JS da página não enxerga. Quem atravessa é o relay, injetado
// pelo nativo nesse mundo e apenas no frame principal. O contrato de ida e
// volta é por evento de DOM.
const PEDIDO = "soyeht.bridge.request";
const RESPOSTA = "soyeht.bridge.response";

const LINHAS = [
  ["o relay atende neste frame", "atende"],
  ["metrics.read declarado → concedido", "concedido"],
  ["comando desconhecido", "recusado"],
  ["chave injetada no corpo", "recusado"],
  ["corpo acima do limite", "recusado"],
  ["corpo malformado", "recusado"],
  ["limite de taxa dispara", "recusado após rajada"],
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

// Correlação por id. Quem não responde em 3s conta como silêncio — que é
// um desfecho legítimo (relay ausente), distinto de recusa.
const pendentes = new Map();
window.addEventListener(RESPOSTA, (ev) => {
  const d = ev.detail || {};
  const p = pendentes.get(d.id);
  if (!p) return;
  pendentes.delete(d.id);
  p(d);
});

let n = 0;
const chamar = (corpo, { silencioEmMs = 3000 } = {}) =>
  new Promise((resolve) => {
    const id = "p" + ++n;
    // corpo pode ser propositalmente malformado; só injeta id se for objeto
    const detail = typeof corpo === "object" && corpo !== null ? { ...corpo, id } : corpo;
    const chave = typeof detail === "object" && detail !== null ? id : null;
    if (chave) {
      pendentes.set(chave, resolve);
      setTimeout(() => {
        if (pendentes.delete(chave)) resolve({ silencio: true });
      }, silencioEmMs);
    } else {
      // sem id não há correlação possível: espera o silêncio
      setTimeout(() => resolve({ silencio: true }), silencioEmMs);
    }
    window.dispatchEvent(new CustomEvent(PEDIDO, { detail }));
  });

const descreve = (d) =>
  d.silencio ? "silêncio" : d.ok ? "ok" : (d.error?.code || "erro") + ": " + (d.error?.message || "");

// Mostra o que veio sem depender de nomes de campo: um rename no schema não
// deve quebrar o probe, e listar tudo revela campo faltando ou inesperado.
const resumo = (m) =>
  Object.entries(m).map(([k, v]) => `${k}=${v}`).join(" · ");

// 1 e 2 — o caminho feliz prova que o relay atende E que a capacidade vale.
chamar({ v: 1, command: "metrics.read" }).then((d) => {
  marca(LINHAS[0][0], !d.silencio, d.silencio ? "SILÊNCIO — relay ausente" : "atende");
  const m = d.result?.["metrics.read"];
  marca(LINHAS[1][0], !!m, m ? resumo(m) : "sem resultado — " + descreve(d));
});

// 3..6 — recusa é sucesso. Silêncio aqui seria falha: o pedido chegou a um
// relay vivo (linha 1) e merece resposta explícita.
const recusaEsperada = (i, corpo) =>
  chamar(corpo).then((d) =>
    marca(LINHAS[i][0], !d.silencio && d.ok === false, d.ok ? "PASSOU" : descreve(d))
  );

recusaEsperada(2, { v: 1, command: "fs.read" });
recusaEsperada(3, { v: 1, command: "metrics.read", INJETADA: 1 });
recusaEsperada(4, { v: 1, command: "metrics.read", pad: "x".repeat(8192) });
recusaEsperada(5, { naoTemVersaoNemComando: true });

// 7 — rajada até o limite de taxa reagir.
(async () => {
  let recusadas = 0, atendidas = 0;
  for (let i = 0; i < 40; i++) {
    const d = await chamar({ v: 1, command: "metrics.read" }, { silencioEmMs: 1500 });
    if (d.ok) atendidas++;
    else if (!d.silencio) recusadas++;
  }
  marca(LINHAS[6][0], recusadas > 0,
    recusadas > 0 ? `${atendidas} atendidas, ${recusadas} recusadas` : `40 atendidas, NENHUMA recusada`);
})();

// 8 — o subframe relata o próprio desfecho.
window.addEventListener("message", (ev) => {
  if (ev.data?.tipo !== "resultado-iframe") return;
  const conseguiu = ev.data.conseguiu;
  marca(LINHAS[7][0], !conseguiu,
    conseguiu ? "PASSOU — subframe falou com o nativo" : "negado: " + ev.data.motivo);
});
