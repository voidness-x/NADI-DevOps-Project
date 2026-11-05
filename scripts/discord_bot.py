import os
import asyncio
import subprocess
import json
import urllib.request
import discord
from discord import app_commands
from discord.ext import commands

TOKEN = os.getenv("DISCORD_BOT_TOKEN", "").strip('"')
AUTHORIZED_USER = os.getenv("AUTHORIZED_USER", "voidness.x").strip('"')

intents = discord.Intents.default()
intents.message_content = True

class NadiBot(commands.Bot):
    def __init__(self):
        super().__init__(command_prefix="!", intents=intents, help_command=None)

    async def on_ready(self):
        print(f"Nadi ChatOps Bot online as {self.user} (Operator: {AUTHORIZED_USER})")
        # Instant guild sync (bypasses 1-hour global Discord cache)
        for guild in self.guilds:
            try:
                self.tree.copy_global_to(guild=guild)
                synced = await self.tree.sync(guild=guild)
                print(f"⚡ Synced {len(synced)} slash commands to: {guild.name}")
            except Exception as e:
                print(f"Sync error for {guild.name}: {e}")

bot = NadiBot()

class CommandResult:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr

async def run_cmd_async(cmd, timeout=30):
    try:
        proc = await asyncio.to_thread(
            subprocess.run,
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout
        )
        return proc
    except subprocess.TimeoutExpired:
        return CommandResult(
            returncode=124,
            stdout="",
            stderr=f"Command timed out after {timeout} seconds."
        )
    except Exception as ex:
        return CommandResult(
            returncode=1,
            stdout="",
            stderr=str(ex)
        )

@bot.tree.error
async def on_app_command_error(interaction: discord.Interaction, error: app_commands.AppCommandError):
    print(f"App command error: {error}")
    msg = f"❌ Command execution error: {error}"
    try:
        if interaction.response.is_done():
            await interaction.followup.send(msg, ephemeral=True)
        else:
            await interaction.response.send_message(msg, ephemeral=True)
    except Exception as e:
        print(f"Failed to deliver error response: {e}")

def is_authorized(user):
    allowed = {AUTHORIZED_USER.lower(), "voidness.x", "ellaxx7"}
    u_name = str(getattr(user, "name", "")).lower()
    d_name = str(getattr(user, "display_name", "")).lower()
    return u_name in allowed or d_name in allowed

def get_status_embed():
    try:
        with open("/opt/gym/state/active_slot", "r") as f:
            active_slot = f.read().strip()
    except Exception:
        active_slot = "unknown"

    try:
        ps_out = subprocess.check_output(
            ["docker", "ps", "--format", "table {{.Names}}\t{{.Status}}\t{{.Ports}}"],
            stderr=subprocess.STDOUT, text=True, timeout=5
        ).strip()
    except Exception as e:
        ps_out = f"Error: {e}"

    try:
        mem_out = subprocess.check_output(["free", "-m"], text=True).strip()
    except Exception:
        mem_out = "N/A"

    embed = discord.Embed(
        title="🖥️ Nadi Production Cluster Status",
        color=0x2ecc71 if active_slot in ["blue", "green"] else 0xe74c3c
    )
    embed.add_field(name="Active Slot", value=f"**`{active_slot.upper()}`**", inline=True)
    embed.add_field(name="Ingress Gateway", value="Caddy Reverse Proxy (8000/8001)", inline=True)
    embed.add_field(name="Containers", value=f"```\n{ps_out[:800]}\n```", inline=False)
    embed.add_field(name="Memory (MB)", value=f"```\n{mem_out}\n```", inline=False)
    return embed

