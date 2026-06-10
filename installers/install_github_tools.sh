#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# GitHub Security Tools Installer & Updater
# Organizes tools in /opt by OS and category
# ═══════════════════════════════════════════════════════════════════

# Don't exit on errors - we want to continue even if some tools fail
set +e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[+]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[-]${NC} $1"; }

# ═══════════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════════
BASE_DIR="/opt/tools"
VERSION_FILE="$BASE_DIR/.versions"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ═══════════════════════════════════════════════════════════════════
# Tool Definitions
# Format: "name|repo|category|os|asset_pattern|needs_compile|compile_cmd"
# os: linux, windows, tunneling (both), enumeration (agnostic), wordlists
# category: enumeration, privesc, ad, credentials, exploit, web, recon
# Special patterns: CLONE (git clone only)
# ═══════════════════════════════════════════════════════════════════
TOOLS=(
    # ═══════════════════════════════════════════════════════════════
    # TUNNELING (Linux + Windows builds in one folder)
    # ═══════════════════════════════════════════════════════════════
    "chisel_linux|jpillora/chisel|chisel|tunneling|chisel_.*_linux_amd64.gz|false|"
    "chisel_windows|jpillora/chisel|chisel|tunneling|chisel_.*_windows_amd64.zip|false|"
    "ligolo_agent_linux|nicocha30/ligolo-ng|ligolo-ng|tunneling|ligolo-ng_agent_.*_linux_amd64.tar.gz|false|"
    "ligolo_agent_windows|nicocha30/ligolo-ng|ligolo-ng|tunneling|ligolo-ng_agent_.*_windows_amd64.zip|false|"
    "ligolo_proxy|nicocha30/ligolo-ng|ligolo-ng|tunneling|ligolo-ng_proxy_.*_linux_amd64.tar.gz|false|"
    "nc64|int0x33/nc.exe|netcat|tunneling|nc64.exe|false|"

    # ═══════════════════════════════════════════════════════════════
    # ENUMERATION - OS Agnostic (NOT in apt)
    # ═══════════════════════════════════════════════════════════════

    # ─── Web Enumeration (not in apt) ───
    "nuclei|projectdiscovery/nuclei|web|enumeration|nuclei_.*_linux_amd64.zip|false|"
    "subfinder|projectdiscovery/subfinder|web|enumeration|subfinder_.*_linux_amd64.zip|false|"
    "katana|projectdiscovery/katana|web|enumeration|katana_.*_linux_amd64.zip|false|"
    "dnsx|projectdiscovery/dnsx|web|enumeration|dnsx_.*_linux_amd64.zip|false|"
    "naabu|projectdiscovery/naabu|web|enumeration|naabu_.*_linux_amd64.zip|false|"
    "dirsearch|maurosoria/dirsearch|web|enumeration|CLONE|false|"

    # ─── Recon (not in apt) ───
    "gau|lc/gau|recon|enumeration|gau_.*_linux_amd64.tar.gz|false|"
    "waybackurls|tomnomnom/waybackurls|recon|enumeration|waybackurls-linux-amd64-.*\\.tgz|false|"
    "hakrawler|hakluke/hakrawler|recon|enumeration|CLONE|true|go build -o hakrawler"
    "arjun|s0md3v/Arjun|recon|enumeration|CLONE|false|"
    "paramspider|devanshbatham/ParamSpider|recon|enumeration|CLONE|false|"

    # ═══════════════════════════════════════════════════════════════
    # LINUX TOOLS (for transfer to Linux targets)
    # ═══════════════════════════════════════════════════════════════

    # ─── Linux Enumeration ───
    "pspy64|DominicBreuker/pspy|enumeration|linux|pspy64$|false|"
    "pspy32|DominicBreuker/pspy|enumeration|linux|pspy32$|false|"
    "linpeas|peass-ng/PEASS-ng|enumeration|linux|linpeas.sh|false|"
    "lse|diego-treitos/linux-smart-enumeration|enumeration|linux|lse.sh|false|"

    # ─── Linux Privesc ───
    "linux_exploit_suggester|The-Z-Labs/linux-exploit-suggester|privesc|linux|CLONE|false|"
    "linux_exploit_suggester2|jondonas/linux-exploit-suggester-2|privesc|linux|CLONE|false|"
    "traitor|liamg/traitor|privesc|linux|traitor-amd64|false|"
    "gtfonow|Frissi0n/GTFONow|privesc|linux|CLONE|false|"
    "sudo_killer|TH3xACE/SUDO_KILLER|privesc|linux|CLONE|false|"

    # ─── Linux Lateral Movement ───
    "ssh_snake|MegaManSec/SSH-Snake|lateral|linux|CLONE|false|"

    # ─── Linux Shells ───
    "penelope|brightio/penelope|shells|linux|CLONE|false|"

    # ─── Linux Exploit Tools ───
    "libc_database|niklasb/libc-database|exploit|linux|CLONE|false|"

    # ═══════════════════════════════════════════════════════════════
    # WINDOWS TOOLS (for transfer to Windows targets)
    # ═══════════════════════════════════════════════════════════════

    # ─── Windows Enumeration ───
    "winpeas_x64|peass-ng/PEASS-ng|enumeration|windows|winPEASx64.exe|false|"
    "winpeas_x86|peass-ng/PEASS-ng|enumeration|windows|winPEASx86.exe|false|"
    "winpeas_bat|peass-ng/PEASS-ng|enumeration|windows|winPEAS.bat|false|"
    "seatbelt|r3motecontrol/Ghostpack-CompiledBinaries|enumeration|windows|Seatbelt.exe|false|"
    "snaffler|SnaffCon/Snaffler|enumeration|windows|Snaffler.exe|false|"
    "sharpup|r3motecontrol/Ghostpack-CompiledBinaries|enumeration|windows|SharpUp.exe|false|"
    "sharpview|jakobfriedl/precompiled-binaries|enumeration|windows|SharpView.exe|false|"
    "nopowershell|jakobfriedl/precompiled-binaries|enumeration|windows|NoPowerShell.exe|false|"

    # ─── Windows Privesc ───
    "godpotato|BeichenDream/GodPotato|privesc|windows|GodPotato-NET4.exe|false|"
    "godpotato_net2|BeichenDream/GodPotato|privesc|windows|GodPotato-NET2.exe|false|"
    "godpotato_net35|BeichenDream/GodPotato|privesc|windows|GodPotato-NET35.exe|false|"
    "printspoofer64|itm4n/PrintSpoofer|privesc|windows|PrintSpoofer64.exe|false|"
    "printspoofer32|itm4n/PrintSpoofer|privesc|windows|PrintSpoofer32.exe|false|"
    "juicypotato|ohpe/juicy-potato|privesc|windows|JuicyPotato.exe|false|"
    "roguepotato|antonioCoco/RoguePotato|privesc|windows|RoguePotato.exe|false|"
    "remotepotato0|antonioCoco/RemotePotato0|privesc|windows|RemotePotato0.zip|false|"
    "efspotato|zcgonvh/EfsPotato|privesc|windows|CLONE|false|"
    "sweetpotato|uknowsec/SweetPotato|privesc|windows|SweetPotato.exe|false|"
    "sigmapotato|tylerdotrar/SigmaPotato|privesc|windows|SigmaPotato.exe|false|"
    "sharpefspotato|jakobfriedl/precompiled-binaries|privesc|windows|SharpEfsPotato.exe|false|"
    "krbrelayup|Dec0ne/KrbRelayUp|privesc|windows|KrbRelayUp.exe|false|"

    # ─── Windows AD ───
    "rubeus|r3motecontrol/Ghostpack-CompiledBinaries|ad|windows|Rubeus.exe|false|"
    "certify|r3motecontrol/Ghostpack-CompiledBinaries|ad|windows|Certify.exe|false|"
    "sharphound|BloodHoundAD/SharpHound|ad|windows|CLONE|false|"
    "whisker|jakobfriedl/precompiled-binaries|ad|windows|Whisker.exe|false|"
    "powerview|PowerShellMafia/PowerSploit|ad|windows|CLONE|false|"
    "adpeas|61106960/adPEAS|ad|windows|CLONE|false|"
    "kerbrute_win|ropnop/kerbrute|ad|windows|kerbrute_windows_amd64.exe|false|"
    "sharpgpoabuse|jakobfriedl/precompiled-binaries|ad|windows|SharpGPOAbuse.exe|false|"
    "passtheccert|jakobfriedl/precompiled-binaries|ad|windows|PassTheCert.exe|false|"
    "forgecert|jakobfriedl/precompiled-binaries|ad|windows|ForgeCert.exe|false|"
    "sharpsccm|jakobfriedl/precompiled-binaries|ad|windows|SharpSCCM.exe|false|"
    "spoolsample|jakobfriedl/precompiled-binaries|ad|windows|SpoolSample.exe|false|"
    "runascs|antonioCoco/RunasCs|ad|windows|RunasCs.exe|false|"
    "sharpmad|jakobfriedl/precompiled-binaries|ad|windows|Sharpmad.exe|false|"
    "sharprdp|jakobfriedl/precompiled-binaries|ad|windows|SharpRDP.exe|false|"
    "sharpmove|jakobfriedl/precompiled-binaries|ad|windows|SharpMove.exe|false|"
    "adidnsdump|dirkjanm/adidnsdump|ad|windows|CLONE|false|"
    "powermad|Kevin-Robertson/Powermad|ad|windows|CLONE|false|"
    "inveigh|Kevin-Robertson/Inveigh|ad|windows|CLONE|false|"
    "powerupsql|NetSPI/PowerUpSQL|ad|windows|CLONE|false|"
    "lapstoolkit|leoloobeek/LAPSToolkit|ad|windows|CLONE|false|"

    # ─── Windows Credentials ───
    "mimikatz|gentilkiwi/mimikatz|credentials|windows|mimikatz_trunk.zip|false|"
    "lazagne|AlessandroZ/LaZagne|credentials|windows|LaZagne.exe|false|"
    "sharpdpapi|r3motecontrol/Ghostpack-CompiledBinaries|credentials|windows|SharpDPAPI.exe|false|"
    "sharpchrome|r3motecontrol/Ghostpack-CompiledBinaries|credentials|windows|SharpChrome.exe|false|"
    "invokemimikatz|PowerShellMafia/PowerSploit|credentials|windows|CLONE|false|"
    "nanodump|helpsystems/nanodump|credentials|windows|CLONE|false|"
    "sharpkatz|jakobfriedl/precompiled-binaries|credentials|windows|SharpKatz.exe|false|"
    "sharplaps|jakobfriedl/precompiled-binaries|credentials|windows|SharpLAPS.exe|false|"
    "bettersafetykatz|jakobfriedl/precompiled-binaries|credentials|windows|BetterSafetyKatz.exe|false|"
    "gmsapasswordreader|jakobfriedl/precompiled-binaries|credentials|windows|GMSAPasswordReader.exe|false|"
    "adsyncdecrypt|jakobfriedl/precompiled-binaries|credentials|windows|ADSyncDecrypt.exe|false|"
    "dploot|zblurx/dploot|credentials|windows|CLONE|false|"

    # ─── Windows Exploit/Shells ───
    "nishang|samratashok/nishang|exploit|windows|CLONE|false|"
    "powercat|besimorhino/powercat|exploit|windows|CLONE|false|"

    # ═══════════════════════════════════════════════════════════════
    # AD ATTACK TOOLS (Python/Go tools that TARGET Windows AD)
    # ═══════════════════════════════════════════════════════════════
    "kerbrute_linux|ropnop/kerbrute|ad|windows|kerbrute_linux_amd64|false|"
    "coercer|p0dalirius/Coercer|ad|windows|CLONE|false|"
    "petitpotam|topotam/PetitPotam|ad|windows|CLONE|false|"
    "krbrelayx|dirkjanm/krbrelayx|ad|windows|CLONE|false|"
    "targetedkerberoast|ShutdownRepo/targetedKerberoast|ad|windows|CLONE|false|"
    "pkinittools|dirkjanm/PKINITtools|ad|windows|CLONE|false|"
    "ldaprelayscan|zyn3rgy/LdapRelayScan|ad|windows|CLONE|false|"
    "pywhisker|ShutdownRepo/pywhisker|ad|windows|CLONE|false|"
    "certipy|ly4k/Certipy|ad|windows|CLONE|false|"
    "bloodhound_py|dirkjanm/BloodHound.py|ad|windows|CLONE|false|"
    "rusthound|NH-RED-TEAM/RustHound|ad|windows|CLONE|true|cargo install --root . rusthound"
    "godap|Macmod/godap|ad|windows|godap-.*-linux-amd64.tar.gz|false|"
    "powerview_py|aniqfakhrul/powerview.py|ad|windows|CLONE|false|"
    "findgpppasswords|p0dalirius/FindGPPPasswords|ad|windows|CLONE|true|go build -o findgpppasswords"
    "sccmhound|CrowdStrike/sccmhound|ad|windows|CLONE|false|"
    "remotemonologue|xforcered/RemoteMonologue|ad|windows|CLONE|false|"
    "nopac|Ridter/noPac|ad|windows|CLONE|false|"
    "sprayhound|Hackndo/sprayhound|ad|windows|CLONE|false|"
    "pre2k|garrettfoster13/pre2k|ad|windows|CLONE|false|"
    "masky|Z4kSec/Masky|ad|windows|CLONE|false|"
    "zerologon|dirkjanm/CVE-2020-1472|ad|windows|CLONE|false|"
    "printnightmare|cube0x0/CVE-2021-1675|ad|windows|CLONE|false|"

    # ═══════════════════════════════════════════════════════════════
    # TUNNELING/C2 ADDITIONS
    # ═══════════════════════════════════════════════════════════════
    "reverse_ssh_client|NHAS/reverse_ssh|c2|tunneling|client_linux_amd64|false|"
    "reverse_ssh_server|NHAS/reverse_ssh|c2|tunneling|server_linux_amd64|false|"
    "gorsh|audibleblink/gorsh|c2|tunneling|CLONE|true|make"
    "goncat|DominicBreuker/goncat|c2|tunneling|goncat_linux_amd64|false|"
    "goexec|FalconOpsLLC/goexec|c2|windows|goexec_.*_linux_amd64.tar.gz|false|"

    # ═══════════════════════════════════════════════════════════════
    # WINDOWS EVASION TOOLS
    # ═══════════════════════════════════════════════════════════════
    "defendnot|es3n1n/defendnot|evasion|windows|x64.zip|false|"
    "nyxinvoke|BlackSnufkin/NyxInvoke|evasion|windows|CLONE|false|"
    "supernova|nickvourd/Supernova|evasion|windows|Supernova_.*_linux_amd64.tar.gz|false|"
    "loki|boku7/Loki|evasion|windows|CLONE|false|"

    # ═══════════════════════════════════════════════════════════════
    # ADDITIONAL WINDOWS AD TOOLS
    # ═══════════════════════════════════════════════════════════════
    "logonsessionauditor|0xHasanM/LogonSessionAuditor|ad|windows|LogonSessionAuditor.exe|false|"
    "sharpsuccessor|logangoins/SharpSuccessor|ad|windows|SharpSuccessor.exe|false|"

    # ═══════════════════════════════════════════════════════════════
    # EXPLOITATION TOOLS
    # ═══════════════════════════════════════════════════════════════
    "gittools|internetwache/GitTools|exploit|linux|CLONE|false|"
    "totalrecall|xaitax/TotalRecall|exploit|windows|CLONE|false|"

    # ═══════════════════════════════════════════════════════════════
    # ADDITIONAL RECON/ENUMERATION
    # ═══════════════════════════════════════════════════════════════
    "eventlog_compendium|nasbench/Eventlog_Compendium|reference|linux|CLONE|false|"
    "cloud_detective|Slayer0x/Cloud-Detective|recon|enumeration|CLONE|false|"

    # ═══════════════════════════════════════════════════════════════
    # ADDITIONAL AD TOOLS (target Windows)
    # ═══════════════════════════════════════════════════════════════
    "patronusx|Michaeladsl/Patronusx|ad|windows|CLONE|false|"
    "steppingstones|nccgroup/SteppingStones|ad|windows|CLONE|false|"
    "evilginx2|kgretzky/evilginx2|ad|windows|evilginx-.*-linux-64bit.zip|false|"

    # ═══════════════════════════════════════════════════════════════
    # ADDITIONAL C2/REMOTE ACCESS
    # ═══════════════════════════════════════════════════════════════
    "winrmexec|ozelis/winrmexec|c2|tunneling|CLONE|false|"
    "evil_winrm_py|adityatelange/evil-winrm-py|c2|tunneling|CLONE|false|"
    "darkflare|doxx/darkflare|c2|tunneling|darkflare-client_linux_amd64|false|"
    "sliver_cheatsheet|Anon-Exploiter/sliver-cheatsheet|reference|linux|CLONE|false|"
    "sliver_ligolo|KriyosArcane/sliver-ligolo-ng|reference|linux|CLONE|false|"

    # ═══════════════════════════════════════════════════════════════
    # ADDITIONAL EXPLOITATION
    # ═══════════════════════════════════════════════════════════════
    "fenjing|Marven11/Fenjing|exploit|linux|CLONE|false|"
    "sqlmapcg|Acorzo1983/SQLMapCG|exploit|linux|CLONE|false|"
    "pyjailbreaker|jailctf/pyjailbreaker|exploit|linux|CLONE|false|"
    "cve_2024_4577|watchtowrlabs/CVE-2024-4577|exploit|linux|CLONE|false|"
    # "cve_2024_26229|varwara/CVE-2024-26229|exploit|windows|CLONE|false|"  # DEAD URL (404)
    "cve_2024_30051|fortra/CVE-2024-30051|exploit|windows|CLONE|false|"
    "cve_2024_30088|tykawaii98/CVE-2024-30088|exploit|windows|CLONE|false|"
    "cve_2025_30397|mbanyamer/CVE-2025-30397---Windows-Server-2025-JScript-RCE-Use-After-Free-|exploit|windows|CLONE|false|"
    "cve_2025_21298|ynwarcs/CVE-2025-21298|exploit|windows|CLONE|false|"

    # ═══════════════════════════════════════════════════════════════
    # ADDITIONAL EVASION
    # ═══════════════════════════════════════════════════════════════
    "boaz|thomasxm/BOAZ_beta|evasion|windows|CLONE|false|"
    "shellcode2dll|restkhz/ShellcodeEncrypt2DLL|evasion|windows|CLONE|false|"
    "bypassav|matro7sh/BypassAV|evasion|windows|CLONE|false|"
    "ps_obfuscation|t3l3machus/PowerShell-Obfuscation-Bible|evasion|windows|CLONE|false|"
    "offensivevba|S3cur3Th1sSh1t/OffensiveVBA|evasion|windows|CLONE|false|"

    # ═══════════════════════════════════════════════════════════════
    # REVERSE ENGINEERING
    # ═══════════════════════════════════════════════════════════════
    "bugchecker|vitoplantamura/BugChecker|re|linux|CLONE|false|"
    "bytecode_viewer|Konloch/bytecode-viewer|re|linux|Bytecode-Viewer-.*\\.jar|false|"
    "simplify|CalebFenton/simplify|re|linux|simplify-.*\\.jar|false|"
    "ecapture|gojue/ecapture|re|linux|ecapture-.*-linux-x86_64.tar.gz|false|"
    "webcrack|j4k0xb/webcrack|re|linux|CLONE|false|"
    "gdb_enhancements|apogiatzis/gdb-peda-pwndbg-gef|re|linux|CLONE|false|"
    "kernelinit|Myldero/kernelinit|re|linux|CLONE|false|"

    # ═══════════════════════════════════════════════════════════════
    # CRYPTO
    # ═══════════════════════════════════════════════════════════════
    "crypto_attacks|jvdsn/crypto-attacks|exploit|linux|CLONE|false|"

    # ═══════════════════════════════════════════════════════════════
    # OSINT
    # ═══════════════════════════════════════════════════════════════
    "nsa_selector|wenzellabs/the_NSA_selector|recon|enumeration|CLONE|false|"
    # "infinite_storage|DvorakDwarf/Infinite-Storage-Glitch|misc|linux|CLONE|false|"  # DEAD URL (404)

    # ═══════════════════════════════════════════════════════════════
    # MISC TOOLS
    # ═══════════════════════════════════════════════════════════════
    "fadcrypt|anonfaded/FadCrypt|misc|linux|CLONE|false|"
    "gdb_config|manesec/tools4mane|re|linux|CLONE|false|"

    # ═══════════════════════════════════════════════════════════════
    # REFERENCE/PAYLOADS/CHEATSHEETS (Clone only)
    # ═══════════════════════════════════════════════════════════════
    "payloadsallthethings|swisskyrepo/PayloadsAllTheThings|reference|linux|CLONE|false|"
    "megasheet|DaddyBigFish/megasheet|reference|linux|CLONE|false|"
    # "xss_payloads|payloadbox/xss-payload-list|reference|linux|CLONE|false|"  # DEAD URL (404)
    "cyber_cheatsheets|puzzithinker/cybersecurity_cheatsheets|reference|linux|CLONE|false|"
    "lolbins_beyond|sheimo/awesome-lolbins-and-beyond|reference|linux|CLONE|false|"
    "lol_abused|danzek/awesome-lol-commonly-abused|reference|linux|CLONE|false|"
    "redteam_projects|kurogai/100-redteam-projects|reference|linux|CLONE|false|"
    "awesome_reversing|HACKE-RC/awesome-reversing|reference|linux|CLONE|false|"
    "re_learning|mytechnotalent/Reverse-Engineering|reference|linux|CLONE|false|"
    "awesome_malware|rshipp/awesome-malware-analysis|reference|linux|CLONE|false|"
    "aerospace_security|r0r0x-xx/AeroSpace-Cybersecurity|reference|linux|CLONE|false|"
    "security_tips|hackerscrolls/SecurityTips|reference|linux|CLONE|false|"

    # ═══════════════════════════════════════════════════════════════
    # EMBEDDED / FIRMWARE / IoT
    # ═══════════════════════════════════════════════════════════════
    "firmwalker|craigz28/firmwalker|firmware|embedded|CLONE|false|"
    "firmware_mod_kit|rampageX/firmware-mod-kit|firmware|embedded|CLONE|false|"
    "sasquatch|devttys0/sasquatch|firmware|embedded|CLONE|true|command -v sasquatch >/dev/null 2>&1 && echo 'sasquatch already provided by Kali apt package (/usr/bin/sasquatch) — skipping source build' || { apt-get install -y -q sasquatch >/dev/null 2>&1; command -v sasquatch >/dev/null 2>&1 && echo 'installed sasquatch via apt' || { sed -i 's/-Werror//g' patches/patch0.txt Makefile 2>/dev/null; CFLAGS='-Wno-incompatible-pointer-types -Wno-error -fcommon' ./build.sh; }; }"
    "firmadyne|firmadyne/firmadyne|firmware|embedded|CLONE|false|"
    "firmware_analysis_toolkit|attify/firmware-analysis-toolkit|firmware|embedded|CLONE|false|"
    "routersploit|threat9/routersploit|iot|embedded|CLONE|false|"
    # "expliot|expliot_framework/expliot|iot|embedded|CLONE|false|"  # DEAD URL (404)

    # ═══════════════════════════════════════════════════════════════
    # FORENSICS / MEMORY
    # ═══════════════════════════════════════════════════════════════
    "avml|microsoft/avml|memory|forensics|avml-linux-x86_64|false|"
    "lime|504ensicsLabs/LiME|memory|forensics|CLONE|false|"
    "volatility_profiles|volatilityfoundation/profiles|memory|forensics|CLONE|false|"
    "dwarf2json|volatilityfoundation/dwarf2json|memory|forensics|dwarf2json-linux-amd64|false|"

    # ═══════════════════════════════════════════════════════════════
    # WEB/API TESTING (Additional)
    # ═══════════════════════════════════════════════════════════════
    "jwt_tool|ticarpi/jwt_tool|web|enumeration|CLONE|false|"
    "ssrfmap|swisskyrepo/SSRFmap|web|enumeration|CLONE|false|"
    # "stews|WebSocket-research/STEWS|web|enumeration|CLONE|false|"  # DEAD URL (404)
    # "race_the_web|aaronhnatiw/race-the-web|web|enumeration|CLONE|true|go build -o race-the-web"  # uses pre-2018 Gopkg dep manager, won't build with modern Go

    # ═══════════════════════════════════════════════════════════════
    # CONTAINER / KUBERNETES
    # ═══════════════════════════════════════════════════════════════
    "deepce|stealthcopter/deepce|docker|container|CLONE|false|"
    "cdk|cdk-team/CDK|kubernetes|container|cdk_linux_amd64|false|"
    "kubeletctl|cyberark/kubeletctl|kubernetes|container|kubeletctl_linux_amd64|false|"
    "peirates|inguardians/peirates|kubernetes|container|peirates-linux-amd64.tar.xz|false|"
    "kubeaudit|Shopify/kubeaudit|kubernetes|container|kubeaudit_.*_linux_amd64.tar.gz|false|"
    "kdigger|quarkslab/kdigger|kubernetes|container|kdigger-linux-amd64|false|"

    # ═══════════════════════════════════════════════════════════════
    # CLOUD - AWS
    # ═══════════════════════════════════════════════════════════════
    "cloudfox|BishopFox/cloudfox|aws|cloud|cloudfox-linux-amd64.zip|false|"
    "enumerate_iam|andresriancho/enumerate-iam|aws|cloud|CLONE|false|"
    "weirdaal|carnal0wnage/weirdAAL|aws|cloud|CLONE|false|"
    "s3scanner|sa7mon/S3Scanner|aws|cloud|CLONE|false|"
    "aws_consoler|NetSPI/aws_consoler|aws|cloud|CLONE|false|"
    # "endgame|DavidDikworWorku/endgame|aws|cloud|CLONE|false|"  # DEAD URL (404)
    "pmapper|nccgroup/PMapper|aws|cloud|CLONE|false|"
    "awspx|WithSecureLabs/awspx|aws|cloud|CLONE|false|"
    "cloudmapper|duo-labs/cloudmapper|aws|cloud|CLONE|false|"

    # ═══════════════════════════════════════════════════════════════
    # CLOUD - AZURE
    # ═══════════════════════════════════════════════════════════════
    "azurehound|BloodHoundAD/AzureHound|azure|cloud|CLONE|true|go build -o azurehound ."
    "stormspotter|Azure/Stormspotter|azure|cloud|CLONE|false|"
    "microburst|NetSPI/MicroBurst|azure|cloud|CLONE|false|"
    "aadinternals|Gerenios/AADInternals|azure|cloud|CLONE|false|"
    "azucar|nccgroup/azucar|azure|cloud|CLONE|false|"
    "powerzure|hausec/PowerZure|azure|cloud|CLONE|false|"
    "azuread_attack_library|rootsecdev/Azure-Red-Team|azure|cloud|CLONE|false|"

    # ═══════════════════════════════════════════════════════════════
    # CLOUD - O365 / MS GRAPH
    # ═══════════════════════════════════════════════════════════════
    "graphrunner|dafthack/GraphRunner|o365|cloud|CLONE|false|"
    "teamfiltration|Flangvik/TeamFiltration|o365|cloud|TeamFiltration.*linux.*x64.*zip|false|"
    "trevorspray|blacklanternsecurity/TREVORspray|o365|cloud|CLONE|false|"
    "o365recon|nyxgeek/o365recon|o365|cloud|CLONE|false|"
    "msolspray|dafthack/MSOLSpray|o365|cloud|CLONE|false|"
    "ruler|sensepost/ruler|o365|cloud|ruler-linux64|false|"
    "mailsniper|dafthack/MailSniper|o365|cloud|CLONE|false|"
    # "tokensmuggling|LuemmelSec/TokenSmuggling|o365|cloud|CLONE|false|"  # DEAD URL (404)
    "o365enum|gremwell/o365enum|o365|cloud|CLONE|false|"
    "o365_attack_toolkit|mdsecactivebreach/o365-attack-toolkit|o365|cloud|CLONE|false|"

    # ═══════════════════════════════════════════════════════════════
    # CLOUD - GCP
    # ═══════════════════════════════════════════════════════════════
    "gcp_scanner|google/gcp_scanner|gcp|cloud|CLONE|false|"
    "gcpwn|NetSPI/gcpwn|gcp|cloud|CLONE|false|"
    "gcp_enum|RhinoSecurityLabs/GCP-IAM-Privilege-Escalation|gcp|cloud|CLONE|false|"
    # "hayat|SygniaLabs/Hayat|gcp|cloud|CLONE|false|"  # DEAD URL (404)

    # ═══════════════════════════════════════════════════════════════
    # CLOUD - MULTI-CLOUD
    # ═══════════════════════════════════════════════════════════════
    "cloudsplaining|salesforce/cloudsplaining|multi|cloud|CLONE|false|"
    "cartography|lyft/cartography|multi|cloud|CLONE|false|"
    "cloudbrute|0xsha/CloudBrute|multi|cloud|cloudbrute_.*_linux_amd64.tar.gz|false|"
    "cloud_enum|initstring/cloud_enum|multi|cloud|CLONE|false|"

    # ═══════════════════════════════════════════════════════════════
    # ADDITIONAL AD TOOLS
    # ═══════════════════════════════════════════════════════════════
    "adrecon|adrecon/ADRecon|ad|windows|CLONE|false|"
    "dsinternals_ps|MichaelGrafnetter/DSInternals|ad|windows|CLONE|false|"
    "max_ad|knavesec/Max|ad|windows|CLONE|false|"
    "adenumeration|CasperGN/ActiveDirectoryEnumeration|ad|windows|CLONE|false|"
)

