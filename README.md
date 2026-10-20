# agentcheck

Find out what is going to break your agent setup, before it does.

You installed Claude Code or OpenClaw or Codex, it worked, and now you are running
agents against real work. This tells you which of the twenty-one things that reliably
go wrong are already wrong on your machine.

```bash
curl -fsSL https://raw.githubusercontent.com/belkenbot/agentcheck/main/agentcheck -o agentcheck
chmod +x agentcheck
./agentcheck
```

No install. One file. Delete it when you are done.

## What it will not do

Read the script before you run it, it is one file and it is commented. But so you
know what you are reading:

- **No network calls.** Not one. It cannot phone home because there is nothing to
  phone home with.
- **Read-only.** It never writes, moves, or deletes anything.
- **Nothing leaves your machine.** No telemetry, no upload, no account, no email
  gate.
- **It never prints a secret.** When it finds an exposed credential it tells you the
  file and the permissions, never the value.

## What it checks

**Memory** — whether your agent will still know anything tomorrow, and whether your
instruction file has grown past the size where the tail gets silently truncated at
load. That one is nasty. There is no error. The rules at the bottom of your file
just stop reaching the model.

**Cost** — whether every trivial task is going to a frontier model. Summarising,
tagging and classifying are the bulk of agent traffic and none of it needs the
expensive model.

**Blast radius** — whether anything is written down that tells your agent where to
stop, whether you have a blanket wildcard in your permission allowlist, whether
unattended execution is on globally, and whether your scheduled jobs are landing
inside live sessions.

**Secrets** — credentials in world-readable config, and .env files sitting in a git
repo that does not ignore them.

**Durability** — no backup of the config you spent months tuning, hand-patched vendor
code that the next update will silently revert, a Node version in the known dead
zone, transcript sprawl, and disk headroom.

**Observability** — whether anything would tell you that an agent stopped working,
and whether your scheduled jobs are throwing their errors into /dev/null.

## Where these came from

A four-machine fleet running since March: ninety-plus agents, a shared Postgres
memory layer, cron orchestration, browser automation, running real production work
every day.

Every check in this file is a failure that actually happened there. Not a best
practice from a blog post. A specific thing that broke, on a specific date, with a
specific cost. A few examples of what is behind the checks:

- A scheduled job configured against a live session key injected a foreign model into
  that conversation, forced a compaction, and wiped working memory. The symptom
  showed up days later as "the agent forgot everything" and took weeks to trace.
- A hand-patched dependency was reverted by a routine update. The tool still ran, so
  nothing looked broken, and the capability it provided quietly disappeared.
- One hundred and eighteen connection-refused lines in a log were written off as
  cosmetic noise. They were the actual blocker. Nothing shipped for weeks because the
  real error was hiding in noise nobody had cleaned up.
- A credential was hardcoded into a scheduled job's prompt. After a rotation the job
  read the current value and put it in an alert message.

The full writeup of what broke, what it cost, and how each one got fixed:
**https://belken.ai/field-manual**

## Tests

Every bug fixed here so far was the same shape: a check that silently stopped
firing on a real setup. `test/run-tests.sh` guards against that. It builds a
throwaway fake `HOME` for each scenario, runs agentcheck against it, and asserts
the right finding fired or stayed silent.

```bash
bash test/run-tests.sh
```

Exits `0` when every assertion passes, `1` otherwise. Add a scenario when you add
a check.

## Exit codes

Always `0`. This is a report, not a gate. If you want it in CI, parse the output.

## Licence

Do what you want with it. Fork it, rename it, ship it inside your own thing. If you
add a check that caught something real, open a PR and say what it caught.

Built by Belken Ventures.