# -------------------------------------------------------------
# COMMANDS
# -------------------------------------------------------------
@bot.command(name="help")
async def help_cmd(ctx):
    embed = discord.Embed(
        title="🛠️ Nadi DevOps ChatOps Commands",
        description="Supported prefixes: `!` text commands and `/` native slash commands.",
        color=0x3498db
    )
    embed.add_field(name="Cluster Operations", value="`!status` / `/status` — Active slot, containers, memory\n`!switch <slot>` / `/switch` — Zero-downtime cutover\n`!rollback` — Revert to alternate slot", inline=False)
    embed.add_field(name="Performance & Telemetry", value="`!benchmark` / `/benchmark` — 25-request in-flight load test\n`!logs <backend|caddy|db>` — Tail live service logs", inline=False)
    embed.add_field(name="Mobile APK", value="`!apk` / `/apk` — Latest mobile Android release & SHA-256 hash", inline=False)
    embed.set_footer(text=f"Authorized Operator: {AUTHORIZED_USER}")
    await ctx.reply(embed=embed)

@bot.tree.command(name="help", description="Show available ChatOps commands and syntax")
async def help_slash(interaction: discord.Interaction):
    embed = discord.Embed(
        title="🛠️ Nadi DevOps ChatOps Commands",
        description="Supported prefixes: `!` text commands and `/` native slash commands.",
        color=0x3498db
    )
    embed.add_field(name="Cluster Operations", value="`!status` / `/status` — Active slot, containers, memory\n`!switch <slot>` / `/switch` — Zero-downtime cutover\n`!rollback` — Revert to alternate slot", inline=False)
    embed.add_field(name="Performance & Telemetry", value="`!benchmark` / `/benchmark` — 25-request in-flight load test\n`!logs <backend|caddy|db>` — Tail live service logs", inline=False)
    embed.add_field(name="Mobile APK", value="`!apk` / `/apk` — Latest mobile Android release & SHA-256 hash", inline=False)
    embed.set_footer(text=f"Authorized Operator: {AUTHORIZED_USER}")
    await interaction.response.send_message(embed=embed)

@bot.command(name="status")
async def status_prefix(ctx):
    if not is_authorized(ctx.author): return
    embed = await asyncio.to_thread(get_status_embed)
    await ctx.reply(embed=embed)

@bot.tree.command(name="status", description="Inspect active slot, container health, and memory telemetry")
async def status_slash(interaction: discord.Interaction):
    if not is_authorized(interaction.user):
        await interaction.response.send_message("⛔ Unauthorized", ephemeral=True)
        return
    await interaction.response.defer()
    try:
        embed = await asyncio.to_thread(get_status_embed)
        await interaction.followup.send(embed=embed)
    except Exception as ex:
        await interaction.followup.send(f"❌ Failed to retrieve status: {ex}")

@bot.command(name="switch")
async def switch_prefix(ctx, slot: str = ""):
    if not is_authorized(ctx.author): return
    slot = slot.lower().strip()
    if slot not in ["blue", "green"]:
        await ctx.reply("⚠️ Usage: `!switch blue` or `!switch green`")
        return
    m = await ctx.reply(f"🔄 Switching production traffic to **`{slot.upper()}`**...")
    proc = await run_cmd_async(["sudo", "/usr/local/bin/switch_slot.sh", slot], timeout=25)
    if proc.returncode == 0:
        await m.edit(content=f"🚀 Traffic successfully switched to **`{slot.upper()}`** with zero downtime!")
    else:
        err = proc.stderr.strip() or proc.stdout.strip()
        await m.edit(content=f"❌ Switch failed:\n```{err[-300:]}```")

@bot.tree.command(name="switch", description="Atomic zero-downtime cutover between Blue and Green slots")
@app_commands.choices(slot=[
    app_commands.Choice(name="Blue Slot (Port 8101/8201)", value="blue"),
    app_commands.Choice(name="Green Slot (Port 8102/8202)", value="green"),
])
async def switch_slash(interaction: discord.Interaction, slot: app_commands.Choice[str]):
    if not is_authorized(interaction.user):
        await interaction.response.send_message("⛔ Unauthorized", ephemeral=True)
        return
    await interaction.response.defer()
    try:
        proc = await run_cmd_async(["sudo", "/usr/local/bin/switch_slot.sh", slot.value], timeout=25)
        if proc.returncode == 0:
            await interaction.followup.send(f"🚀 Ingress traffic switched to **`{slot.value.upper()}`** with zero downtime!")
        else:
            err = proc.stderr.strip() or proc.stdout.strip()
            await interaction.followup.send(f"❌ Switch failed: `{err}`")
    except Exception as ex:
        await interaction.followup.send(f"❌ Switch error: {ex}")