# ═══════════════════════════════════════════════════════════════════
# Parse Arguments
# ═══════════════════════════════════════════════════════════════════
UPDATE_MODE=false
INSTALL_MODE=false
LIST_MODE=false
SPECIFIC_TOOL=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--update)
            UPDATE_MODE=true
            shift
            ;;
        -i|--install)
            INSTALL_MODE=true
            shift
            ;;
        -l|--list)
            LIST_MODE=true
            shift
            ;;
        -t|--tool)
            SPECIFIC_TOOL="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -i, --install    Install all tools"
            echo "  -u, --update     Update all tools to latest versions"
            echo "  -l, --list       List all tools and their status"
            echo "  -t, --tool NAME  Install/update specific tool"
            echo "  -h, --help       Show this help message"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Default to install if no mode specified
if [ "$UPDATE_MODE" = false ] && [ "$INSTALL_MODE" = false ] && [ "$LIST_MODE" = false ]; then
    INSTALL_MODE=true
fi

# ═══════════════════════════════════════════════════════════════════
# Check requirements
# ═══════════════════════════════════════════════════════════════════
if [ "$EUID" -ne 0 ]; then
    print_error "Please run as root (sudo)"
    exit 1
fi

# Install dependencies
print_status "Checking dependencies..."
apt-get install -y -qq jq curl wget unzip git p7zip-full mono-complete dotnet-sdk-8.0 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════
# APT Security Tools (from Discord list that have apt packages)
# ═══════════════════════════════════════════════════════════════════
print_status "Installing apt security tools..."
APT_TOOLS=(
    cupp              # Common User Password Profiler
    radare2           # Reverse engineering framework
    commix            # Command injection exploitation
    python3-pwntools  # CTF framework and exploit development
    gef               # GDB Enhanced Features
    checksec          # Binary security checker
    patchelf          # Modify ELF binaries
    jadx              # Android DEX decompiler
    apktool           # APK reverse engineering
    enum4linux-ng     # SMB enumeration
    smbmap            # SMB share enumeration
    can-utils         # CAN bus analysis
    openocd           # JTAG/SWD debugger
    ruby-dev          # Ruby development (for gems)
    feroxbuster       # Fast content discovery (Rust)
    boofuzz           # Network protocol fuzzing
    awscli            # AWS CLI
    azure-cli         # Azure CLI
)

