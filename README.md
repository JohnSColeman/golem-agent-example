# Golem Quickstart 

This is the Golem [Quickstart project](https://learn.golem.cloud/quickstart) project along with all the
steps to [setup Golem](https://learn.golem.cloud/cli/install-from-source) for local development on macOS.

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
Golem CLI. At this time version 1.4.0 is the latest release.

```shell
curl -L https://github.com/golemcloud/golem/releases/download/v1.4.0/golem-aarch64-apple-darwin -o ~/.cargo/bin/golem && chmod +x ~/.cargo/bin/golem
```

This line is in required in .zshrc to execute the golem command:

`export PATH="~/.cargo/bin/:$PATH"`

To check you are setup try printing Golems version on the command line:
```shell
 golem --version
```

### Tip
If you have been using a prior version of Golem it may have left incompatible runtime state, to
remove this, execute this command to remove all the local state:

```shell
rm -rf ~/Library/Application\ Support/golem/*
```

## Testing the project code

From the project directory, open a command prompt and try a build:

```shell
npm run build
```

Then start the golem server process:

```shell
npm run start
```

Deploy the component:

```shell
npm run deploy
```

Test the counter agent using its API:

```shell
curl -X POST http://localhost:9006/agent-1/increment   
```

This should return `{"result":"incremented agent-1, new value is 1"}% `