@bot.command(name="benchmark")
async def benchmark_prefix(ctx):
    if not is_authorized(ctx.author): return
    m = await ctx.reply("⚡ Running Zero-Downtime Benchmark (25 requests across reload)...")
    try:
        proc = await run_cmd_async(["python3", "/opt/gym/devops/scripts/benchmark_switch.py"], timeout=45)
        report = proc.stdout if proc.returncode == 0 else f"{proc.stdout}\n{proc.stderr}"
        filtered = [l for l in report.split("\n") if "REQ #" not in l and not l.startswith("#")]
        text = "\n".join(filtered).strip()
        if not text:
            text = proc.stderr.strip() or "Benchmark completed with no output."
        if len(text) > 1900:
            text = text[-1900:]
        await m.edit(content=f"```{text}```")
    except Exception as ex:
        await m.edit(content=f"❌ Benchmark execution error: {ex}")

@bot.tree.command(name="benchmark", description="Run 25-request in-flight load test verifying 100% zero downtime")
async def benchmark_slash(interaction: discord.Interaction):
    if not is_authorized(interaction.user):
        await interaction.response.send_message("⛔ Unauthorized", ephemeral=True)
        return
    await interaction.response.defer()
    try:
        proc = await run_cmd_async(["python3", "/opt/gym/devops/scripts/benchmark_switch.py"], timeout=45)
        report = proc.stdout if proc.returncode == 0 else f"{proc.stdout}\n{proc.stderr}"
        lines = [l for l in report.split("\n") if "REQ #" not in l and not l.startswith("#")]
        text = "\n".join(lines).strip()
        if not text:
            text = proc.stderr.strip() or "Benchmark completed with no output."
        if len(text) > 1900:
            text = text[-1900:]
        await interaction.followup.send(f"```{text}```")
    except Exception as ex:
        await interaction.followup.send(f"❌ Benchmark execution failed: `{ex}`")

def load_apk_info():
    d = json.load(open("/srv/apk/version.json"))
    mb = d.get('size_bytes', 0) / 1048576
    embed = discord.Embed(title="📱 Nadi Gym Mobile Android Release", color=0x2ecc71)
    embed.add_field(name="Version", value=f"`{d.get('tag', 'unknown')}`", inline=True)
    embed.add_field(name="Size", value=f"{mb:.1f} MB", inline=True)
    embed.add_field(name="Published", value=d.get('published_at', 'N/A'), inline=False)
    embed.add_field(name="SHA-256 Checksum", value=f"`{d.get('sha256', 'N/A')}`", inline=False)
    embed.add_field(name="Download Portal", value="https://178.18.249.160:8001/download/", inline=False)
    return embed

@bot.command(name="apk")
async def apk_cmd(ctx):
    try:
        embed = await asyncio.to_thread(load_apk_info)
        await ctx.reply(embed=embed)
    except Exception as ex:
        await ctx.reply(f"❌ Error: {ex}")

@bot.tree.command(name="apk", description="Get latest mobile Android APK release and SHA-256 hash")
async def apk_slash(interaction: discord.Interaction):
    await interaction.response.defer()
    try:
        embed = await asyncio.to_thread(load_apk_info)
        await interaction.followup.send(embed=embed)
    except Exception as ex:
        await interaction.followup.send(f"❌ Error: {ex}", ephemeral=True)

