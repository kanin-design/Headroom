# ``SunburstAgents``

Lets AI agents look at a chart and point at things on it, over MCP, once the user allows them.

## Overview

An app describes itself in an ``AgentHost`` (its name, what agents are told, its folder and its tools) and opens an
``AgentDoor`` with a closure that answers each call. ``SunburstAgentTools`` gives any `SunburstChart` eight tools for free:
a summary of what's on it, finding things by name, what's inside a node, a picture, zooming in and out, and lighting things
up.

```swift
let door = AgentDoor.open(.myApp) { call in
    try SunburstAgentTools.answer(call, chart: chart)
}
```

As the first thing the program does, `AgentDoor.relayIfAsked(.myApp)` lets the same program, started by an agent with
`--mcp`, relay between the agent and the running app.

An agent gets nothing until the user allows it: `agentQuestion(_:explaining:)` asks in the app's window, and
``AgentAccessView`` lists who's asking, who's allowed, and what each agent did. Which program is on the other end, and
who signed it, is read from the system. The door is a socket file that only the user can open; nothing listens on the
network.

## Topics

### Opening the door

- ``AgentHost``
- ``AgentDoor``

### Tools

- ``AgentTool``
- ``AgentCall``
- ``AgentReply``
- ``AgentFailure``
- ``SunburstAgentTools``

### The user's side

- ``Agents``
- ``AgentAccessView``
- ``AgentIdentity``
- ``AllowedAgent``
- ``AgentRequest``
- ``AgentDecision``
- ``ConnectedAgent``
- ``AgentActivity``
