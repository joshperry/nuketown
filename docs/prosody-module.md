# Prosody Module: mod_nuketown_approval

Server-side Prosody module for routing `urn:nuketown:approval` stanzas
to the approval broker resource.

## Overview

Nuketown agents send approval requests (sudo, delegation, scaling) to
the human's bare JID as `<message type="normal">` stanzas containing a
child element in the `urn:nuketown:approval` namespace. Without server
routing, these land on whichever resource has highest priority — usually
the human's chat client, which can't process structured approval stanzas.

This module inspects incoming messages for the approval namespace and
routes them to the resource that advertises `urn:nuketown:approval` via
service discovery (XEP-0030). This is the approval broker
(`josh@6bit.com/nuketown-broker`), which runs as part of the
approval daemon on the human's workstation.

## How It Works

```
agent sends <message to="josh@6bit.com" type="normal">
  ├── has <approval xmlns="urn:nuketown:approval">
  │     → route to resource advertising urn:nuketown:approval (broker)
  └── plain <message type="chat">
        → route to chat client per normal XMPP rules
```

1. Module hooks `message/bare` (messages to bare JIDs)
2. Checks if the message contains `<approval xmlns="urn:nuketown:approval">`
3. If yes, queries disco#info for all online resources of the target JID
4. Finds the resource advertising `urn:nuketown:approval` as a feature
5. Rewrites the `to` attribute to the full JID of that resource
6. Returns the message for normal delivery to the full JID

### Fallback Behaviour

If no resource advertises the approval feature (broker offline):
- The message falls through to normal bare-JID delivery
- The human's chat client receives it as a regular message
- Chat client shows the raw XML or body (if present) as a notification
- This is intentional — the human still sees the request, just in a
  less structured form

## Broker Side

The approval broker (running in the human's session via
`approval-daemon.nix`) connects as `josh@6bit.com/nuketown-broker` and:

1. Registers `xep_0030` service discovery
2. Advertises `urn:nuketown:approval` as a feature
3. Listens for messages containing approval stanzas
4. Shows zenity dialog (local) or forwards to chat (remote)
5. Sends `<approval-response>` back to the agent's JID

## Implementation Location

This module lives in **mynix** (the liver.6bit.com Prosody config), not
in nuketown. Nuketown documents the expected behaviour; mynix implements
it.

Suggested path in mynix:
```
mynix/machines/liver/prosody/mod_nuketown_approval.lua
```

Prosody config addition:
```lua
-- In the relevant VirtualHost block
modules_enabled = {
    -- ... existing modules ...
    "nuketown_approval";
}
```

## Lua Module Skeleton

```lua
-- mod_nuketown_approval.lua
--
-- Routes messages containing urn:nuketown:approval stanzas
-- to the resource advertising that feature via XEP-0030.

local st = require "util.stanza";
local jid_split = require "util.jid".split;
local jid_join = require "util.jid".join;

local APPROVAL_NS = "urn:nuketown:approval";

module:add_feature(APPROVAL_NS);

local function find_approval_resource(user, host)
    -- Find the online resource advertising urn:nuketown:approval
    local sessions = prosody.hosts[host]
        and prosody.hosts[host].sessions
        and prosody.hosts[host].sessions[user];

    if not sessions then return nil; end

    for resource, session in pairs(sessions.sessions or {}) do
        -- Check if this resource advertises the approval feature
        -- via its disco#info capabilities
        local dominated = false;
        if session.caps_cache then
            for _, features in pairs(session.caps_cache) do
                if type(features) == "table" then
                    for _, feature in ipairs(features) do
                        if feature == APPROVAL_NS then
                            return jid_join(user, host, resource);
                        end
                    end
                end
            end
        end
    end

    return nil;
end

module:hook("message/bare", function(event)
    local stanza = event.stanza;

    -- Only process messages with approval namespace children
    local approval = stanza:get_child("approval", APPROVAL_NS);
    if not approval then return; end

    local to_user, to_host = jid_split(stanza.attr.to);
    if not to_user or not to_host then return; end

    -- Find the resource with the approval feature
    local target = find_approval_resource(to_user, to_host);

    if target then
        module:log("info",
            "Routing approval request %s to broker %s",
            approval.attr.id or "?", target);
        stanza.attr.to = target;
        -- Re-fire as a full-JID message
        module:send(stanza);
        return true; -- consumed
    else
        module:log("warn",
            "No approval broker online for %s@%s, falling through",
            to_user, to_host);
        -- Fall through to normal delivery
    end
end, 100); -- High priority so we run before default routing
```

## Capability Discovery

The module relies on XEP-0115 (Entity Capabilities) for efficient
feature lookup. When the broker connects and advertises
`urn:nuketown:approval` via `xep_0030`, Prosody's `mod_caps` caches
the capability hash. The routing module queries this cache rather than
issuing live disco#info queries.

**Required Prosody modules** (should already be enabled):
- `mod_caps` — Entity Capabilities caching
- `mod_disco` — Service Discovery

## Testing

### Manual Testing

1. Start the approval broker on the human's machine
2. Verify the broker advertises the feature:
   ```bash
   # From any XMPP client or prosodyctl
   prosodyctl shell
   > s2s:show_caps("josh@6bit.com/nuketown-broker")
   ```
3. Send a test approval stanza from an agent:
   ```bash
   # As the agent, send via slixmpp or prosodyctl
   prosodyctl shell
   > module:fire_event("message/bare", {
   >   stanza = st.message({to="josh@6bit.com", type="normal"})
   >     :tag("approval", {xmlns="urn:nuketown:approval", id="test1"})
   >       :tag("agent"):text("ada"):up()
   >       :tag("kind"):text("sudo"):up()
   >       :tag("command"):text("whoami"):up()
   >       :tag("timeout"):text("120"):up()
   > })
   ```
4. Verify the broker receives the message (not the chat client)
5. Disconnect the broker, resend — verify the chat client gets it

### Automated Testing

From a nuketown test VM with mock approval:
1. Connect two slixmpp clients: broker (advertising feature) and agent
2. Agent sends approval stanza to human's bare JID
3. Assert broker receives it
4. Disconnect broker
5. Agent sends again
6. Assert chat client resource receives the fallback

## Security Considerations

- The module only routes messages, never modifies content
- Routing is based on feature advertisement — any resource can
  advertise `urn:nuketown:approval` (trusted within the account)
- The broker authenticates as the human's account (not a separate
  service account), so no cross-account trust is needed
- Rate limiting is handled by Prosody's existing mechanisms
