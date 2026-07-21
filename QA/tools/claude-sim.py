#!/usr/bin/env python3
"""claude-sim: emula o padrão de output do Claude Code (TUI Ink) para reproduzir
freeze de terminal sem custo de API.

Comportamentos emulados:
  - frames com synchronized output (CSI ?2026 h/l) a ~15 fps
  - repaint de bloco (cursor-up + erase-line) de 10-40 linhas estilizadas
  - linhas de "histórico" que rolam para o scrollback (acumulação real)
  - spinner + título OSC 0 periódico
  - query DSR (ESC[6n) periódica com leitura de resposta (timeout) — como TUIs reais
  - bursts de streaming (~configurável KB/s)

Telemetria (arquivo de log, uma linha a cada janela de 10s):
  ts iter bytes_total win_kbps max_write_ms dsr_ok dsr_fail last_dsr_rtt_ms
Se um write bloquear > STALL_S, loga "WRITE-STALL". Se o processo congelar de vez,
o log simplesmente para de crescer (detectável de fora pelo mtime).

Uso: uv run claude-sim.py /caminho/do/log [kbps_alvo]
"""
import os
import select
import signal
import sys
import termios
import time
import tty

ESC = "\x1b"
CSI = ESC + "["
STALL_S = 3.0

SPINNER = ["·", "✢", "✳", "∗", "✻", "✽"]
WORDS = (
    "Analisando arquivos do projeto para entender a estrutura atual e decidir "
    "o próximo passo da implementação conforme o plano acordado com o usuário "
).split()


def now():
    return time.monotonic()


class Sim:
    def __init__(self, log_path, kbps, read_stdin=True):
        self.log = open(log_path, "a", buffering=1)
        self.kbps = kbps
        # noread: emula uma TUI que parou de ler stdin (ex.: bloqueada no
        # próprio stdout) — dispara o deadlock de input no terminal antigo.
        self.read_stdin = read_stdin
        self.bytes_total = 0
        self.win_bytes = 0
        self.max_write_ms = 0.0
        self.dsr_ok = 0
        self.dsr_fail = 0
        self.last_dsr_rtt = -1.0
        self.iter = 0
        self.fd_in = sys.stdin.fileno()
        self.old_termios = None

    def logline(self, msg):
        self.log.write(f"{time.strftime('%H:%M:%S')} {msg}\n")

    def w(self, s):
        data = s.encode()
        t0 = now()
        sys.stdout.write(s)
        sys.stdout.flush()
        dt = (now() - t0) * 1000
        if dt > self.max_write_ms:
            self.max_write_ms = dt
        if dt > STALL_S * 1000:
            self.logline(f"WRITE-STALL {dt:.0f}ms iter={self.iter}")
        self.bytes_total += len(data)
        self.win_bytes += len(data)

    def dsr_probe(self):
        """Manda ESC[6n e espera ESC[r;cR até 2s."""
        t0 = now()
        self.w(CSI + "6n")
        buf = b""
        deadline = t0 + 2.0
        while now() < deadline:
            r, _, _ = select.select([self.fd_in], [], [], deadline - now())
            if not r:
                break
            chunk = os.read(self.fd_in, 64)
            if not chunk:
                break
            buf += chunk
            if b"R" in buf:
                self.dsr_ok += 1
                self.last_dsr_rtt = (now() - t0) * 1000
                return
        self.dsr_fail += 1
        self.last_dsr_rtt = -1.0
        self.logline(f"DSR-TIMEOUT iter={self.iter} buf={buf!r}")

    def history_line(self, i):
        c = 31 + (i % 6)
        words = " ".join(WORDS[(i + j) % len(WORDS)] for j in range(9))
        return f"{CSI}0;{c}m● {CSI}0m{words} {CSI}2m#{i}{CSI}0m\r\n"

    def frame(self, nlines, spin):
        """Um frame Ink-style: BSU, sobe N linhas, redesenha, ESU."""
        parts = [CSI + "?2026h"]
        parts.append(CSI + f"{nlines}A")
        for j in range(nlines):
            c = 32 + ((self.iter + j) % 5)
            bar = "█" * (1 + (self.iter + j * 7) % 60)
            parts.append(
                CSI + "2K" + f"{CSI}0;{c}m{SPINNER[spin % len(SPINNER)]} "
                f"{bar}{CSI}0m {CSI}2mtool-use {self.iter}.{j}{CSI}0m\r\n"
            )
        parts.append(CSI + "?2026l")
        self.w("".join(parts))

    def run(self):
        self.old_termios = termios.tcgetattr(self.fd_in)
        tty.setcbreak(self.fd_in)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        self.logline(f"START pid={os.getpid()} kbps_alvo={self.kbps} tty={os.ttyname(1)}")
        block = 24
        last_report = now()
        win_start = now()
        try:
            # área inicial do "frame"
            self.w("\r\n" * block)
            while True:
                self.iter += 1
                self.frame(block, self.iter)
                # a cada 10 frames, 3 linhas viram histórico (scrollback cresce)
                if self.iter % 10 == 0:
                    self.w(CSI + f"{block}A" + CSI + "1M" * 3)  # rola conteúdo
                    for k in range(3):
                        self.w(self.history_line(self.iter + k))
                    self.w("\r\n" * (block - 1) + CSI + "2K")
                if self.iter % 50 == 0:
                    self.w(ESC + f"]0;claude-sim · iter {self.iter}\x07")
                if self.read_stdin and self.iter % 500 == 0:
                    self.dsr_probe()
                # pacing pro alvo de kbps: só dorme quando ACIMA da meta
                elapsed = now() - win_start
                target = self.kbps * 1024 * elapsed
                if self.win_bytes > target:
                    time.sleep(min(0.5, (self.win_bytes - target) / (self.kbps * 1024)))
                elif self.iter % 20 == 0:
                    time.sleep(0.001)
                if now() - last_report >= 10:
                    kbps = self.win_bytes / 1024 / (now() - win_start)
                    self.logline(
                        f"OK iter={self.iter} total={self.bytes_total/1048576:.1f}MB "
                        f"win={kbps:.0f}KB/s max_write={self.max_write_ms:.0f}ms "
                        f"dsr_ok={self.dsr_ok} dsr_fail={self.dsr_fail} "
                        f"dsr_rtt={self.last_dsr_rtt:.0f}ms"
                    )
                    last_report = now()
                    win_start = now()
                    self.win_bytes = 0
                    self.max_write_ms = 0.0
        finally:
            termios.tcsetattr(self.fd_in, termios.TCSADRAIN, self.old_termios)
            self.logline(f"EXIT iter={self.iter} total={self.bytes_total/1048576:.1f}MB")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("uso: uv run claude-sim.py /caminho/log [kbps] [noread]", file=sys.stderr)
        sys.exit(2)
    Sim(
        sys.argv[1],
        float(sys.argv[2]) if len(sys.argv) > 2 else 80.0,
        read_stdin=not (len(sys.argv) > 3 and sys.argv[3] == "noread"),
    ).run()
