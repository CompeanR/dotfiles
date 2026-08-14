const VERIFY_AGENT = /(?:^|[./_-])work-verify$/i;
const WRITER_AGENT = /(?:^|[./_-])(?:work-apply|jd-fix-agent|worker)$/i;
const EXPLICIT_DELEGATION = /\b(subagents?|delegate|delegation|parallel|fan[ -]?out|orchestrat(?:e|ion)|reviewers?)\b|\b(?:multiple|several|\d+|two|three|four)\s+agents?\b/i;
const EXPLICIT_VERIFY = /\b(verify|verification|review|audit|double-check|independent check)\b/i;
const RISK_RATIONALE = /\b(concurr(?:ency|ent)|race|deadlock|security|auth(?:entication|orization)?|migration|data loss|breaking|public interface|regression|flaky|performance|subtle|cross-cutting|uncertain|high[ -]?risk)\b/i;
const HIGH_RISK_PATH = /(?:^|[/_.-])(auth|security|permission|credential|secret|payment|billing|migration|schema|database|deploy|release|workflow|lock|settings?|config|agents?|extensions?|subagents?)(?:[/_.-]|$)/i;
const MUTATING_BASH = /(?:^|[;&|]\s*)(?:rm|mv|cp|install|mkdir|touch|truncate|chmod|chown|ln|sed\s+-i|perl\s+-pi|git\s+(?:apply|checkout|reset|clean|mv|rm)|npm\s+(?:install|uninstall|update)|pnpm\s+(?:add|remove|install|update)|yarn\s+(?:add|remove|install)|cargo\s+(?:add|remove)|pip\s+install)\b|(^|[^>])>{1,2}(?![&])|\btee\b/i;
const MUTATION_INTENT = /\b(?:implement|build|change|fix|refactor|migrat\w*|redesign|integrat\w*|overhaul|add|remove|update)\b/i;
const MEANINGFUL_LANE_INTENT = /\b(?:debug\w*|diagnos\w*|root[ -]?cause|implement\w*|build\w*|review\w*|audit\w*)\b/i;
const EXPLICIT_SMALL_SCOPE = /\b(?:tiny|trivial|mechanical|typo|spelling|formatting|one[- ]line|single[- ]line|one sentence|single sentence|tightly coupled)\b|\b(?:docs?|documentation|comments?|wording)[ -]only\b|\blocali[sz]ed\s+(?:edit|change|rename)\b/i;
const MULTI_AREA_SCOPE = /\b(?:multiple|several|many|across)\s+(?:files?|modules?|components?|packages?|services?|systems?)\b|\bmulti[ -](?:file|module|component|package|service)\b/i;
const STRUCTURAL_SCOPE = /\b(?:architecture|architectural|cross[ -]cutting|refactor|migration|integration|overhaul|redesign)\b/i;
const DIRECT_WORK_TOOLS = new Set([
  "bash",
  "edit",
  "fetch_content",
  "get_search_content",
  "mcp",
  "mcpscript",
  "read",
  "source_check",
  "web_search",
  "write",
]);

function finiteInteger(value, fallback = 0) {
  return Number.isInteger(value) && value >= 0 ? value : fallback;
}

function stableValue(value) {
  if (Array.isArray(value)) return value.map(stableValue);
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(
    Object.entries(value)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, child]) => [key, stableValue(child)]),
  );
}

function fingerprint(input) {
  return JSON.stringify(stableValue(input));
}

function collectAgents(value, agents = []) {
  if (Array.isArray(value)) {
    for (const child of value) collectAgents(child, agents);
    return agents;
  }
  if (!value || typeof value !== "object") return agents;

  for (const [key, child] of Object.entries(value)) {
    if (key === "agent" && typeof child === "string") agents.push(child);
    else collectAgents(child, agents);
  }
  return agents;
}

