"""Fala para Windows: a janela. Liga o PC ao iPhone (QR), mostra se está ligado à internet e as contas Claude/ChatGPT.
O servidor (ecrã, rato, colar, sessões) corre em fundo; fechar a janela só a esconde na barra de tarefas (minimiza)."""
import ctypes, os, sys, threading, tkinter as tk, winreg
from tkinter import messagebox
import segno
import config, accounts

BG, CARD, INK, MUTED, LINE = "#F4F2F5", "#FFFFFF", "#1A1A1A", "#6B6B61", "#E4E2E6"
ORANGE, GREEN, RED = "#FEA946", "#0B4D3E", "#B3261E"
FONT = "Segoe UI"
RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"

def exe_cmd():
    return f'"{sys.executable}" --hidden' if getattr(sys, "frozen", False) else f'"{sys.executable}" "{os.path.abspath(__file__)}" --hidden'

def autostart(on=None):
    """Abrir com o Windows (HKCU\\...\\Run). on=None só lê."""
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_ALL_ACCESS) as k:
        if on is True: winreg.SetValueEx(k, "Fala", 0, winreg.REG_SZ, exe_cmd())
        elif on is False:
            try: winreg.DeleteValue(k, "Fala")
            except FileNotFoundError: pass
        try: winreg.QueryValueEx(k, "Fala"); return True
        except FileNotFoundError: return False

