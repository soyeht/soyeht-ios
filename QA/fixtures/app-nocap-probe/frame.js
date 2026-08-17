// Este subframe tem a MESMA ORIGEM do documento pai, então passa em
// qualquer comparação de origem. O que deve barrá-lo é o direito pertencer
// ao frame principal: o relay é injetado com forMainFrameOnly, logo não
// existe aqui.
//
// Dois desfechos contam como negado — silêncio (relay ausente) e recusa
// explícita do nativo. Só receber métrica conta como falha do produto.
const PEDIDO = "soyeht.bridge.request";
const RESPOSTA = "soyeht.bridge.response";

const relatar = (conseguiu, motivo) => {
  document.getElementById("s").innerHTML =
    "<code>" + (conseguiu ? "CONSEGUIU — " : "negado — ") + motivo + "</code>";
  parent.postMessage({ tipo: "resultado-iframe", conseguiu, motivo }, "*");
};

let respondeu = false;
window.addEventListener(RESPOSTA, (ev) => {
  respondeu = true;
  const d = ev.detail || {};
  const m = d.result?.["metrics.read"];
  if (m) relatar(true, "recebeu métricas do nativo");
  else relatar(false, "recusado: " + (d.error?.code || "sem resultado"));
});

window.dispatchEvent(
  new CustomEvent(PEDIDO, { detail: { v: 1, id: "iframe", command: "metrics.read" } })
);

// Silêncio é o desfecho esperado: sem relay neste frame, o evento não
// atravessa para o mundo isolado e ninguém responde.
setTimeout(() => {
  if (!respondeu) relatar(false, "silêncio — relay não injetado neste frame");
}, 3000);