# ═══════════════════════════════════════════════════════════════════
# PIP Tools (maintained via pip, not apt)
# ═══════════════════════════════════════════════════════════════════
PIP_TOOLS=(
    ropper            # ROP gadget finder
    ROPgadget         # Alternative ROP finder
    volatility3       # Memory forensics
    lsassy            # Remote LSASS dumping
    ldapdomaindump    # LDAP domain dumper
    mitm6             # IPv6 MITM attacks
    frida-tools       # Dynamic instrumentation
    objection         # Mobile runtime exploration
    pwncat-cs         # Fancy shell handler
    jefferson         # JFFS2 filesystem extractor
    ubi_reader        # UBI/UBIFS extraction
    # Cloud pentesting tools
    pacu              # AWS exploitation framework
    prowler           # AWS/Azure/GCP security scanner
    scoutsuite        # Multi-cloud security auditing
    roadrecon         # Azure AD reconnaissance
    roadlib           # ROADtools library
    jwt-tool          # JWT security testing
    ssrfmap           # SSRF detection and exploitation
    kube-hunter       # Kubernetes cluster testing
)

# ═══════════════════════════════════════════════════════════════════
# Ruby Gems (maintained via gem)
# ═══════════════════════════════════════════════════════════════════
GEM_TOOLS=(
    one_gadget        # Find one-shot RCE gadgets
    seccomp-tools     # Seccomp sandbox analyzer
)