class App:
    def __init__(self, root):
        self.root = root
        # Ecrãs com escala (125 a 200%): o processo vê píxeis reais (screen.py), por isso tudo cresce com o DPI.
        try: self.k = ctypes.windll.user32.GetDpiForSystem() / 96
        except Exception: self.k = 1
        root.tk.call("tk", "scaling", 96 * self.k / 72)
        z = self.z
        root.title("Fala"); root.configure(bg=BG); root.geometry(f"{z(760)}x{z(520)}"); root.minsize(z(680), z(480))
        try: root.iconbitmap(os.path.join(config.BUNDLE, "fala.ico"))
        except Exception: pass
        root.protocol("WM_DELETE_WINDOW", root.iconify)  # continua a correr: o iPhone precisa dele

        head = tk.Frame(root, bg=BG); head.pack(fill="x", padx=z(28), pady=(z(22), z(8)))
        tk.Label(head, text="Fala", font=(FONT, 22, "bold"), bg=BG, fg=INK).pack(side="left")
        self.status = tk.Label(head, text="● A ligar…", font=(FONT, 11), bg=BG, fg=MUTED); self.status.pack(side="right")

        body = tk.Frame(root, bg=BG); body.pack(fill="both", expand=True, padx=z(28))
        left = self.card(body); left.pack(side="left", fill="y", padx=(0, z(14)))
        tk.Label(left, text="Liga o iPhone", font=(FONT, 14, "bold"), bg=CARD, fg=INK).pack(anchor="w")
        tk.Label(left, text="App Fala no iPhone › menu ☰ › Ligar ao PC (QR)", font=(FONT, 10), bg=CARD, fg=MUTED).pack(anchor="w", pady=(z(2), z(10)))
        self.qr = tk.Canvas(left, width=z(230), height=z(230), bg=CARD, highlightthickness=0); self.qr.pack()
        self.code = tk.Label(left, font=("Consolas", 11), bg=CARD, fg=MUTED); self.code.pack(pady=(10, 0))
        tk.Button(left, text="Gerar código novo", command=self.new_code, relief="flat", bg=CARD, fg=MUTED, font=(FONT, 9), cursor="hand2",
                  activebackground=CARD).pack(pady=(4, 0))

        right = self.card(body); right.pack(side="left", fill="both", expand=True)
        tk.Label(right, text="Contas de IA", font=(FONT, 14, "bold"), bg=CARD, fg=INK).pack(anchor="w")
        tk.Label(right, text="As tuas sessões do Claude e do ChatGPT (Codex) aparecem no iPhone.\nO login é teu, no browser deste PC.",
                 font=(FONT, 10), bg=CARD, fg=MUTED, justify="left").pack(anchor="w", pady=(2, 12))
        self.rows = {w: self.account_row(right, w) for w in ("claude", "codex")}
        tk.Frame(right, bg=LINE, height=1).pack(fill="x", pady=14)
        self.auto = tk.BooleanVar(value=autostart())
        tk.Checkbutton(right, text="Abrir a Fala quando o Windows arranca", variable=self.auto, command=lambda: autostart(self.auto.get()),
                       bg=CARD, fg=INK, font=(FONT, 10), activebackground=CARD, selectcolor=CARD).pack(anchor="w")
        tk.Label(right, text="Com a Fala aberta, o iPhone vê e controla este PC de qualquer rede\n(ecrã ao vivo, rato com o dedo, teclado e ditado).",
                 font=(FONT, 10), bg=CARD, fg=MUTED, justify="left").pack(anchor="w", pady=(12, 0))
        self.msg = tk.Label(root, text="", font=(FONT, 10), bg=BG, fg=MUTED); self.msg.pack(pady=(8, 14))

        self.draw_qr(); self.tick(); self.refresh_accounts()

    def z(self, v): return int(v * self.k)

    def card(self, parent):
        return tk.Frame(parent, bg=CARD, highlightbackground=LINE, highlightthickness=1, padx=self.z(20), pady=self.z(18))

    def account_row(self, parent, which):
        f = tk.Frame(parent, bg=CARD); f.pack(fill="x", pady=4)
        name = tk.Label(f, text="Claude" if which == "claude" else "ChatGPT", font=(FONT, 12, "bold"), bg=CARD, fg=INK, width=9, anchor="w"); name.pack(side="left")
        state = tk.Label(f, text="…", font=(FONT, 10), bg=CARD, fg=MUTED); state.pack(side="left")
        btn = tk.Button(f, text="Entrar", font=(FONT, 10, "bold"), bg=INK, fg="white", relief="flat", padx=self.z(14), pady=self.z(4), cursor="hand2",
                        activebackground="#333", activeforeground="white", command=lambda: self.login(which))
        btn.pack(side="right")
        return state, btn

    def draw_qr(self):
        c = self.qr; c.delete("all")
        m = segno.make(config.pair_url(), error="m").matrix
        n = len(m) + 8; px = self.z(230) / n
        for y, row in enumerate(m):
            for x, v in enumerate(row):
                if v: c.create_rectangle((x + 4) * px, (y + 4) * px, (x + 5) * px, (y + 5) * px, fill=INK, outline=INK)
        k = config.code()
        self.code.config(text=" ".join(k[i:i + 4] for i in range(0, len(k), 4)))

    def new_code(self):
        if not messagebox.askyesno("Fala", "Gerar um código novo? Os iPhones ligados a este PC têm de ler o QR outra vez."): return
        config.code(new=True)
        os.execv(sys.executable, [sys.executable] + ([] if getattr(sys, "frozen", False) else [os.path.abspath(__file__)]))  # recomeça com o código novo

    def tick(self):
        import relay_link
        on = relay_link.status.get("relay")
        self.status.config(text="● Ligada à internet" if on else "● Sem internet (só rede de casa)", fg=GREEN if on else ORANGE)
        self.root.after(3000, self.tick)

    def refresh_accounts(self):
        def work():
            st = accounts.status()
            self.root.after(0, lambda: self.show_accounts(st))
        threading.Thread(target=work, daemon=True).start()
        self.root.after(20000, self.refresh_accounts)

    def show_accounts(self, st):
        for w, (label, btn) in self.rows.items():
            a = st[w]
            if a["loggedIn"]: label.config(text="Ligado ✓", fg=GREEN); btn.config(text="Trocar")
            elif a["installed"]: label.config(text="Não ligado", fg=MUTED); btn.config(text="Entrar")
            else: label.config(text="Não instalado", fg=MUTED); btn.config(text="Instalar")

    def login(self, which):
        self.msg.config(text=accounts.login(which))
        self.root.after(15000, self.refresh_accounts)

def main():
    import server
    try: server.start()
    except OSError:
        tk.Tk().withdraw(); messagebox.showinfo("Fala", "A Fala já está aberta neste PC."); return
    if not os.path.exists(os.path.join(config.DATA, ".autostart-set")):  # 1.ª vez: abre com o Windows (pode desligar-se na janela)
        autostart(True); open(os.path.join(config.DATA, ".autostart-set"), "w").close()
    root = tk.Tk(); App(root)
    if "--hidden" in sys.argv: root.iconify()
    root.mainloop()

if __name__ == "__main__":
    main()
