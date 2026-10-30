#!/usr/bin/env python3
"""
NADI Gym DevSecOps Cyber-Deception Honeypot
Author: Ellaxx7
Purpose: Intercept malicious scanners probing for /admin, /.env, /wp-admin
         Deploys a bait UI, logs intruder telemetry, autoplays video, and alerts Discord.
"""
import os
import json
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler

PORT = 8099
DISCORD_WEBHOOK_FILE = "/etc/gym/secrets/discord_webhook_url"
LOG_FILE = "/var/log/gym/honeypot.log"

def get_discord_webhook():
    if os.path.exists(DISCORD_WEBHOOK_FILE):
        try:
            with open(DISCORD_WEBHOOK_FILE, "r") as f:
                return f.read().strip()
        except Exception:
            pass
    return os.getenv("DISCORD_WEBHOOK_URL", "")

def send_discord_alert(ip, path, ua, action="Page Visit"):
    webhook_url = get_discord_webhook()
    if not webhook_url:
        return
    
    payload = {
        "embeds": [{
            "title": "🚨 HONEYPOT DETONATED: INTRUDER CAUGHT IN 4K",
            "description": f"**You have been pwned by Ellaxx7!**\nAn unauthorized user attempted to access protected canary routes.",
            "color": 15158332, # Vibrant Red
            "fields": [
                {"name": "Attacker IP", "value": f"`{ip}`", "inline": True},
                {"name": "Canary Path", "value": f"`{path}`", "inline": True},
                {"name": "Action Triggered", "value": f"**{action}**", "inline": True},
                {"name": "User-Agent", "value": f"```{ua[:150]}```", "inline": False},
                {"name": "Countermeasure", "value": "Troll video deployed & IP logged to forensic audit trail.", "inline": False}
            ],
            "footer": {"text": "Nadi DevSecOps Active HoneyWall · Lead Defense: Ellaxx7"}
        }]
    }
    try:
        req = urllib.request.Request(
            webhook_url,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json", "User-Agent": "Nadi-HoneyWall/1.0"}
        )
        urllib.request.urlopen(req, timeout=3.0)
    except Exception as e:
        print(f"Discord dispatch error: {e}")