function agentsFromWorkflowScript(script) {
  if (typeof script !== "string") return [];
  return [...script.matchAll(/\bagent\s*:\s*["'`]([^"'`]+)["'`]/g)].map((match) => match[1]);
}

function taskText(input) {
  const fragments = [];
  const visit = (value, key = "") => {
    if (typeof value === "string" && (key === "task" || key === "workflowScript")) fragments.push(value);
    else if (Array.isArray(value)) value.forEach((child) => visit(child, key));
    else if (value && typeof value === "object") {
      for (const [childKey, child] of Object.entries(value)) visit(child, childKey);
    }
  };
  visit(input);
  return fragments.join("\n");
}

function declaredChildren(input, agents) {
  if (Array.isArray(input?.tasks)) {
    return input.tasks.reduce((total, task) => total + Math.max(1, finiteInteger(task?.count, 1)), 0);
  }
  if (typeof input?.workflowScript === "string") return Math.max(1, agents.length);
  if (Array.isArray(input?.chain)) return Math.max(1, agents.length);
  return typeof input?.agent === "string" ? 1 : Math.max(1, agents.length);
}

function analyzeSubagentInput(input) {
  const management = typeof input?.action === "string" && input.action.length > 0;
  const agents = [
    ...collectAgents(input),
    ...agentsFromWorkflowScript(input?.workflowScript),
  ];
  const uniqueAgents = [...new Set(agents)];
  return {
    management,
    agents: uniqueAgents,
    childCount: management ? 0 : declaredChildren(input, agents),
    hasVerify: uniqueAgents.some((agent) => VERIFY_AGENT.test(agent)),
    hasWriter: uniqueAgents.some((agent) => WRITER_AGENT.test(agent)),
    taskText: taskText(input),
    fingerprint: management ? undefined : fingerprint(input),
  };
}

function emptyRisk() {
  return {
    files: new Set(),
    editChars: 0,
    highRisk: false,
    uncertainMutation: false,
    delegatedWriter: false,
  };
}

export function createHarnessState(snapshot = {}) {
  const risk = snapshot.risk && typeof snapshot.risk === "object" ? snapshot.risk : {};
  return {
    mutationRevision: finiteInteger(snapshot.mutationRevision),
    verifiedRevision: finiteInteger(snapshot.verifiedRevision),
    risk: {
      files: new Set(Array.isArray(risk.files) ? risk.files.filter((item) => typeof item === "string") : []),
      editChars: finiteInteger(risk.editChars),
      highRisk: risk.highRisk === true,
      uncertainMutation: risk.uncertainMutation === true,
      delegatedWriter: risk.delegatedWriter === true,
    },
    prompt: {
      text: "",
      explicitDelegation: false,
      explicitVerify: false,
      attemptedChildren: 0,
      attemptedFingerprints: new Set(),
      audit: {
        reminderRequired: false,
        delegationUsed: false,
        directExecutionUsed: false,
        finished: false,
      },
    },
  };
}

export function snapshotHarnessState(state) {
  return {
    version: 1,
    mutationRevision: state.mutationRevision,
    verifiedRevision: state.verifiedRevision,
    risk: {
      files: [...state.risk.files].sort(),
      editChars: state.risk.editChars,
      highRisk: state.risk.highRisk,
      uncertainMutation: state.risk.uncertainMutation,
      delegatedWriter: state.risk.delegatedWriter,
    },
  };
}

export function beginPrompt(state, prompt) {
  const text = typeof prompt === "string" ? prompt : "";
  const substantial = !EXPLICIT_SMALL_SCOPE.test(text)
    && (
      MEANINGFUL_LANE_INTENT.test(text)
      || (
        MUTATION_INTENT.test(text)
        && (RISK_RATIONALE.test(text) || MULTI_AREA_SCOPE.test(text) || STRUCTURAL_SCOPE.test(text))
      )
    );
  state.prompt = {
    text,
    explicitDelegation: EXPLICIT_DELEGATION.test(text),
    explicitVerify: EXPLICIT_VERIFY.test(text),
    attemptedChildren: 0,
    attemptedFingerprints: new Set(),
    audit: {
      reminderRequired: substantial,
      delegationUsed: false,
      directExecutionUsed: false,
      finished: false,
    },
  };
}

export function delegationReminder(state) {
  if (!state.prompt.audit.reminderRequired) return undefined;
  return "This request appears to involve substantial debugging, implementation, or review. Before acting, briefly state `delegate` or `direct` and why. Actively consider one focused child when it can own a meaningful lane; direct execution remains appropriate for small or tightly coupled work. This is an audit reminder, not a gate.";
}

export function finishPromptAudit(state) {
  const audit = state.prompt.audit;
  if (!audit.reminderRequired || audit.finished) return undefined;
  audit.finished = true;

  const outcome = audit.delegationUsed
    ? (audit.directExecutionUsed ? "mixed" : "delegated")
    : (audit.directExecutionUsed ? "direct" : "no-execution");
  return {
    version: 1,
    outcome,
    delegationUsed: audit.delegationUsed,
    directExecutionUsed: audit.directExecutionUsed,
  };
}

function riskReasons(state, analysis) {
  const reasons = [];
  if (state.risk.editChars >= 2000) reasons.push("large edit volume");
  if (state.risk.files.size >= 4) reasons.push("four or more changed files");
  if (state.risk.highRisk) reasons.push("high-risk path");
  if (state.risk.uncertainMutation) reasons.push("uncertain shell mutation");
  if (state.risk.delegatedWriter) reasons.push("delegated writer");
  if (RISK_RATIONALE.test(analysis.taskText)) reasons.push("stated risk rationale");
  return reasons;
}

export function evaluateSubagentCall(state, input) {
  const analysis = analyzeSubagentInput(input);
  if (analysis.management) return { disposition: "allow", ...analysis };

  if (state.prompt.attemptedFingerprints.has(analysis.fingerprint)) {
    return {
      disposition: "block",
      reason: "Duplicate subagent launch blocked. Reuse the existing result or materially revise the brief.",
      ...analysis,
    };
  }

  if (analysis.hasVerify && !state.prompt.explicitVerify) {
    if (state.mutationRevision <= state.verifiedRevision) {
      return {
        disposition: "block",
        reason: "Verification blocked: there are no unverified mutations. Do not re-run a verifier after PASS without new changes.",
        ...analysis,
      };
    }
    const reasons = riskReasons(state, analysis);
    if (reasons.length === 0) {
      return {
        disposition: "block",
        reason: "Verification blocked: the pending mutation is low-risk. Validate it directly unless the user requests independent verification.",
        ...analysis,
      };
    }
    analysis.riskReasons = reasons;
  }

  const proposedChildren = state.prompt.attemptedChildren + analysis.childCount;
  if (proposedChildren > 2 && !state.prompt.explicitDelegation) {
    return {
      disposition: "confirm",
      reason: `This request would launch ${proposedChildren} children. Direct-first policy allows two without user approval.`,
      proposedChildren,
      ...analysis,
    };
  }

  return { disposition: "allow", proposedChildren, ...analysis };
}

export function reserveSubagentCall(state, decision) {
  if (decision.management) return;
  state.prompt.attemptedChildren += decision.childCount;
  if (decision.fingerprint) state.prompt.attemptedFingerprints.add(decision.fingerprint);
}

export function releaseFailedSubagentCall(state, decision) {
  if (decision?.fingerprint) state.prompt.attemptedFingerprints.delete(decision.fingerprint);
}

function addMutation(state, evidence) {
  state.mutationRevision += 1;
  if (evidence.path) state.risk.files.add(evidence.path);
  state.risk.editChars += evidence.editChars ?? 0;
  state.risk.highRisk ||= evidence.highRisk === true || (evidence.path ? HIGH_RISK_PATH.test(evidence.path) : false);
  state.risk.uncertainMutation ||= evidence.uncertainMutation === true;
  state.risk.delegatedWriter ||= evidence.delegatedWriter === true;
}

function editVolume(input) {
  if (!Array.isArray(input?.edits)) return 0;
  return input.edits.reduce((total, edit) => {
    const oldText = typeof edit?.oldText === "string" ? edit.oldText.length : 0;
    const newText = typeof edit?.newText === "string" ? edit.newText.length : 0;
    return total + oldText + newText;
  }, 0);
}

export function recordSuccessfulTool(state, toolName, input, decision) {
  const normalized = String(toolName).toLowerCase().split(/[:/.]/).at(-1);
  if (normalized === "subagent" && decision && !decision.management) {
    state.prompt.audit.delegationUsed = true;
  } else if (DIRECT_WORK_TOOLS.has(normalized)) {
    state.prompt.audit.directExecutionUsed = true;
  }

  if (normalized === "edit") {
    addMutation(state, { path: input?.path, editChars: editVolume(input) });
    return true;
  }
  if (normalized === "write") {
    addMutation(state, {
      path: input?.path,
      editChars: typeof input?.content === "string" ? input.content.length : 0,
    });
    return true;
  }
  if (normalized === "bash" && MUTATING_BASH.test(String(input?.command ?? ""))) {
    addMutation(state, {
      editChars: 0,
      highRisk: HIGH_RISK_PATH.test(String(input?.command ?? "")),
      uncertainMutation: true,
    });
    return true;
  }
  if (normalized !== "subagent" || !decision || decision.management) return false;

  if (decision.hasWriter) {
    addMutation(state, { delegatedWriter: true, uncertainMutation: true });
  }
  if (decision.hasVerify) {
    state.verifiedRevision = state.mutationRevision;
    state.risk = emptyRisk();
  }
  return decision.hasWriter || decision.hasVerify;
}
