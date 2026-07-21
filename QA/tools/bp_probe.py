#!/usr/bin/env python3
"""bracketed-paste probe: inicia um CLI num PTY, captura a saída de init e
reporta se ele liga o bracketed paste mode (CSI ?2004h) — capacidade que
determina se a Opção B (colar literal) funciona nele. Custo zero de API:
só observa a inicialização do TUI, não submete nada ao modelo.

uso: uv run bp_probe.py <nome> <cmd...> [--secs N]
"""
import os
import pty
import select
import signal
import sys
import time

def main():
    args = sys.argv[1:]
    secs = 6.0
    if "--secs" in args:
        i = args.index("--secs")
        secs = float(args[i + 1])
        args = args[:i] + args[i + 2:]
    name, cmd = args[0], args[1:]

    pid, fd = pty.fork()
    if pid == 0:  # child
        os.environ["TERM"] = "xterm-256color"
        os.environ.setdefault("CI", "")  # não force modo não-interativo
        try:
            os.execvp(cmd[0], cmd)
        except Exception as e:
            os.write(2, f"exec fail: {e}\n".encode())
            os._exit(127)

    # pai: define tamanho de janela pra o TUI achar que é interativo
    import fcntl
    import struct
    import termios
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))

    buf = b""
    deadline = time.monotonic() + secs
    while time.monotonic() < deadline:
        r, _, _ = select.select([fd], [], [], 0.3)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
    try:
        os.kill(pid, signal.SIGTERM)
        time.sleep(0.3)
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.waitpid(pid, os.WNOHANG)

    enables_2004 = b"\x1b[?2004h" in buf
    # também detecta se pede DA/DSR (sinal de TUI rica) e bytes totais
    print(f"=== {name} ===")
    print(f"  bytes de init capturados: {len(buf)}")
    print(f"  liga bracketed paste (CSI ?2004h): {'SIM' if enables_2004 else 'NAO'}")
    print(f"  desliga bracketed paste (?2004l) visto: {'sim' if b'\x1b[?2004l' in buf else 'nao'}")
    print(f"  usa alt-screen (?1049h): {'sim' if b'\x1b[?1049h' in buf else 'nao'}")
    print(f"  usa synchronized output (?2026): {'sim' if b'?2026' in buf else 'nao'}")

if __name__ == "__main__":
    main()
