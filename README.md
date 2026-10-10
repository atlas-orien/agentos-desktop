# AgentOS Desktop

Native macOS application for AgentOS, built with SwiftUI and AppKit where macOS
integration requires it.

This application is a frontend. It communicates with a separately running
headless AgentOS Runtime through a local full-duplex protocol. It does not
depend on `agent-cli` or any Rust runtime crate.

## Run

Start the Headless Runtime Host in the `agent` workspace first:

```bash
cd /Users/ancient/src/rust/agent-os/agent
cargo run -p agent-runtime-host
```

Then start the native application:

```bash
cd /Users/ancient/src/rust/agent-os/agentos-desktop
./scripts/run-app.sh
```

This builds and opens `AgentOS Desktop.app`. Do not use `swift run` for the
desktop UI: it launches a bare executable whose keyboard focus is owned by the
calling terminal rather than by a macOS application bundle.

The application connects through a user-private Unix domain socket at:

```text
~/Library/Application Support/AgentOS/runtime.sock
```

Set the same `AGENTOS_RUNTIME_SOCKET` value in both processes to override the
path during development. The protocol is JSON Lines, versioned independently
from both applications, and carries submitted user text, cancellation requests,
and final Runtime output.
