// The cage's extra Seatbelt rules (cage-config.py `seatbelt`): rules sandbox-runtime has no
// setting for. withRules() puts seatbelt-exec.sh in place of sandbox-exec in the command
// sandbox-runtime built, and seatbelt-exec.sh appends the rules to the profile. It throws when
// that cannot be done, so run.mjs refuses rather than run the command without them.

const SANDBOX_EXEC = '/usr/bin/sandbox-exec'

const quote = arg => `'${arg.replaceAll("'", "'\\''")}'`

export function withRules (wrapped, rules, wrapper, platform = process.platform) {
  if (!rules?.length || platform !== 'darwin') return wrapped
  const at = wrapped.indexOf(SANDBOX_EXEC)
  if (at < 0 || wrapped.indexOf(SANDBOX_EXEC, at + 1) >= 0) {
    throw new Error(`expected ${SANDBOX_EXEC} exactly once in the sandbox command`)
  }
  const call = [wrapper, ...rules, '--'].map(quote).join(' ')
  return wrapped.slice(0, at) + call + wrapped.slice(at + SANDBOX_EXEC.length)
}