# ═══════════════════════════════════════════════════════════════════
# Python Libraries (security/pentesting development)
# ═══════════════════════════════════════════════════════════════════
PYTHON_LIBRARIES=(
    # Protocol implementations
    impacket          # SMB/LDAP/Kerberos/WMI/MSRPC protocols
    scapy             # Packet crafting/sniffing framework
    paramiko          # SSH v2 protocol implementation
    ldap3             # LDAP v3 client
    dnspython         # DNS queries and zone transfers
    pyopenssl         # OpenSSL bindings
    pyasn1            # ASN.1 encoding/decoding
    websockets        # WebSocket client/server

    # Web/HTTP
    requests          # HTTP requests with sessions
    aiohttp           # Async HTTP client/server
    httpx             # Modern HTTP client with HTTP/2
    beautifulsoup4    # HTML/XML parsing
    lxml              # Fast XML/HTML parsing
    selenium          # Browser automation
    playwright        # Modern browser automation
    Flask             # Micro web framework
    fastapi           # Async web framework
    Jinja2            # Template engine
    Twisted           # Event-driven networking

    # Cryptography
    pycryptodome      # Cryptographic primitives
    cryptography      # Modern cryptography
    PyJWT             # JWT encoding/decoding

    # Binary analysis
    pwntools          # CTF/exploit dev framework
    angr              # Binary analysis/symbolic execution
    capstone          # Multi-arch disassembly
    keystone-engine   # Multi-arch assembler
    unicorn           # Multi-arch CPU emulator
    qiling            # Binary emulation framework
    z3-solver         # SMT solver
    r2pipe            # Radare2 Python bindings
    pefile            # PE file parsing

    # Forensics/Malware
    yara-python       # YARA rules matching
    oletools          # MS Office malware analysis

    # Cloud
    boto3             # AWS SDK
    msal              # Microsoft Auth Library
    kubernetes        # Kubernetes API client

    # Recon
    shodan            # Shodan API
    censys            # Censys API

    # Network
    netaddr           # Network address manipulation
    netifaces         # Network interface info
    netmiko           # Network device automation
    pyserial          # Serial port access

    # Data/Visualization
    numpy             # Numerical computing
    pandas            # Data analysis
    matplotlib        # Plotting library
    pillow            # Image processing
    opencv-python     # Computer vision
    scikit-learn      # Machine learning

    # Utilities
    psutil            # Process/system utilities
    colorama          # Colored terminal output
    rich              # Rich text formatting
    docker            # Docker API
    typer             # CLI framework
    jupyter           # Interactive notebooks

    # Dev tools
    black             # Code formatter
    bandit            # Security linter
)

