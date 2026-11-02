# Workflow diagrams

Three views of how agentbus works. Each diagram's source is in [`docs/diagrams/`](diagrams/); run `docs/diagrams/render.sh` to regenerate the images.

## A handoff, end to end

You set the goal, every agent that joins is shown it, and work moves through inboxes while claims keep two agents out of the same files.

```mermaid
sequenceDiagram
    participant you as You
    participant claude as claude (brain)
    participant codex as codex (hand)
    participant tests as tests (subagent)
    participant bus as The bus

    you->>bus: goal "auth on the new token API"
    claude->>bus: join
    bus-->>claude: goal: auth on the new token API
    codex->>bus: join
    bus-->>codex: goal: auth on the new token API
    tests->>bus: join
    bus-->>tests: goal: auth on the new token API

    claude->>bus: post --to codex --kind handoff
    codex->>bus: inbox
    bus-->>codex: handoff from claude

    codex->>bus: claim src/auth/ --purpose "token API"
    bus-->>codex: claimed src/auth/
    tests->>bus: claim src/auth/
    bus--xtests: claim_conflict, held by codex

    tests->>bus: post --to codex --kind question
    codex->>bus: post --to tests --reply-to 2 --kind answer

    codex->>bus: release src/auth/
    codex->>bus: post --to claude --kind done
    you->>bus: watch
```

![A handoff, end to end](diagrams/handoff.png)

## Claim lifecycle

A claim is held until it is released (release, or the holder runs leave), its TTL expires, or its holder drops off the roster and the next claim auto-releases it; claiming again renews it, and an overlapping claim from a different agent is refused.

```mermaid
stateDiagram-v2
    direction TB
    state "free" as free
    state "held" as held
    state "renewed<br/>claim again" as renewed
    state "refused<br/>another agent claims an overlapping path" as refused
    state "released<br/>release PATH" as released
    state "expired<br/>TTL passes, 120 min default" as expired
    state "holder gone<br/>off the roster (crashed or stale)" as gone

    [*] --> free
    free --> held: claim PATH
    held --> renewed
    renewed --> held
    held --> refused
    refused --> held: claim_conflict names the holder
    held --> released
    held --> expired
    held --> gone
    released --> free
    expired --> free
    gone --> free: next claim auto-releases
```

![Claim lifecycle](diagrams/claims.png)

## Which bus a command uses

`AGENTBUS_DB` wins; otherwise the command walks up to the nearest bus, and `--up N` reaches an outer one.

```mermaid
flowchart TD
    start(["agentbus command"]) --> env{{"AGENTBUS_DB set?"}}
    env -- yes --> useenv["Use that database<br/>(--up is ignored)"]
    env -- no --> wt{{"In a linked worktree?"}}
    wt -- yes --> main["Start at the same spot<br/>in the main checkout"]
    wt -- no --> walk
    main --> walk["Walk up to the nearest .agentbus/"]
    walk --> found{{"Found one?"}}
    found -- no --> none["agentbus: no bus here or in any parent folder.<br/>Run: agentbus init DIR"]
    found -- yes --> home{{"HOME's own .agentbus?"}}
    home -- yes --> skip["Never used: keep walking"]
    skip --> walk
    home -- no --> up{{"--up N given?"}}
    up -- no --> nearest["Use the nearest bus"]
    up -- yes --> outer["Use the Nth bus above it<br/>(buses lists the chain)"]

    classDef ok fill:#F5B800,stroke:#1f2328,color:#1f2328;
    classDef bad fill:#ffffff,stroke:#1f2328,color:#1f2328,stroke-dasharray: 5 4;
    class useenv,nearest,outer ok;
    class none,skip bad;
```

![Which bus a command uses](diagrams/bus-selection.png)
