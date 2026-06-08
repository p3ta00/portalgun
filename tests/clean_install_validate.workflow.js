export const meta = {
  name: 'portalgun-clean-install-validate',
  description: 'Revert VM to clean snapshot, full install, validate ZERO errors/warnings, research+fix, repeat until clean',
  phases: [
    { title: 'Install',  detail: 'revert snapshot1 + re-expand disk + deploy repo + install all, poll to completion' },
    { title: 'Validate', detail: 'portalgun verify + install-log analyzer -> structured errors/warnings' },
    { title: 'Fix',      detail: 'research + fix each error/warning in the repo, commit' },
  ],
}

const MAX_ITER = 5

const ENV = `
JUMP=p3ta@192.168.1.49
VM_IP=192.168.122.23
VM_USER=kali
VM_PASS=kali
VM_NAME=linux2024
VM_SNAP=snapshot1
REPO=/home/p3ta/dev/portalgun
# helper to run a command on the VM as root via the jump host:
#   vm(){ ssh -o ConnectTimeout=10 "$JUMP" "sshpass -p $VM_PASS ssh -o StrictHostKeyChecking=no $VM_USER@$VM_IP 'sudo bash -lc \\"$1\\"'"; }
`.trim()

const INSTALL_SCHEMA = {
  type: 'object',
  required: ['completed', 'reachable', 'notes'],
  properties: {
    completed: { type: 'boolean', description: 'install reached "Done. Run \'portalgun status\'" (or finished)' },
    reachable: { type: 'boolean', description: 'VM came back up after revert and was deployed' },
    disk_gb: { type: 'number', description: 'root filesystem size in GB after re-expand' },
    duration_min: { type: 'number' },
    log_path: { type: 'string', description: 'path to the install log on the VM' },
    notes: { type: 'string', description: 'what happened, any blockers' },
  },
}

const VALIDATE_SCHEMA = {
  type: 'object',
  required: ['errors', 'warnings', 'verify_summary'],
  properties: {
    verify_summary: { type: 'string', description: 'the portalgun verify Passed/Warnings/Failed line' },
    errors: {
      type: 'array',
      items: {
        type: 'object',
        required: ['id', 'detail', 'source'],
        properties: {
          id: { type: 'string', description: 'short stable key, e.g. apt:boofuzz or verify:pip' },
          detail: { type: 'string', description: 'exact error text + context' },
          source: { type: 'string', description: 'verify | install-log | service | other' },
        },
      },
    },
    warnings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['id', 'detail', 'source'],
        properties: {
          id: { type: 'string' },
          detail: { type: 'string' },
          source: { type: 'string' },
        },
      },
    },
  },
}

const FIX_SCHEMA = {
  type: 'object',
  required: ['fixed', 'unresolved'],
  properties: {
    fixed: { type: 'array', items: { type: 'string', description: 'issue id + one-line fix summary' } },
    unresolved: { type: 'array', items: { type: 'string', description: 'issue id + why not fixed (benign/false-positive/blocked)' } },
    committed: { type: 'boolean' },
    commit: { type: 'string', description: 'commit hash if committed' },
  },
}

const history = []

