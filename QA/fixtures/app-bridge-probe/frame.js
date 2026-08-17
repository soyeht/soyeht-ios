// Este subframe tem a MESMA ORIGEM do documento pai, então passa em
// qualquer comparação de origem. O que deve barrá-lo é o direito ser do
// frame principal — e o relay não ser injetado aqui.
//
// Duas tentativas, porque há duas portas: o handler pode existir e recusar,
// ou não existir de todo. As duas contam como negado; só falar com o nativo
// e receber métrica conta como falha.
const relatar = (conseguiu, motivo) => {
  document.getElementById("s").innerHTML =
    "<code>" + (conseguiu ? "CONSEGUIU — " : "negado — ") + motivo + "</code>";
  parent.postMessage({ tipo: "resultado-iframe", conseguiu, motivo }, "*");
};

const ponte = window.webkit?.messageHandlers?.soyehtBridge;

if (!ponte) {
  relatar(false, "handler ausente neste frame");
} else {
  // O handler existe aqui (é instalado em todos os frames, sempre).
  // A recusa tem de vir da validação de principal no nativo.
  ponte
    .postMessage({ v: 1, id: "iframe", command: "metrics.read" })
    .then((r) => {
      const m = r?.result?.["metrics.read"];
      relatar(!!m, m ? "recebeu métricas do nativo" : "respondeu sem resultado");
    })
    .catch((e) => relatar(false, "recusado pelo nativo: " + e.message));
}