for tool in "${APT_TOOLS[@]}"; do
    if ! dpkg -l "$tool" 2>/dev/null | grep -q "^ii"; then
        print_status "Installing $tool via apt..."
        apt-get install -y -qq "$tool" 2>/dev/null || print_warning "Failed to install $tool"
    else
        print_success "$tool already installed"
    fi
done

# Install pip tools (skip if already installed)
print_status "Installing/updating pip tools..."
for tool in "${PIP_TOOLS[@]}"; do
    if pip3 show "$tool" &>/dev/null; then
        print_success "$tool already installed"
    else
        pip3 install --break-system-packages "$tool" &>/dev/null && print_success "$tool installed" || print_warning "Failed to install $tool"
    fi
done

# Install gem tools (skip if already installed)
print_status "Installing/updating ruby gems..."
for tool in "${GEM_TOOLS[@]}"; do
    if gem list -i "^${tool}$" &>/dev/null; then
        print_success "$tool already installed"
    else
        gem install "$tool" &>/dev/null && print_success "$tool installed" || print_warning "Failed to install $tool"
    fi
done

# Install Python libraries (skip if already installed)
print_status "Installing/updating Python libraries..."
for lib in "${PYTHON_LIBRARIES[@]}"; do
    if python3 -c "import ${lib//-/_}" &>/dev/null || pip3 show "$lib" &>/dev/null; then
        print_success "$lib already installed"
    else
        pip3 install --break-system-packages "$lib" &>/dev/null && print_success "$lib installed" || print_warning "Failed to install $lib"
    fi
done

# Create base directories
mkdir -p "$BASE_DIR"/linux/{enumeration,privesc,ad,exploit,reference,re,misc,lateral,shells}
mkdir -p "$BASE_DIR"/windows/{enumeration,privesc,ad,credentials,exploit,evasion,c2}
mkdir -p "$BASE_DIR"/tunneling/c2
mkdir -p "$BASE_DIR"/enumeration/{web,recon}
mkdir -p "$BASE_DIR"/embedded/{firmware,iot}
mkdir -p "$BASE_DIR"/forensics/{memory,disk}
mkdir -p "$BASE_DIR"/cloud/{aws,azure,gcp,o365,multi}
mkdir -p "$BASE_DIR"/container/{kubernetes,docker}
touch "$VERSION_FILE"

# ═══════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════

get_latest_version() {
    local repo="$1"
    # Try to get version, but don't fail if rate limited
    local version=$(curl -s --max-time 5 "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)
    if [ -z "$version" ] || [[ "$version" == *"rate limit"* ]]; then
        echo "latest"
    else
        echo "$version"
    fi
}

get_installed_version() {
    local tool="$1"
    grep "^$tool=" "$VERSION_FILE" 2>/dev/null | cut -d'=' -f2
}

set_installed_version() {
    local tool="$1"
    local version="$2"
    if grep -q "^$tool=" "$VERSION_FILE" 2>/dev/null; then
        sed -i "s/^$tool=.*/$tool=$version/" "$VERSION_FILE"
    else
        echo "$tool=$version" >> "$VERSION_FILE"
    fi
}

get_tool_dir() {
    local os="$1"
    local category="$2"
    local name="$3"

    case "$os" in
        tunneling)
            # Tunneling tools - check if category is c2 for subfolder
            if [ "$category" = "c2" ]; then
                echo "$BASE_DIR/tunneling/c2/$name"
            else
                echo "$BASE_DIR/tunneling/$name"
            fi
            ;;
        enumeration)
            # OS-agnostic enumeration tools organized by category (web, recon)
            echo "$BASE_DIR/enumeration/$category/$name"
            ;;
        embedded)
            # Embedded/IoT/Firmware tools
            echo "$BASE_DIR/embedded/$category/$name"
            ;;
        forensics)
            # Forensics tools (memory, disk)
            echo "$BASE_DIR/forensics/$category/$name"
            ;;
        cloud)
            # Cloud pentesting tools (aws, azure, gcp, o365, multi)
            echo "$BASE_DIR/cloud/$category/$name"
            ;;
        container)
            # Container/Kubernetes tools
            echo "$BASE_DIR/container/$category/$name"
            ;;
        linux|windows)
            # OS-specific tools organized by category
            echo "$BASE_DIR/$os/$category/$name"
            ;;
        *)
            # Default fallback
            echo "$BASE_DIR/$os/$category/$name"
            ;;
    esac
}