def log_event(ip, path, ua, action):
    try:
        os.makedirs("/var/log/gym", exist_ok=True)
        entry = {
            "pwned_by": "Ellaxx7",
            "ip": ip,
            "path": path,
            "user_agent": ua,
            "action": action
        }
        with open(LOG_FILE, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception:
        pass

HTML_PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>NADI Gym — Enterprise Admin Console</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
    <style>
        body {
            font-family: 'Plus Jakarta Sans', sans-serif;
            background-color: #070a12;
            color: #f1f5f9;
        }
        .font-mono { font-family: 'JetBrains Mono', monospace; }
        .gym-ambient-bg {
            background-color: #070a12;
            background-image: 
                radial-gradient(at 0% 0%, rgba(56, 189, 248, 0.12) 0px, transparent 50%),
                radial-gradient(at 100% 0%, rgba(139, 92, 246, 0.15) 0px, transparent 50%),
                radial-gradient(at 50% 100%, rgba(30, 58, 138, 0.2) 0px, transparent 60%);
        }
        .nadi-glass-card {
            background: rgba(15, 23, 42, 0.85);
            backdrop-filter: blur(20px);
            border: 1px solid rgba(51, 65, 85, 0.6);
            box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.6), 0 0 40px rgba(59, 130, 246, 0.1);
        }
        .nadi-btn-primary {
            background: linear-gradient(135deg, #3b82f6 0%, #6366f1 100%);
            box-shadow: 0 4px 20px rgba(79, 110, 247, 0.4);
            transition: all 0.25s ease;
        }
        .nadi-btn-primary:hover {
            background: linear-gradient(135deg, #2563eb 0%, #4f46e5 100%);
            box-shadow: 0 6px 25px rgba(79, 110, 247, 0.6);
            transform: translateY(-1px);
        }
        .nadi-btn-danger {
            background: linear-gradient(135deg, #ef4444 0%, #dc2626 100%);
            box-shadow: 0 4px 20px rgba(239, 68, 68, 0.4);
            transition: all 0.25s ease;
        }
        .nadi-btn-danger:hover {
            transform: translateY(-2px);
            box-shadow: 0 8px 30px rgba(239, 68, 68, 0.7);
        }
        @keyframes pulse-alarm {
            0%, 100% { border-color: rgba(239, 68, 68, 0.4); }
            50% { border-color: rgba(239, 68, 68, 1); box-shadow: 0 0 50px rgba(239, 68, 68, 0.6); }
        }
        .alarm-border { animation: pulse-alarm 1.5s infinite; }
    </style>
</head>
<body class="gym-ambient-bg min-h-screen flex flex-col justify-between p-4 sm:p-6 lg:p-8">

    <!-- Header Navbar -->
    <header class="max-w-5xl w-full mx-auto flex items-center justify-between py-4 border-b border-slate-800/80">
        <div class="flex items-center space-x-3">
            <div class="w-10 h-10 rounded-xl bg-gradient-to-tr from-blue-600 to-indigo-500 flex items-center justify-center shadow-lg shadow-blue-500/30">
                <span class="text-white font-extrabold text-xl tracking-wider">N</span>
            </div>
            <div>
                <span class="font-bold text-lg tracking-tight text-white">NADI<span class="text-blue-500 font-extrabold ml-1">GYM</span></span>
                <span class="ml-2 px-2 py-0.5 text-[10px] uppercase font-mono font-bold tracking-widest bg-red-500/10 text-red-400 border border-red-500/30 rounded-md">RESTRICTED SRE CONSOLE</span>
            </div>
        </div>
        <div class="hidden sm:flex items-center space-x-4 text-xs font-mono text-slate-400">
            <span class="flex items-center"><span class="w-2 h-2 rounded-full bg-emerald-400 animate-pulse mr-2"></span>CLUSTER: ONLINE</span>
            <span>NODE: 178.18.249.160</span>
        </div>
    </header>

    <!-- Main Content Area -->
    <main class="max-w-3xl w-full mx-auto my-auto py-8">
        <!-- Initial Honeypot Bait Screen -->
        <div id="bait-card" class="nadi-glass-card rounded-2xl p-6 sm:p-8 border border-slate-800 space-y-6">
            <div class="flex items-center justify-between border-b border-slate-800 pb-4">
                <div class="flex items-center space-x-3">
                    <span class="text-2xl">🔐</span>
                    <div>
                        <h1 class="text-xl font-bold text-white">Root System Administration</h1>
                        <p class="text-xs text-slate-400">Authorized personnel only. All access attempts are cryptographically verified.</p>
                    </div>
                </div>
                <span class="text-xs font-mono text-amber-400 bg-amber-400/10 border border-amber-400/20 px-2.5 py-1 rounded-full">CONFIDENTIAL</span>
            </div>

            <div class="space-y-4">
                <div>
                    <label class="block text-xs font-mono uppercase tracking-wider text-slate-400 mb-2">Master Administrator Token</label>
                    <input type="password" value="••••••••••••••••••••••••••••••••" disabled class="w-full bg-slate-950/80 border border-slate-800 rounded-lg px-4 py-2.5 text-sm text-slate-300 font-mono focus:outline-none">
                </div>

                <!-- THE TEMPTING BAIT BUTTON -->
                <div class="pt-2">
                    <button id="pwn-button" onclick="triggerTrap()" class="nadi-btn-danger w-full py-4 px-6 rounded-xl text-white font-bold text-base flex items-center justify-center space-x-3 group cursor-pointer">
                        <span class="text-xl">📥</span>
                        <span>Download .env (Decrypted Production Secrets)</span>
                    </button>
                    <p class="text-[11px] text-center text-slate-500 font-mono mt-2">Emergency SRE Vault · Includes DB Passwords & Stripe Secret Keys</p>
                </div>
            </div>
        </div>

        <!-- The "You Have Been Pwned" Detonation Modal / Screen -->
        <div id="trap-card" class="hidden nadi-glass-card alarm-border rounded-2xl p-6 sm:p-8 border-2 border-red-500 space-y-6 text-center">
            <div class="space-y-2">
                <div class="inline-block p-3 bg-red-500/10 rounded-2xl border border-red-500/30 text-3xl">💀</div>
                <h2 class="text-2xl sm:text-3xl font-extrabold text-transparent bg-clip-text bg-gradient-to-r from-red-400 via-rose-300 to-amber-300">
                    YOU HAVE BEEN PWNED BY Ellaxx7
                </h2>
                <p class="text-sm text-red-300 font-mono">
                    🚨 INTRUSION DETECTED &amp; LOGGED IN 4K · DISCORD SOC ALERT FIRED
                </p>
            </div>

            <!-- Intruder Details Box -->
            <div class="bg-slate-950/90 rounded-xl p-4 border border-slate-800 text-left font-mono text-xs space-y-1 text-slate-300">
                <div class="flex justify-between"><span class="text-slate-500">Target Asset:</span> <span class="text-amber-400 font-bold">/.env secrets harvesting attempt</span></div>
                <div class="flex justify-between"><span class="text-slate-500">Security Officer:</span> <span class="text-emerald-400 font-bold">Ellaxx7 (DevOps Lead)</span></div>
                <div class="flex justify-between"><span class="text-slate-500">Forensic Status:</span> <span class="text-rose-400 font-bold">Fingerprint forwarded to Discord</span></div>
            </div>

            <!-- The Requested Troll Video -->
            <div class="rounded-xl overflow-hidden border border-slate-800 shadow-2xl aspect-video bg-black">
                <iframe id="troll-video" class="w-full h-full" src="" title="Pwned by Ellaxx7" frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>
            </div>

            <div class="pt-2">
                <p class="text-xs font-mono text-slate-400">Next time, try finding a real vulnerability 😉</p>
                <a href="/download/" class="inline-block mt-3 text-xs font-mono text-blue-400 hover:text-blue-300 underline">← Return to Official NADI Download Portal</a>
            </div>
        </div>
    </main>

    <footer class="max-w-5xl w-full mx-auto text-center text-xs text-slate-600 font-mono py-4 border-t border-slate-900">
        Nadi Gym DevSecOps Autonomous HoneyWall · Guarded by Ellaxx7 · AlmaLinux 9
    </footer>

    <script>
        function triggerTrap() {
            // 1. Hide bait, show trap card
            document.getElementById('bait-card').classList.add('hidden');
            document.getElementById('trap-card').classList.remove('hidden');

            // 2. Play the requested YouTube video with autoplay
            document.getElementById('troll-video').src = "https://www.youtube.com/embed/Aq5WXmQQooo?autoplay=1&enablejsapi=1";

            // 3. Notify the backend honeypot API to fire Discord alert
            fetch('/api/honeypot/trigger', { method: 'POST' }).catch(() => {});
        }
    </script>
</body>
</html>
"""

CLI_TROLL_PAYLOAD = """
# ==============================================================================
# 🚨 NADI GYM DEFENSE GRID: YOU HAVE BEEN PWNED BY Ellaxx7 🚨
# ==============================================================================
# Nice try scanning for sensitive configuration files!
# Your IP address and User-Agent have been fingerprinted and dispatched to SOC.
#
# Watch proof of your defeat:
# https://www.youtube.com/watch?v=Aq5WXmQQooo
# ==============================================================================
APP_ENV=honeypot_trap
SECURITY_LEAD=Ellaxx7
STATUS=CAUGHT_IN_4K
FLAG=FLAG{Ellaxx7_HONEYPOT_PWNED_YOU}
"""

class HoneypotHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Suppress standard noisy stdout logging
        pass

    def get_client_ip(self):
        return self.headers.get("X-Forwarded-For", self.client_address[0]).split(",")[0].strip()

    def do_POST(self):
        client_ip = self.get_client_ip()
        ua = self.headers.get("User-Agent", "Unknown")
        
        # Clicked the download .env button
        send_discord_alert(client_ip, self.path, ua, action="Clicked 'Download .env' Button")
        log_event(client_ip, self.path, ua, "BUTTON_CLICK_PWNED")
        
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Pwned-By", "Ellaxx7")
        self.end_headers()
        self.wfile.write(json.dumps({"status": "pwned", "by": "Ellaxx7"}).encode())

    def do_GET(self):
        client_ip = self.get_client_ip()
        ua = self.headers.get("User-Agent", "Unknown")
        
        # If user visits via curl or requests .env directly:
        if self.path.endswith(".env") or "curl" in ua.lower():
            send_discord_alert(client_ip, self.path, ua, action="Direct CLI .env probe")
            log_event(client_ip, self.path, ua, "CLI_ENV_PROBE")
            
            self.send_response(418) # I'm a teapot
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("X-Pwned-By", "Ellaxx7")
            self.end_headers()
            self.wfile.write(CLI_TROLL_PAYLOAD.encode("utf-8"))
            return

        # Otherwise render the visual admin console bait page
        send_discord_alert(client_ip, self.path, ua, action="Admin Page Reconnaissance")
        log_event(client_ip, self.path, ua, "WEB_ADMIN_VIEW")
        
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("X-Pwned-By", "Ellaxx7")
        self.end_headers()
        self.wfile.write(HTML_PAGE.encode("utf-8"))

if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", PORT), HoneypotHandler)
    print(f"Nadi Honeypot active on 127.0.0.1:{PORT} (Guarded by Ellaxx7)")
    server.serve_forever()
