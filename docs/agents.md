# Set up OmacVM with a coding agent

OmacVM is built to be driven by an agent as well as by hand. Paste this into
your coding agent (Claude Code, Codex, …):

```text
Set up OmacVM on my Mac (github.com/gillesgoetsch/omacvm): Omarchy in a VM.
Read https://raw.githubusercontent.com/gillesgoetsch/omacvm/main/AGENTS.md
first (section 0) and follow it. Install it with
curl -fsSL https://raw.githubusercontent.com/gillesgoetsch/omacvm/main/install.sh | bash -s -- --no-start
then walk me through the build: ask me OmacVM.app, UTM, VMware Fusion or Parallels,
how much of my Mac the VM gets and which features I want (explain each, scroll
momentum is experimental), show me the plan, ask for my password, build it, and
tell me the steps only I can do.
```

Other things to ask, for example: *"Turn on the scroll momentum for my VM
'Omarchy'"* or *"Update OmacVM and check my VM"*.

- [AGENTS.md](../AGENTS.md) is the manual for agents: recipes for building,
  switching features, updating and fixing, plus everything that was tried and
  does not work. Claude Code also picks up the skill in
  [.claude/skills/omacvm](../.claude/skills/omacvm/SKILL.md).
- Machine-readable: `omacvm vms --json`, `omacvm features --json`,
  `omacvm check --json`, `omacvm build --plan --json` (what would be built,
  the steps only you can do as `needs_human`, and the exact command).
- Nothing waits on a question without a terminal: `--yes` and options instead
  (`omacvm build --help`), the password from `OMACVM_PASSWORD`. Exit codes:
  0 done, 1 failed, 2 usage, 3 needs a person (installing an app, a macOS
  permission), and the message says what to do.

The steps that need you (macOS permission prompts, one Parallels setting, your
password) stay with you; the agent hands them over.