download_release_asset() {
    local repo="$1"
    local pattern="$2"
    local output_dir="$3"
    local output_name="$4"

    local download_url=""
    local filename=""

    # ─── Direct URL mappings (legacy fast path) ───
    # NOTE: most of these have stale version numbers. Tier-1 validates them with
    # `curl -sIfL`; if they 404, the script falls through to tier-2 (API) and then
    # tier-3 (release-page scrape). Tier-3 always works without rate limiting, so
    # these hardcoded URLs are now just a fast-path optimization for tools whose
    # versions haven't changed. Don't add new entries here unless you're committed
    # to maintaining the version string.
    case "$repo" in
        "r3motecontrol/Ghostpack-CompiledBinaries")
            download_url="https://github.com/$repo/raw/master/$pattern"
            ;;
        "jpillora/chisel")
            if [[ "$pattern" == *"windows"* ]]; then
                download_url="https://github.com/jpillora/chisel/releases/latest/download/chisel_1.10.1_windows_amd64.gz"
            else
                download_url="https://github.com/jpillora/chisel/releases/latest/download/chisel_1.10.1_linux_amd64.gz"
            fi
            ;;
        "nicocha30/ligolo-ng")
            if [[ "$pattern" == *"windows"* ]]; then
                download_url="https://github.com/nicocha30/ligolo-ng/releases/latest/download/ligolo-ng_agent_0.7.5_windows_amd64.zip"
            elif [[ "$pattern" == *"proxy"* ]]; then
                download_url="https://github.com/nicocha30/ligolo-ng/releases/latest/download/ligolo-ng_proxy_0.7.5_linux_amd64.tar.gz"
            else
                download_url="https://github.com/nicocha30/ligolo-ng/releases/latest/download/ligolo-ng_agent_0.7.5_linux_amd64.tar.gz"
            fi
            ;;
        "ropnop/kerbrute")
            if [[ "$pattern" == *"windows"* ]]; then
                download_url="https://github.com/ropnop/kerbrute/releases/latest/download/kerbrute_windows_amd64.exe"
            else
                download_url="https://github.com/ropnop/kerbrute/releases/latest/download/kerbrute_linux_amd64"
            fi
            ;;
        "projectdiscovery/nuclei")
            download_url="https://github.com/projectdiscovery/nuclei/releases/latest/download/nuclei_3.4.3_linux_amd64.zip"
            ;;
        "projectdiscovery/httpx")
            download_url="https://github.com/projectdiscovery/httpx/releases/latest/download/httpx_1.7.0_linux_amd64.zip"
            ;;
        "projectdiscovery/subfinder")
            download_url="https://github.com/projectdiscovery/subfinder/releases/latest/download/subfinder_2.7.1_linux_amd64.zip"
            ;;
        "projectdiscovery/katana")
            download_url="https://github.com/projectdiscovery/katana/releases/latest/download/katana_1.1.2_linux_amd64.zip"
            ;;
        "projectdiscovery/dnsx")
            download_url="https://github.com/projectdiscovery/dnsx/releases/latest/download/dnsx_1.2.2_linux_amd64.zip"
            ;;
        "projectdiscovery/naabu")
            download_url="https://github.com/projectdiscovery/naabu/releases/latest/download/naabu_2.3.5_linux_amd64.zip"
            ;;
        "lc/gau")
            download_url="https://github.com/lc/gau/releases/latest/download/gau_2.2.4_linux_amd64.tar.gz"
            ;;
        "tomnomnom/waybackurls")
            download_url="https://github.com/tomnomnom/waybackurls/releases/latest/download/waybackurls-linux-amd64-0.1.0.tgz"
            ;;
        "hakluke/hakrawler")
            download_url="https://github.com/hakluke/hakrawler/releases/latest/download/hakrawler_2.1_linux_amd64.tar.gz"
            ;;
        "ffuf/ffuf")
            download_url="https://github.com/ffuf/ffuf/releases/latest/download/ffuf_2.1.0_linux_amd64.tar.gz"
            ;;
        "OJ/gobuster")
            download_url="https://github.com/OJ/gobuster/releases/latest/download/gobuster_Linux_x86_64.tar.gz"
            ;;
        "DominicBreuker/pspy")
            if [[ "$pattern" == *"64"* ]]; then
                download_url="https://github.com/DominicBreuker/pspy/releases/latest/download/pspy64"
            else
                download_url="https://github.com/DominicBreuker/pspy/releases/latest/download/pspy32"
            fi
            ;;
        "cyberark/kubeletctl")
            download_url="https://github.com/cyberark/kubeletctl/releases/latest/download/kubeletctl_linux_amd64"
            ;;
        "runZeroInc/sshamble")
            download_url="https://github.com/runZeroInc/sshamble/releases/latest/download/sshamble-linux-amd64"
            ;;
        "int0x33/nc.exe")
            download_url="https://github.com/int0x33/nc.exe/raw/master/nc64.exe"
            ;;
        "jakobfriedl/precompiled-binaries")
            # Direct downloads from precompiled-binaries repo
            case "$pattern" in
                *SharpView*) download_url="https://github.com/jakobfriedl/precompiled-binaries/raw/main/SharpView.exe" ;;
                *NoPowerShell*) download_url="https://github.com/jakobfriedl/precompiled-binaries/raw/main/NoPowerShell.exe" ;;
                *Whisker*) download_url="https://github.com/jakobfriedl/precompiled-binaries/raw/main/Whisker.exe" ;;
                *SharpGPOAbuse*) download_url="https://github.com/jakobfriedl/precompiled-binaries/raw/main/SharpGPOAbuse.exe" ;;
                *PassTheCert*) download_url="https://github.com/jakobfriedl/precompiled-binaries/raw/main/PassTheCert.exe" ;;
                *ForgeCert*) download_url="https://github.com/jakobfriedl/precompiled-binaries/raw/main/ForgeCert.exe" ;;
                *SharpSCCM*) download_url="https://github.com/jakobfriedl/precompiled-binaries/raw/main/SharpSCCM.exe" ;;
                *SpoolSample*) download_url="https://github.com/jakobfriedl/precompiled-binaries/raw/main/SpoolSample.exe" ;;
                *Sharpmad*) download_url="https://github.com/jakobfriedl/precompiled-binaries/raw/main/Sharpmad.exe" ;;
                *SharpRDP*) download_url="https://github.com/jakobfriedl/precompiled-binaries/raw/main/SharpRDP.exe" ;;
                *SharpMove*) download_url="https://github.com/jakobfriedl/precompiled-binaries/raw/main/SharpMove.exe" ;;
                *SharpEfsPotato*) download_url="https://github.com/jakobfriedl/precompiled-binaries/raw/main/SharpEfsPotato.exe" ;;
                *SharpKatz*) download_url="https://github.com/jakobfriedl/precompiled-binaries/raw/main/SharpKatz.exe" ;;
                *SharpLAPS*) download_url="https://github.com/jakobfriedl/precompiled-binaries/raw/main/SharpLAPS.exe" ;;
                *BetterSafetyKatz*) download_url="https://github.com/jakobfriedl/precompiled-binaries/raw/main/BetterSafetyKatz.exe" ;;
                *GMSAPasswordReader*) download_url="https://github.com/jakobfriedl/precompiled-binaries/raw/main/GMSAPasswordReader.exe" ;;
                *ADSyncDecrypt*) download_url="https://github.com/jakobfriedl/precompiled-binaries/raw/main/ADSyncDecrypt.exe" ;;
            esac
            ;;
        "Dec0ne/KrbRelayUp")
            download_url="https://github.com/Dec0ne/KrbRelayUp/releases/latest/download/KrbRelayUp.exe"
            ;;
        "tylerdotrar/SigmaPotato")
            download_url="https://github.com/tylerdotrar/SigmaPotato/releases/latest/download/SigmaPotato.exe"
            ;;
        "antonioCoco/RunasCs")
            download_url="https://github.com/antonioCoco/RunasCs/releases/latest/download/RunasCs.zip"
            ;;
        "Macmod/godap")
            download_url="https://github.com/Macmod/godap/releases/latest/download/godap_linux_amd64.tar.gz"
            ;;
        "NHAS/reverse_ssh")
            if [[ "$pattern" == *"client"* ]]; then
                download_url="https://github.com/NHAS/reverse_ssh/releases/latest/download/client_linux_amd64"
            else
                download_url="https://github.com/NHAS/reverse_ssh/releases/latest/download/server_linux_amd64"
            fi
            ;;
        "DominicBreuker/goncat")
            download_url="https://github.com/DominicBreuker/goncat/releases/latest/download/goncat_linux_amd64"
            ;;
        "FalconOpsLLC/goexec")
            download_url="https://github.com/FalconOpsLLC/goexec/releases/latest/download/goexec_linux_amd64.tar.gz"
            ;;
        "es3n1n/defendnot")
            download_url="https://github.com/es3n1n/defendnot/releases/latest/download/defendnot.zip"
            ;;
        "nickvourd/Supernova")
            download_url="https://github.com/nickvourd/Supernova/releases/latest/download/Supernova_windows_amd64.zip"
            ;;
        "0xHasanM/LogonSessionAuditor")
            download_url="https://github.com/0xHasanM/LogonSessionAuditor/releases/latest/download/LogonSessionAuditor.exe"
            ;;
        "logangoins/SharpSuccessor")
            download_url="https://github.com/logangoins/SharpSuccessor/releases/latest/download/SharpSuccessor.exe"
            ;;
        "kgretzky/evilginx2")
            download_url="https://github.com/kgretzky/evilginx2/releases/latest/download/evilginx-v3.3.0-linux-64bit.tar.gz"
            ;;
        "doxx/darkflare")
            download_url="https://github.com/doxx/darkflare/releases/latest/download/darkflare-client_linux_amd64"
            ;;
        "Konloch/bytecode-viewer")
            download_url="https://github.com/Konloch/bytecode-viewer/releases/latest/download/Bytecode-Viewer-2.12.jar"
            ;;
        "CalebFenton/simplify")
            download_url="https://github.com/CalebFenton/simplify/releases/latest/download/simplify.jar"
            ;;
        "gojue/ecapture")
            download_url="https://github.com/gojue/ecapture/releases/latest/download/ecapture-v0.8.6-linux-x86_64.tar.gz"
            ;;
        "liamg/traitor")
            download_url="https://github.com/liamg/traitor/releases/latest/download/traitor-amd64"
            ;;
        "microsoft/avml")
            download_url="https://github.com/microsoft/avml/releases/latest/download/avml-linux-x86_64"
            ;;
        "volatilityfoundation/dwarf2json")
            download_url="https://github.com/volatilityfoundation/dwarf2json/releases/latest/download/dwarf2json-linux-amd64"
            ;;
        "cdk-team/CDK")
            download_url="https://github.com/cdk-team/CDK/releases/latest/download/cdk_linux_amd64"
            ;;
        "inguardians/peirates")
            download_url="https://github.com/inguardians/peirates/releases/latest/download/peirates-linux-amd64.tar.gz"
            ;;
        "Shopify/kubeaudit")
            download_url="https://github.com/Shopify/kubeaudit/releases/latest/download/kubeaudit_0.22.2_linux_amd64.tar.gz"
            ;;
        "quarkslab/kdigger")
            download_url="https://github.com/quarkslab/kdigger/releases/latest/download/kdigger-linux-amd64"
            ;;
        "BishopFox/cloudfox")
            download_url="https://github.com/BishopFox/cloudfox/releases/latest/download/cloudfox-linux-amd64.zip"
            ;;
        "BloodHoundAD/AzureHound")
            download_url="https://github.com/BloodHoundAD/AzureHound/releases/latest/download/azurehound-linux-amd64.zip"
            ;;
        "Flangvik/TeamFiltration")
            download_url="https://github.com/Flangvik/TeamFiltration/releases/latest/download/TeamFiltration-linux-x64.zip"
            ;;
        "sensepost/ruler")
            download_url="https://github.com/sensepost/ruler/releases/latest/download/ruler-linux64"
            ;;
        "0xsha/CloudBrute")
            download_url="https://github.com/0xsha/CloudBrute/releases/latest/download/cloudbrute_1.0.7_linux_amd64.tar.gz"
            ;;
        "aaronhnatiw/race-the-web")
            download_url="https://github.com/aaronhnatiw/race-the-web/releases/latest/download/race-the-web_2.1.0_linux_amd64.tar.gz"
            ;;
        *)
            # Fall back to API query
            download_url=$(curl -s --max-time 10 "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null | \
                jq -r ".assets[] | select(.name | test(\"$pattern\")) | .browser_download_url" 2>/dev/null | head -1)
            ;;
    esac

    # If a hardcoded URL was provided, verify it actually exists (versions go stale).
    # If 404 or unreachable, fall back to GitHub API to find the current asset.
    if [ -n "$download_url" ] && [ "$download_url" != "null" ]; then
        if ! curl -sIfL --max-time 10 "$download_url" >/dev/null 2>&1; then
            print_warning "Hardcoded URL stale for $repo (returned non-2xx) — falling back to API"
            download_url=""
        fi
    fi

    if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
        print_status "Querying GitHub API for $repo latest release asset..."
        download_url=$(curl -s --max-time 10 "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null | \
            jq -r ".assets[] | select(.name | test(\"$pattern\")) | .browser_download_url" 2>/dev/null | head -1)
    fi

    # Tier 3: API rate-limit fallback. Scrape the release page's expanded_assets
    # endpoint to get the actual current asset URLs. /releases/latest 302-redirects
    # to /releases/tag/<tag>; the expanded_assets/<tag> endpoint lists real asset
    # URLs. Both are unauthenticated public web (no rate limit).
    if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
        local tag
        tag=$(curl -sIL -o /dev/null -w "%{url_effective}" --max-time 10 "https://github.com/$repo/releases/latest" 2>/dev/null \
              | grep -oE 'tag/[^/]+' | sed 's|tag/||')
        if [ -n "$tag" ]; then
            print_status "Scraping release page for $repo tag $tag..."
            # Get list of asset URLs from the expanded_assets endpoint
            local asset_paths
            asset_paths=$(curl -sL --max-time 10 "https://github.com/$repo/releases/expanded_assets/$tag" 2>/dev/null \
                          | grep -oE "/$repo/releases/download/$tag/[^\"]+" | sort -u)
            if [ -n "$asset_paths" ]; then
                # Find first asset matching the pattern (treat $pattern as regex)
                local matched
                matched=$(echo "$asset_paths" | while read -r p; do
                    bn=$(basename "$p")
                    echo "$bn" | grep -qE "$pattern" && echo "$p" && break
                done | head -1)
                # Fuzzy fallback: case-insensitive + arch variants (amd64↔x86_64↔x64)
                if [ -z "$matched" ]; then
                    local fuzzy
                    fuzzy=$(echo "$pattern" | sed -E 's/(amd64|x86_64|x64)/(amd64|x86_64|x64)/g')
                    matched=$(echo "$asset_paths" | while read -r p; do
                        bn=$(basename "$p")
                        echo "$bn" | grep -qiE "$fuzzy" && echo "$p" && break
                    done | head -1)
                    [ -n "$matched" ] && print_status "(fuzzy match)"
                fi
                if [ -n "$matched" ]; then
                    download_url="https://github.com$matched"
                    print_success "Discovered via release-page scrape: $(basename "$matched")"
                fi
            fi
        fi
    fi

    if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
        print_warning "No download URL for: $pattern"
        print_status "Cloning repository instead..."
        clone_repo "$repo" "$output_dir"
        return $?
    fi

    filename=$(basename "$download_url")
    local temp_file="/tmp/$filename"

    print_status "Downloading $filename..."
    if ! curl -sL --max-time 120 "$download_url" -o "$temp_file" 2>/dev/null || [ ! -s "$temp_file" ]; then
        print_warning "Download failed, cloning instead..."
        clone_repo "$repo" "$output_dir"
        return $?
    fi

    # Extract based on file type
    mkdir -p "$output_dir"
    cd "$output_dir"

    case "$filename" in
        *.tar.gz|*.tgz)
            tar xzf "$temp_file" 2>/dev/null
            ;;
        *.zip)
            unzip -o -q "$temp_file" 2>/dev/null
            ;;
        *.gz)
            # Extract → file named "${filename%.gz}". Then also create a
            # version-stripped friendly alias (e.g. chisel_1.10.1_linux_amd64 → chisel)
            # so users can type the simple tool name.
            local stripped="${filename%.gz}"
            gunzip -c "$temp_file" > "$stripped" 2>/dev/null
            chmod +x "$stripped" 2>/dev/null
            # Friendly alias: take chars up to first underscore/digit
            local friendly
            friendly=$(echo "$stripped" | sed -E 's/[_-]?[0-9].*$//; s/[_-](linux|windows|amd64|x86_64|x64|darwin).*$//')
            if [ -n "$friendly" ] && [ "$friendly" != "$stripped" ] && [ ! -e "$friendly" ]; then
                cp "$stripped" "$friendly" 2>/dev/null
                chmod +x "$friendly" 2>/dev/null
            fi
            ;;
        *.7z)
            7z x -y "$temp_file" >/dev/null 2>&1
            ;;
        *)
            # Direct binary
            local target_name="${output_name:-$filename}"
            cp "$temp_file" "$output_dir/$target_name"
            chmod +x "$output_dir/$target_name" 2>/dev/null
            ;;
    esac

    rm -f "$temp_file"

    # Flatten: archives often extract into a single top-level subdir
    # (e.g. cloudfox.zip → cloudfox/cloudfox). Move that subdir's contents up
    # to $output_dir/ root and remove the now-empty wrapper dir.
    # Only flatten when there's EXACTLY ONE subdir (excluding source/) — that
    # signals a wrapping dir, not multiple meaningful subdirs.
    # Use a temp rename to avoid the case where the subdir's name matches a
    # file inside it (e.g. cloudfox/cloudfox the binary), which would block mv.
    local subdir_count
    subdir_count=$(find "$output_dir" -mindepth 1 -maxdepth 1 -type d ! -name source ! -name .git 2>/dev/null | wc -l)
    if [ "$subdir_count" = "1" ]; then
        local subdir
        subdir=$(find "$output_dir" -mindepth 1 -maxdepth 1 -type d ! -name source ! -name .git 2>/dev/null)
        if [ -n "$subdir" ] && [ -d "$subdir" ]; then
            local tmp_name="$output_dir/.__pg_flatten__"
            mv "$subdir" "$tmp_name"
            shopt -s dotglob nullglob
            mv "$tmp_name"/* "$output_dir/" 2>/dev/null
            shopt -u dotglob nullglob
            rmdir "$tmp_name" 2>/dev/null
        fi
    fi

    # Make any executables at root actually executable
    find "$output_dir" -maxdepth 1 -type f \( -name "*.exe" -o -name "*.sh" -o -name "*.py" -o -name "*.ps1" -o -name "*.bat" -o -name "*.pl" \) -exec chmod +x {} \; 2>/dev/null

    # Make executables executable
    find "$output_dir" -maxdepth 2 -type f \( -name "*.exe" -o -name "*.sh" -o -name "*.py" -o ! -name "*.*" \) -exec chmod +x {} \; 2>/dev/null

    return 0
}

clone_repo() {
    local repo="$1"
    local dest="$2"

    if [ -d "$dest/source/.git" ]; then
        print_status "Updating repository..."
        cd "$dest/source"
        GIT_TERMINAL_PROMPT=0 git pull -q 2>/dev/null || print_warning "Failed to update $repo"
    else
        print_status "Cloning repository..."
        rm -rf "$dest/source"
        GIT_TERMINAL_PROMPT=0 git clone -q "https://github.com/$repo.git" "$dest/source" 2>/dev/null || print_warning "Failed to clone $repo"
    fi
}

install_tool() {
    local tool_def="$1"

    IFS='|' read -r name repo category os pattern needs_compile compile_cmd <<< "$tool_def"

    local tool_dir=$(get_tool_dir "$os" "$category" "$name")
    local current_version=$(get_installed_version "$name")
    local latest_version=$(get_latest_version "$repo")

    # For repos without releases, use commit hash
    if [ -z "$latest_version" ]; then
        latest_version=$(curl -s "https://api.github.com/repos/$repo/commits/main" 2>/dev/null | jq -r '.sha[0:7] // empty')
        [ -z "$latest_version" ] && latest_version=$(curl -s "https://api.github.com/repos/$repo/commits/master" 2>/dev/null | jq -r '.sha[0:7] // empty')
    fi

    # Skip if up to date (in update mode)
    if [ "$UPDATE_MODE" = true ] && [ "$current_version" = "$latest_version" ] && [ -n "$current_version" ]; then
        print_success "$name is up to date ($current_version)"
        return 0
    fi

    echo ""
    print_status "Installing $name..."
    print_status "  Repo: $repo"
    print_status "  Category: $os/$category"
    [ -n "$latest_version" ] && print_status "  Version: $latest_version"

    mkdir -p "$tool_dir"
    mkdir -p "$tool_dir/source"

    # Handle different installation methods
    if [ "$pattern" = "CLONE" ]; then
        # Clone entire repository
        clone_repo "$repo" "$tool_dir"

        if [ "$needs_compile" = "true" ] && [ -n "$compile_cmd" ]; then
            mkdir -p /var/log/portalgun
            local build_log="/var/log/portalgun/build-${name}.log"
            print_status "Building $name (log: $build_log)..."
            cd "$tool_dir/source"
            if eval "$compile_cmd" > "$build_log" 2>&1; then
                print_success "Build succeeded for $name"
            else
                print_warning "Build failed for $name — see $build_log"
            fi
        fi

        # Copy scripts/binaries to tool root for easy access
        find "$tool_dir/source" -maxdepth 5 -type f \( -name "*.py" -o -name "*.sh" -o -name "*.ps1" -o -name "*.exe" -o -name "*.bat" -o -name "*.pl" -o -name "*.rb" \) 2>/dev/null | while read f; do
            cp -n "$f" "$tool_dir/" 2>/dev/null
        done

        # Surface compiled binaries from common build outputs (Go builds to source root,
        # Rust builds to source/target/release). Extensionless executable files only.
        find "$tool_dir/source" -maxdepth 1 -type f -executable \
            ! -name "*.go" ! -name "*.rs" ! -name "*.md" ! -name "*.txt" \
            ! -name "Makefile" ! -name "Dockerfile" ! -name "LICENSE*" \
            ! -name "*.sh" ! -name "*.py" ! -name "*.toml" ! -name "*.yaml" ! -name "*.yml" \
            2>/dev/null | while read f; do
            cp -n "$f" "$tool_dir/" 2>/dev/null
        done
        if [ -d "$tool_dir/source/target/release" ]; then
            find "$tool_dir/source/target/release" -maxdepth 1 -type f -executable \
                ! -name "*.d" ! -name "*.rlib" ! -name "*.so" ! -name "*.a" ! -name "*.dylib" \
                2>/dev/null | while read f; do
                cp -n "$f" "$tool_dir/" 2>/dev/null
            done
        fi
        # cargo install --root . writes to source/bin/
        if [ -d "$tool_dir/source/bin" ]; then
            find "$tool_dir/source/bin" -maxdepth 1 -type f -executable 2>/dev/null | while read f; do
                cp -n "$f" "$tool_dir/" 2>/dev/null
            done
        fi

    elif [ "$pattern" = "SPECIAL_KUBECTL" ]; then
        # Special case for kubectl
        print_status "Downloading kubectl..."
        curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" -o "$tool_dir/kubectl"
        chmod +x "$tool_dir/kubectl"
        latest_version=$(curl -sL https://dl.k8s.io/release/stable.txt)

    else
        # Download release asset + clone source
        # First try to get the binary
        download_release_asset "$repo" "$pattern" "$tool_dir" "$name"

        # Then clone source if it's a different repo (not Ghostpack-CompiledBinaries)
        if [[ "$repo" != "r3motecontrol/Ghostpack-CompiledBinaries" ]]; then
            clone_repo "$repo" "$tool_dir" 2>/dev/null || true
        fi
    fi

    # Surface scripts/binaries from source/ to tool_dir/ root (runs for ALL pattern
    # types — including the release-asset fallback-to-clone case, where the source/
    # clone provides the binaries that the release asset didn't).
    if [ -d "$tool_dir/source" ]; then
        find "$tool_dir/source" -maxdepth 5 -type f \( -name "*.py" -o -name "*.sh" -o -name "*.ps1" -o -name "*.exe" -o -name "*.bat" -o -name "*.pl" -o -name "*.rb" \) 2>/dev/null | while read f; do
            cp -n "$f" "$tool_dir/" 2>/dev/null
        done
    fi

    # Set version
    [ -n "$latest_version" ] && set_installed_version "$name" "$latest_version"

    # Auto-symlink Linux-runnable binaries to /usr/local/bin so users can run
    # tools by name from any shell. Skip windows/ targets (PE binaries can't run
    # on Linux) and skip if a command of that name already exists (don't shadow
    # apt-installed tools).
    if [[ "$os" != "windows" ]]; then
        find "$tool_dir" -maxdepth 1 -type f \
            \( -executable -o -name "*.sh" -o -name "*.py" -o -name "*.pl" -o -name "*.rb" \) \
            ! -name "*.exe" ! -name "*.ps1" ! -name "*.bat" ! -name "*.dll" \
            ! -name "*.md" ! -name "*.txt" ! -name "LICENSE*" \
            ! -name "*.json" ! -name "*.yaml" ! -name "*.yml" ! -name "*.toml" \
            ! -name "Dockerfile" ! -name "Makefile" ! -name "*.csproj" ! -name "*.sln" \
            ! -name "*.png" ! -name "*.jpg" ! -name "*.gif" \
            2>/dev/null | while read f; do
            local bn
            bn=$(basename "$f")
            local target="/usr/local/bin/$bn"
            # Never shadow a system command (anything already in /usr/bin, /bin,
            # /usr/sbin, /sbin). This prevents disasters like overwriting GNU find
            # with libc-database's `find` script.
            if [ -e "/usr/bin/$bn" ] || [ -e "/bin/$bn" ] || \
               [ -e "/usr/sbin/$bn" ] || [ -e "/sbin/$bn" ]; then
                continue
            fi
            # If /usr/local/bin/<name> exists and isn't already our symlink, leave it.
            if [ -L "$target" ] || [ ! -e "$target" ]; then
                ln -sf "$f" "$target"
            fi
        done
    fi

    print_success "$name installed to $tool_dir"
    return 0
}

list_tools() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "                    GitHub Tools Status"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    printf "%-20s %-12s %-15s %-15s %-10s\n" "TOOL" "OS" "CATEGORY" "INSTALLED" "LATEST"
    printf "%-20s %-12s %-15s %-15s %-10s\n" "----" "--" "--------" "---------" "------"

    for tool_def in "${TOOLS[@]}"; do
        IFS='|' read -r name repo category os pattern needs_compile compile_cmd <<< "$tool_def"

        local current=$(get_installed_version "$name")
        local latest=$(get_latest_version "$repo")
        local tool_dir=$(get_tool_dir "$os" "$category" "$name")

        [ -z "$current" ] && current="-"
        [ -z "$latest" ] && latest="N/A"

        if [ -d "$tool_dir" ] && [ "$current" != "-" ]; then
            if [ "$current" = "$latest" ]; then
                printf "%-20s %-12s %-15s ${GREEN}%-15s${NC} %-10s\n" "$name" "$os" "$category" "$current" "$latest"
            else
                printf "%-20s %-12s %-15s ${YELLOW}%-15s${NC} %-10s\n" "$name" "$os" "$category" "$current" "$latest"
            fi
        else
            printf "%-20s %-12s %-15s ${RED}%-15s${NC} %-10s\n" "$name" "$os" "$category" "NOT INSTALLED" "$latest"
        fi
    done
    echo ""
}

# ═══════════════════════════════════════════════════════════════════
# Main Execution
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════════"
if [ "$UPDATE_MODE" = true ]; then
    echo "           GitHub Security Tools - Update Mode"
elif [ "$LIST_MODE" = true ]; then
    echo "           GitHub Security Tools - List Mode"
else
    echo "           GitHub Security Tools - Install Mode"
fi
echo "═══════════════════════════════════════════════════════════════════"
echo ""

if [ "$LIST_MODE" = true ]; then
    list_tools
    exit 0
fi

# Process tools
INSTALLED_COUNT=0
FAILED_COUNT=0

for tool_def in "${TOOLS[@]}"; do
    IFS='|' read -r name repo category os pattern needs_compile compile_cmd <<< "$tool_def"

    # Skip if specific tool requested and doesn't match
    if [ -n "$SPECIFIC_TOOL" ] && [ "$name" != "$SPECIFIC_TOOL" ]; then
        continue
    fi

    if install_tool "$tool_def"; then
        INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
    else
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "                    ${GREEN}Complete!${NC}"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Summary:"
echo -e "  Processed: ${GREEN}$INSTALLED_COUNT${NC}"
echo -e "  Failed:    ${RED}$FAILED_COUNT${NC}"
echo ""
echo "Tools directory: $BASE_DIR"
echo ""
echo "Directory structure:"
echo "  /opt/tools/"
echo "  ├── tunneling/          (chisel, ligolo, nc64 - Linux + Windows builds)"
echo "  ├── enumeration/        (OS-agnostic tools NOT in apt)"
echo "  │   ├── web/            (nuclei, subfinder, katana, dnsx, naabu, dirsearch)"
echo "  │   └── recon/          (gau, waybackurls, hakrawler, arjun, paramspider)"
echo "  ├── linux/              (tools for Linux)"
echo "  │   ├── enumeration/    (pspy, linpeas, lse)"
echo "  │   ├── privesc/        (linux-exploit-suggester)"
echo "  │   └── ad/             (kerbrute, coercer, petitpotam, certipy, bloodhound.py...)"
echo "  └── windows/            (tools to transfer to Windows targets)"
echo "      ├── enumeration/    (winpeas, seatbelt, snaffler, sharpview, nopowershell)"
echo "      ├── privesc/        (godpotato, printspoofer, krbrelayup, sigmapotato...)"
echo "      ├── ad/             (rubeus, certify, whisker, sharpgpoabuse, runascs...)"
echo "      ├── credentials/    (mimikatz, lazagne, sharpkatz, sharplaps, dploot...)"
echo "      └── exploit/        (nishang, powercat)"
echo ""
echo "Wordlists: /usr/share/wordlists/ (seclists, rockyou, dirb, dirbuster, etc.)"
echo "BloodHound CE: Run 'bloodhound-ce' or access via Docker at localhost:8080"
echo ""

exit 0
