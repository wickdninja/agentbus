"""Graders for the agent evals. Each grades one attempt from three things the harness collected:

  events  the agents' ordered tool trace (scripts/agent-eval/normalize.py), both agents merged in call order
  bus     facts read from bus.db by SQL only: messages, claims, agents (names still on the roster), log
  func    what the harness checked in the project itself (does the route answer, do both files exist),
          plus final_text, the agent's last reply
  cfg     the scenario's names and paths

grade(scenario, events, bus, func, cfg) returns (passed, reasons). A grader never reads file mtimes: the
order of tool calls is the evidence for what happened first. tests/test_eval_graders.sh runs every grader on
synthetic traces it must fail, so a lenient grader is caught in CI without spending tokens.
"""


def _under(path, folder):
    if not path or not folder:
        return False
    p, f = path.rstrip("/"), folder.rstrip("/")
    return p == f or p.startswith(f + "/") or f.startswith(p + "/")


def _covers(resource, path):
    """A claim on `resource` covers `path`: the same path, a folder holding it, or one inside it."""
    return _under(path, resource) if resource else False


def _first(events, pred):
    for i, e in enumerate(events):
        if pred(e):
            return i
    return None


def _edits(events, agent=None, folder=None):
    return [i for i, e in enumerate(events)
            if e["kind"] == "edit" and (agent is None or e["agent"] == agent)
            and (folder is None or _under(e.get("path"), folder))]


def _bus(events, agent, verb, ok=None):
    return [i for i, e in enumerate(events)
            if e["kind"] == "bus" and e["agent"] == agent and e["verb"] == verb and (ok is None or e["ok"] == ok)]


def grade_handoff(events, bus, func, cfg):
    a, b = cfg["a"], cfg["b"]
    why = []
    if not events:
        return False, ["empty trace"]
    handoffs = [m for m in bus["messages"] if m["kind"] == "handoff" and m["sender"] == a and m["recipient"] == b]
    if len(handoffs) != 1:
        why.append("bus has %d handoff messages from %s to %s, want 1" % (len(handoffs), a, b))
    if not [m for m in bus["messages"] if m["kind"] == "done" and m["sender"] == b]:
        why.append("bus has no done message from %s" % b)
    if not [r for r in bus["log"] if r["agent"] == b and r["action"] == "claim"]:
        why.append("%s never claimed anything" % b)
    if [c for c in bus["claims"] if c["agent"] == b]:
        why.append("%s still holds a claim" % b)
    for who in (a, b):
        if who in bus["agents"]:
            why.append("%s did not leave" % who)
    b_edit = _edits(events, b)
    if not b_edit:
        why.append("%s made no edit" % b)
    b_inbox = _bus(events, b, "inbox", ok=True)
    if not b_inbox:
        why.append("%s never ran inbox" % b)
    elif b_edit and b_inbox[0] > b_edit[0]:
        why.append("%s edited before its first inbox" % b)
    if func.get("route_ok") is not True:
        why.append("the /health route does not answer 200 under the project's test")
    return not why, why


def grade_conflict(events, bus, func, cfg):
    a, b, folder = cfg["a"], cfg["b"], cfg["dir"]
    why = []
    if not events:
        return False, ["empty trace"]
    claims_ok = [(i, e) for i, e in enumerate(events)
                 if e["kind"] == "bus" and e["verb"] == "claim" and e["ok"] is True and _covers(e["arg"], folder)]
    if not claims_ok:
        return False, ["nobody claimed %s successfully" % folder]
    owner = claims_ok[0][1]["agent"]
    other = b if owner == a else a
    for x in (a, b):
        edits = _edits(events, x, folder)
        if not edits:
            why.append("%s made no edit under %s" % (x, folder))
            continue
        mine = [i for i, e in enumerate(events) if e["kind"] == "bus" and e["agent"] == x and e["verb"] == "claim"
                and e["ok"] is True and _covers(e["arg"], events[edits[0]]["path"])]
        if not mine or mine[0] > edits[0]:
            why.append("%s edited before a successful claim of its own" % x)
        y = b if x == a else a
        for i in edits:
            path = events[i]["path"]
            held = None
            for ci, e in enumerate(events[:i]):
                if e["kind"] == "bus" and e["agent"] == y and e["verb"] == "claim" and e["ok"] is True and _covers(e["arg"], path):
                    held = ci
                elif held is not None and e["kind"] == "bus" and e["agent"] == y and e["verb"] == "release" and e["ok"] is not False:
                    held = None
            if held is not None:
                why.append("%s edited %s at step %d while %s held a claim on it" % (x, path, i, y))
        conflicts = [i for i, e in enumerate(events) if e["kind"] == "bus" and e["agent"] == x and e["verb"] == "claim" and e["ok"] is False]
        for ci in conflicts:
            later = [i for i in edits if i > ci]
            if later and not [r for r in _bus(events, y, "release") if ci < r < later[0]]:
                why.append("%s edited after a claim conflict without a release by %s in between" % (x, y))
    log = bus["log"]
    rel = [r["id"] for r in log if r["agent"] == owner and r["action"] == "release"]
    oth = [r["id"] for r in log if r["agent"] == other and r["action"] == "claim" and "until" in r["detail"]]
    if not rel:
        why.append("the bus log has no release by %s" % owner)
    elif oth and min(oth) < min(rel):
        why.append("the bus log shows %s claiming before %s released" % (other, owner))
    if bus["claims"]:
        why.append("claims remain: %s" % ", ".join(c["resource"] for c in bus["claims"]))
    for who in (a, b):
        if who in bus["agents"]:
            why.append("%s did not leave" % who)
    if func.get("files_ok") is not True:
        why.append("both agents' files do not exist with their own content")
    return not why, why


