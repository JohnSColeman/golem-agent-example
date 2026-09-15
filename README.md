# Golem Quickstart 

This is the Golem [Quickstart project](https://learn.golem.cloud/v1.5/quickstart) project along with all the
steps to [setup Golem](https://learn.golem.cloud/v1.5/cli/install-from-source) for local development on macOS.

## Prerequisite steps
- install rust
- setup golem

### Installing Rust

If you do not have Rust then install it using this script:

```shell
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

If you do have Rust check your Rust is the latest stable and update it if required:

```shell
rustup update
```

## Setup Golem - macOS

If you plan to deploy to and test with Golem locally as required for this project, you will need to install the full
Golem. At this time version 1.5.10 is the latest release.

```shell
curl -L https://github.com/golemcloud/golem/releases/download/v1.5.10/golem-aarch64-apple-darwin -o ~/.cargo/bin/golem && chmod +x ~/.cargo/bin/golem
```

This line is in required in .zshrc to execute the golem command:

`export PATH="~/.cargo/bin/:$PATH"`

To check you are setup try printing Golems version on the command line:
```shell
 golem --version
```

### Tip
If you have been using a prior version of Golem it may have left incompatible runtime state, to
remove this, execute this command to remove all the local state or better still use the `golem server run --clean` argument:

```shell
rm -rf ~/Library/Application\ Support/golem/*
```

## Testing the project code

Scripts have been added to the default package.json. From the project directory, open a command prompt and try a build:

```shell
npm run build
```

Then start the golem server process:

```shell
npm run start-golem
```

Deploy the component:

```shell
npm run deploy
```

Test the counter agent using its API:

```shell
curl -X POST http://app.localhost:9006/counters/agent-1/increment
```

This should return `1.0`

## Coding agent skills

This project includes coding-agent skills in `.agents/skills/` (also listed in `AGENTS.md`). These are installed
automatically when the project is first created with `golem new my-app`, not as a separate step. If you're using an AI
coding agent (e.g. Claude Code) to work on this project, it can load these skills to learn how to perform
Golem-specific tasks — building, deploying, adding agents and endpoints, configuring RDBMS connections,
scheduling, webhooks, and more — instead of guessing at the correct commands and manifest structure. Note that
a coding agent may need its skill list reloaded (or the agent restarted) to pick up skills installed this way.
The skills section of `AGENTS.md` is managed by Golem tooling and should not be edited by hand.
