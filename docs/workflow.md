# Workflow diagrams

Three views of how agentbus works. GitHub renders each Mermaid block; the image under it is the same diagram, in your theme. Sources are in [`docs/diagrams/`](diagrams/); run `docs/diagrams/render.sh` to regenerate every image.

## A handoff, end to end

You set the goal, every agent that joins is shown it, and work moves through inboxes while claims keep two agents out of the same files. The dashed replies are what each agent sees: `inbox` prints `#1 claude -> codex [handoff]`, and a refused claim names the holder.

```mermaid
sequenceDiagram
    autonumber
    participant you as You
    participant claude as claude (lead)
    participant codex as codex (implementer)
    participant tests as tests (subagent)
    participant bus as The bus

    you->>bus: goal "auth on the new token API"
    claude->>bus: join
    bus-->>claude: goal (you, now): auth on the new token API
    Note over codex,bus: codex and tests join too,<br/>and see the same goal

    claude->>bus: post "auth refactor is yours" --to codex --kind handoff
    codex->>bus: inbox
    bus-->>codex: #35;1 claude -> codex [handoff]

    codex->>bus: claim src/auth/ --purpose "token API"
    bus-->>codex: claimed src/auth/
    tests->>bus: claim src/auth/
    bus--xtests: refused: src/auth/ is claimed by codex
    Note over tests,bus: exit 1, and the error says<br/>ask codex with post --kind question

    tests->>bus: post --to codex --kind question
    codex->>bus: inbox
    bus-->>codex: #35;2 tests -> codex [question]
    codex->>bus: post --to tests --reply-to 2 --kind answer

    codex->>bus: release src/auth/
    codex->>bus: post "done, tests green" --to claude --reply-to 1 --kind done
    claude->>bus: inbox
    bus-->>claude: #35;4 codex -> claude [done] re #35;1

    you->>bus: watch
    Note over you,bus: watch shows agents, claims, facts and messages, live
```

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/handoff-dark.png">
  <img src="diagrams/handoff-light.png" alt="A handoff, end to end, in 19 numbered steps: you set the goal; claude joins and sees it; claude posts a handoff to codex; codex reads #1 in its inbox and claims src/auth/; the tests subagent is refused and asks codex instead; codex answers, releases, and posts done; claude reads #4; you watch it live" width="100%">
</picture>

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

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/claims-dark.png">
  <img src="diagrams/claims-light.png" alt="Claim lifecycle: free, then held after claim PATH; held can be renewed, refused to another agent, released, expired, or lost when the holder goes; each path returns to free" width="100%">
</picture>

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

    classDef ok fill:#F5B800,stroke:#F5B800,color:#1f2328;
    classDef bad fill:transparent,stroke:#8b949e,stroke-dasharray: 5 4;
    class useenv,nearest,outer ok;
    class none,skip bad;
```

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/bus-selection-dark.png">
  <img src="diagrams/bus-selection-light.png" alt="Which bus a command uses: AGENTBUS_DB wins; otherwise start from the main checkout for a linked worktree, walk up to the nearest .agentbus/, skip HOME's own, and use the nearest bus or the Nth above it with --up N" width="100%">
</picture>