@bot.command(name="logs")
async def logs_cmd(ctx, service: str = "backend"):
    if not is_authorized(ctx.author): return
    service = service.lower().strip()
    if service == "caddy":
        cmd = ["sudo", "journalctl", "-u", "caddy", "-n", "15", "--no-pager"]
    elif service == "webhook":
        cmd = ["sudo", "journalctl", "-u", "gym-webhook", "-n", "15", "--no-pager"]
    elif service == "db":
        cmd = ["docker", "logs", "--tail", "15", "gym-postgres"]
    else:
        slot = (await asyncio.to_thread(subprocess.getoutput, "cat /opt/gym/state/active_slot 2>/dev/null || echo blue")).strip()
        cmd = ["docker", "logs", "--tail", "15", f"gym-{slot}-backend"]
    proc = await run_cmd_async(cmd, timeout=15)
    out = proc.stdout or proc.stderr
    await ctx.reply(f"📋 **Logs for `{service}`:**\n```{out[-1800:]}```")

@bot.command(name="rollback")
async def rollback_cmd(ctx):
    if not is_authorized(ctx.author): return
    curr = (await asyncio.to_thread(subprocess.getoutput, "cat /opt/gym/state/active_slot 2>/dev/null || echo blue")).strip()
    target = "green" if curr == "blue" else "blue"
    m = await ctx.reply(f"🚨 Rolling back to **`{target.upper()}`**...")
    proc = await run_cmd_async(["sudo", "/usr/local/bin/switch_slot.sh", target], timeout=25)
    if proc.returncode == 0:
        await m.edit(content=f"🛡️ Rollback complete! Live slot: **`{target.upper()}`**.")
    else:
        err = proc.stderr.strip() or proc.stdout.strip()
        await m.edit(content=f"❌ Error:\n```{err[-300:]}```")

@bot.command(name="deploy")
async def deploy_cmd(ctx, slot: str = ""):
    if not is_authorized(ctx.author): return
    curr = (await asyncio.to_thread(subprocess.getoutput, "cat /opt/gym/state/active_slot 2>/dev/null || echo blue")).strip()
    target = slot.lower().strip() if slot in ["blue", "green"] else ("green" if curr == "blue" else "blue")
    
    msg = await ctx.reply(f"⏳ Initiating deployment pipeline for slot **`{target.upper()}`**...")
    proc = await run_cmd_async(
        ["/opt/gym/devops/scripts/deploy.sh", target],
        timeout=180
    )
    if proc.returncode == 0:
        await msg.edit(content=f"✅ Successfully deployed slot **`{target.upper()}`**! Traffic is live with zero downtime.")
    else:
        err = proc.stderr.strip() or proc.stdout.strip()
        await msg.edit(content=f"❌ Deployment to slot `{target}` failed:\n```{err[-400:]}```")

@bot.tree.command(name="deploy", description="Deploy new candidate container build with automated smoke test & cutover")
async def deploy_slash(interaction: discord.Interaction):
    if not is_authorized(interaction.user):
        await interaction.response.send_message("⛔ Unauthorized", ephemeral=True)
        return
    await interaction.response.defer()
    try:
        curr = (await asyncio.to_thread(subprocess.getoutput, "cat /opt/gym/state/active_slot 2>/dev/null || echo blue")).strip()
        target = "green" if curr == "blue" else "blue"
        proc = await run_cmd_async(["/opt/gym/devops/scripts/deploy.sh", target], timeout=180)
        if proc.returncode == 0:
            await interaction.followup.send(f"✅ Successfully deployed slot **`{target.upper()}`** with zero downtime!")
        else:
            err = proc.stderr.strip() or proc.stdout.strip()
            await interaction.followup.send(f"❌ Deployment failed:\n```{err[-500:]}```")
    except Exception as ex:
        await interaction.followup.send(f"❌ Deployment error: {ex}")

if __name__ == "__main__":
    if TOKEN:
        bot.run(TOKEN)
