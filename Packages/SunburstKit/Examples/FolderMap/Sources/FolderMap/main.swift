import SunburstAgents

// Started by an agent as `FolderMap --mcp`, the program only relays between the agent and the running app, and never
// returns. That's checked first, so a relay makes no window, no chart and no GPU work.
AgentDoor.relayIfAsked(.folderMap)
FolderMapApp.main()
