// Run a command inside a cage built by cage-config.py.
//
//   node run.mjs <cage.json> -- <command> [args...]
//
// The command runs under the cage's sandbox-runtime config with the cage's environment
// added. A cage that cannot be built is a refusal: the command never runs outside it.
// The exit status is the command's (a command killed by a signal kills this process with
// the same signal).

import { SandboxManager } from '@anthropic-ai/sandbox-runtime'
import { spawn } from 'node:child_process'
import { mkdirSync, readFileSync } from 'node:fs'

const quote = arg => `'${arg.replaceAll("'", "'\\''")}'`

const args = process.argv.slice(2)
const split = args.indexOf('--')
if (split !== 1 || args.length < 3) {
  console.error('usage: node run.mjs <cage.json> -- <command> [args...]')
  process.exit(2)
}
const cagePath = args[0]
const command = args.slice(2)

let cage
try {
  cage = JSON.parse(readFileSync(cagePath, 'utf8'))
  // sandbox-runtime hands the command TMPDIR from this process's CLAUDE_CODE_TMPDIR.
  const tmp = cage.env.CLAUDE_CODE_TMPDIR
  mkdirSync(tmp, { recursive: true, mode: 0o700 })
  process.env.CLAUDE_CODE_TMPDIR = tmp
  await SandboxManager.initialize(cage.sandbox)
} catch (error) {
  console.error(`run.mjs: cannot build the cage from ${cagePath}: ${error.message}`)
  process.exit(1)
}

const wrapped = await SandboxManager.wrapWithSandbox(command.map(quote).join(' '))
const child = spawn(wrapped, {
  shell: true,
  stdio: 'inherit',
  env: { ...process.env, ...cage.env },
})

// The terminal delivers Ctrl-C / Ctrl-Z to the whole foreground group: the command
// handles them itself, this process stays to report its exit.
for (const signal of ['SIGINT', 'SIGQUIT', 'SIGTSTP']) process.on(signal, () => {})
for (const signal of ['SIGTERM', 'SIGHUP']) process.on(signal, () => child.kill(signal))

child.on('exit', async (code, signal) => {
  await SandboxManager.reset()
  if (signal) {
    process.removeAllListeners(signal)
    process.kill(process.pid, signal)
  }
  process.exit(code ?? 1)
})
