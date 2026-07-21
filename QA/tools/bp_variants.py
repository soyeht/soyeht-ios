#!/usr/bin/env python3
# /// script
# dependencies = ["pyte"]
# ///
"""Testa variantes de terminador para fechar o popup de @mention antes do Enter,
sem corromper a mensagem. Para cada variante: entrega o payload, faz as ações,
manda Enter real, e renderiza o resultado pra ver se SUBMETEU LIMPO (input
esvaziou / virou processando) ou se CORROMPEU (token virou arquivo) / TRAVOU.

uso: uv run bp_variants.py <variante> <cmd...>
variantes:
  raw_plain     digita '...@jov' cru + Enter            (baseline: corrompe)
  raw_space     digita '...@jov ' (espaço) cru + Enter
  bp_space      bracketed paste '...@jov ' + Enter
  raw_esc       digita '...@jov' + ESC + Enter
  bp_then_space bracketed paste '...@jov', depois espaço fora do paste + Enter
"""
import os, pty, select, signal, struct, sys, time, fcntl, termios
import pyte

BP_START, BP_END = b"\x1b[200~", b"\x1b[201~"
BASE = b"confirma a correcao final com a @jov"

def drain(fd, secs):
    out=b""; end=time.monotonic()+secs
    while time.monotonic()<end:
        r,_,_=select.select([fd],[],[],0.2)
        if r:
            try:c=os.read(fd,65536)
            except OSError:break
            if not c:break
            out+=c
    return out

def type_raw(fd, b):
    for ch in b:
        os.write(fd, bytes([ch])); time.sleep(0.004)

def main():
    var, cmd = sys.argv[1], sys.argv[2:]
    pid, fd = pty.fork()
    if pid==0:
        os.environ["TERM"]="xterm-256color"; os.execvp(cmd[0],cmd); os._exit(127)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH",40,120,0,0))
    data=drain(fd,6.0)

    if var=="raw_plain":
        type_raw(fd, BASE)
    elif var=="raw_space":
        type_raw(fd, BASE+b" ")
    elif var=="bp_space":
        os.write(fd, BP_START+BASE+b" "+BP_END)
    elif var=="raw_esc":
        type_raw(fd, BASE); time.sleep(0.3); os.write(fd, b"\x1b")
    elif var=="bp_then_space":
        os.write(fd, BP_START+BASE+BP_END); time.sleep(0.3); os.write(fd, b" ")
    else:
        print("variante desconhecida"); return
    data+=drain(fd,1.5)
    os.write(fd, b"\r")               # Enter real
    data+=drain(fd,3.0)

    scr=pyte.Screen(120,40); st=pyte.Stream(scr); st.feed(data.decode("utf-8","replace"))
    ne=[l.rstrip() for l in scr.display if l.strip()]
    print(f"===== VARIANTE: {var} =====")
    for l in ne[-12:]: print("|", l)
    joined="\n".join(ne)
    substituted = ".txt" in joined and "@jov" not in joined  # token virou arquivo
    literal_present = "@jov " in joined or "@jov\n" in joined or joined.rstrip().endswith("@jov")
    print(f">>> token corrompido p/ arquivo (@...txt): {'SIM' if substituted else 'nao'}")
    print(f">>> '@jov' literal ainda presente: {'sim' if literal_present else 'nao'}")
    print()
    try:
        os.kill(pid,signal.SIGTERM); time.sleep(0.2); os.kill(pid,signal.SIGKILL)
    except ProcessLookupError: pass
    try: os.waitpid(pid,os.WNOHANG)
    except ChildProcessError: pass

if __name__=="__main__":
    main()