for (let it = 1; it <= MAX_ITER; it++) {
  phase('Install')
  const inst = await agent(
`Iteration ${it} of a clean-install validation loop for the portalgun pentest-image installer.

Environment (copy these into your shell):
${ENV}

Do EXACTLY this, reporting progress, and return the schema at the end:

1. REVERT the VM to the clean snapshot:
   ssh -o ConnectTimeout=10 "$JUMP" "sudo virsh snapshot-revert $VM_NAME $VM_SNAP --running"
   Then poll until SSH answers (sshpass kali/kali). Up to ~4 min:
     until ssh "$JUMP" "sshpass -p $VM_PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 $VM_USER@$VM_IP echo ok" 2>/dev/null | grep -q ok; do sleep 5; done
   Clear stale host keys on both ends for $VM_IP if SSH complains.

2. RE-EXPAND THE DISK. snapshot1 predates a disk expansion, so after revert the
   qcow2 is 160G virtual but the partition is ~80G. As root on the VM:
     apt-get install -y -q cloud-guest-utils >/dev/null 2>&1 || true
     growpart /dev/vda 1 ; partx -u /dev/vda 2>/dev/null || partprobe /dev/vda 2>/dev/null || true ; resize2fs /dev/vda1
   Confirm 'df -h /' shows ~150G+. Record disk_gb.

3. DEPLOY the repo to the VM. First push your SSH key so rsync/ProxyJump works:
     pubkey=$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub 2>/dev/null)
     ssh "$JUMP" "sshpass -p $VM_PASS ssh -o StrictHostKeyChecking=no $VM_USER@$VM_IP 'mkdir -p ~/.ssh && echo \\"$pubkey\\" >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'"
     ssh "$JUMP" "sshpass -p $VM_PASS ssh -o StrictHostKeyChecking=no $VM_USER@$VM_IP 'echo $VM_PASS | sudo -S usermod -aG kali-trusted $VM_USER'" 2>/dev/null || true
   Then rsync (exclude .git, large gitignored assets are needed though — include data/sliver-armory if present locally):
     rsync -a --delete --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' --exclude='tests/logs' \\
       -e "ssh -o StrictHostKeyChecking=no -o ProxyJump=$JUMP" "$REPO/" "$VM_USER@$VM_IP:/home/$VM_USER/portalgun/"
   NOTE: the wheelhouse/apt-mirror/sliver-armory phases need the bundled data under /opt/portalgun/data — the installer copies data/ from the repo, so ensure data/sliver-armory and data/bapp-catalog.json made it over (they are gitignored but exist locally at $REPO/data/). If rsync excluded them, re-rsync that dir explicitly.

4. RUN THE FULL INSTALL as the kali USER (NOT root — install.sh self-sudos and
   creates its own temp sudoers), detached so an SSH drop doesn't kill it,
   auto-answering the "Press ENTER to continue" prompt with 'yes', logging to
   /tmp/pg_install.log:
     ssh "$JUMP" "sshpass -p $VM_PASS ssh $VM_USER@$VM_IP 'cd ~/portalgun && nohup bash -lc \\"yes | bash install.sh\\" >/tmp/pg_install.log 2>&1 & echo started'"
   The kali user must have passwordless sudo (it does: kali-grant-root). If the
   install aborts immediately on the prompt, confirm 'yes |' is feeding stdin.

5. POLL until done. The install prints \"INSTALLATION COMPLETE\" / portalgun verify summary at the end. Loop, checking every ~4-5 minutes (a full install is 60-120 min), up to ~150 min total:
     tail -3 /tmp/pg_install.log ; grep -qE 'INSTALLATION COMPLETE|Passed:[[:space:]]' /tmp/pg_install.log && echo DONE
   Use multiple Bash calls with sleep ~270 between checks (do NOT exceed the per-call timeout). Stop when you see the completion banner or the verify summary, or after ~150 min (report completed=false with notes).

Return INSTALL_SCHEMA. Be truthful about completed/reachable. Put the install log path (/tmp/pg_install.log on the VM) in log_path.`,
    { label: `install-iter${it}`, phase: 'Install', schema: INSTALL_SCHEMA },
  )

  if (!inst || !inst.reachable) {
    log(`Iteration ${it}: VM unreachable after revert — aborting loop`)
    return { success: false, iterations: it, reason: 'vm-unreachable', history }
  }

  phase('Validate')
  const val = await agent(
`Iteration ${it}: validate the portalgun install on the VM and report EVERY error and warning. ZERO is the target.

Environment:
${ENV}
Install log on VM: ${inst.log_path || '/tmp/pg_install.log'}

Run these as root on the VM (via the jump host) and aggregate results:
1. portalgun verify  -> capture the full output. Every WARN (!) row is a warning; every FAIL row is an error; record the "Passed: / Warnings: / Failed:" summary line.
2. The install-log analyzer (the GOOD one, tight regexes, not the naive grep):
     sudo bash /home/$VM_USER/portalgun/lib/export_install_log.sh /tmp/pg_install.log
   then read the produced summary JSON (it prints the path; also /tmp/install-summary.json). Count its error/failed/fatal entries (these are real errors) and its warning entries.
3. systemctl --failed  -> any failed portalgun-related service (tools-server, sliver-armory) is an error.

For EACH distinct error and warning, emit an entry with a short stable id (e.g. 'apt:boofuzz', 'verify:pip-wheelhouse', 'service:portalgun-sliver-armory', 'log:fatal-X'), the exact detail text + a few lines of context, and the source. DEDUPE. Do NOT include false positives (e.g. package names containing 'error', the literal 'Failed: 0' summary line, progress lines) — only genuine problems. If the install never completed, record that as an error.

Return VALIDATE_SCHEMA.`,
    { label: `validate-iter${it}`, phase: 'Validate', schema: VALIDATE_SCHEMA },
  )

  const errors = (val && val.errors) || []
  const warnings = (val && val.warnings) || []
  history.push({ iter: it, verify: val && val.verify_summary, errors, warnings })
  log(`Iteration ${it}: ${errors.length} errors, ${warnings.length} warnings — ${val && val.verify_summary}`)

  if (errors.length === 0 && warnings.length === 0) {
    log(`Iteration ${it}: ZERO errors / ZERO warnings — CLEAN. Done.`)
    return { success: true, iterations: it, verify: val && val.verify_summary, history }
  }

  phase('Fix')
  const issues = [...errors.map(e => ({ ...e, kind: 'error' })), ...warnings.map(w => ({ ...w, kind: 'warning' }))]
  const fix = await agent(
`Iteration ${it}: research and FIX these ${issues.length} install errors/warnings in the portalgun repo at /home/p3ta/dev/portalgun, then commit. The next loop iteration will revert + reinstall to verify.

Issues (JSON):
${JSON.stringify(issues, null, 2)}

For EACH issue:
- Find the root cause in the repo (the relevant installer/lib script). Read the actual code.
- If it's a REAL problem, fix it behavior-preservingly (the install must still install the same things). Research package/build errors (a failed pip/apt/github build, a missing dep, a service that won't start) — use web search for the specific error if needed.
- If it's a genuine FALSE POSITIVE or unavoidable-benign (e.g. an upstream 404, a cosmetic warning that reflects reality), fix the DETECTOR instead so it stops flagging it (tighten the log-analyzer regex in lib/export_install_log.sh, or adjust the verify threshold) — but ONLY when it's truly not a real defect. Do not paper over real failures.
- Prefer minimal, targeted edits. Keep the install's behavior identical.

After fixing, run 'bash -n' on every shell file you changed and 'python3 -m py_compile' on every .py you changed. Then commit ALL changes with a clear message summarizing the fixes (do NOT push). Return FIX_SCHEMA with the commit hash. List anything you could not resolve in 'unresolved' with the reason.`,
    { label: `fix-iter${it}`, phase: 'Fix', schema: FIX_SCHEMA },
  )
  log(`Iteration ${it}: fixed ${(fix && fix.fixed || []).length}, unresolved ${(fix && fix.unresolved || []).length}`)
  if (fix && fix.unresolved && fix.unresolved.length && (!fix.fixed || !fix.fixed.length)) {
    log(`Iteration ${it}: nothing fixable this round — stopping to avoid a no-progress loop`)
    return { success: false, iterations: it, reason: 'no-progress', history, lastUnresolved: fix.unresolved }
  }
}

return { success: false, iterations: MAX_ITER, reason: 'max-iterations', history }