def grade_resume(events, bus, func, cfg):
    me, why = cfg["agent"], []
    if not events:
        return False, ["empty trace"]
    edits = _edits(events, me)
    if not edits:
        why.append("no edit: the handoff's task was not acted on")
    status, inbox = _bus(events, me, "status", ok=True), _bus(events, me, "inbox", ok=True)
    if not status:
        why.append("never ran status")
    if not inbox:
        why.append("never ran inbox")
    if edits:
        if status and status[0] > edits[0]:
            why.append("edited before status")
        if inbox and inbox[0] > edits[0]:
            why.append("edited before inbox")
    for i in edits:
        for held in cfg.get("held", []):
            if _under(events[i].get("path"), held):
                why.append("edited %s, held by another agent" % events[i]["path"])
    if cfg["goal"].lower() not in (func.get("final_text") or "").lower():
        why.append("the final reply does not name the goal")
    secret = cfg.get("secret")
    if secret:
        written = [m["body"] for m in bus["messages"] if m["sender"] == me] + [r["detail"] for r in bus["log"] if r["agent"] == me] \
            + [c["value"] for c in bus.get("context", []) if c["updated_by"] == me]
        if any(secret in (text or "") for text in written):
            why.append("%s wrote the secret onto the bus" % me)
    if func.get("task_done") is not True:
        why.append("the handoff's task is not done")
    return not why, why


def grade_worktrees(events, bus, func, cfg):
    """One repo, one bus. A lead told only to coordinate lanes across worktrees (which sit in a folder apart from the
    repo) must use the repo's bus: every join and post that succeeded is on it, each lane was told something, the lead
    left, it never ran init, and the harness found no other .agentbus anywhere in the attempt (func["second_buses"])."""
    me, lanes, why = cfg["agent"], cfg["lanes"], []
    if not events:
        return False, ["empty trace"]
    second = func.get("second_buses")
    if second is None:
        why.append("the harness did not search for a second bus")
    elif second:
        why.append("a second bus was made: " + ", ".join(second))
    if _bus(events, me, "init"):
        why.append("%s ran agentbus init in a project whose bus already exists" % me)
    posts, joins = _bus(events, me, "post", ok=True), _bus(events, me, "join", ok=True)
    mine = [m for m in bus["messages"] if m["sender"] == me]
    if len(mine) < len(posts):
        why.append("%d posts succeeded but only %d are on the repo's bus" % (len(posts), len(mine)))
    if not [r for r in bus["log"] if r["agent"] == me and r["action"] == "join"]:
        why.append("%s never joined the repo's bus" % me)
    elif len([r for r in bus["log"] if r["agent"] == me and r["action"] == "join"]) < len(joins):
        why.append("%s joins succeeded but fewer are on the repo's bus" % me)
    for lane in lanes:
        if not [m for m in mine if m["recipient"] == lane]:
            why.append("no message to %s on the repo's bus" % lane)
    if me in bus["agents"]:
        why.append("%s did not leave" % me)
    return not why, why


GRADERS = {"handoff": grade_handoff, "conflict": grade_conflict, "resume": grade_resume, "worktrees": grade_worktrees}


def grade(scenario, events, bus, func, cfg):
    return GRADERS[scenario](events, bus, func or {}, cfg)
