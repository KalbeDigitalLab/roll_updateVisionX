const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");
const consoleUtils = require("../utils/consoleUtils");

/**
 * Applies the Supabase chart hardening (strategy: Recreate for db, plus
 * startup/readiness/liveness probes for 12 components) to the chart at
 * SUPABASE_CHART_DIR. Unlike increaseSupabaseLimit.js (a pure values.yaml
 * patch, no downtime), this triggers a brief db pod restart via Recreate,
 * so it requires an explicit operator confirmation and fails loudly on any
 * problem rather than swallowing errors.
 *
 * The chart at SUPABASE_CHART_DIR is hand-edited directly on each site's
 * VM (there's no shared internal fork to pull from — its git remote is
 * just the public supabase-community/supabase-kubernetes repo). This
 * usecase does no git operations at all — it applies whatever's on disk,
 * the same as the manual `helm upgrade` process already validated on the
 * staging VM did.
 *
 * Pre-flight checks specifically guard against the incident this hardening
 * itself must not reproduce: Realtime's readinessProbe hitting `httpGet
 * path: /` (the endpoint that caused the original analytics log-bloat
 * incident) instead of the tcpSocket probe its livenessProbe already uses.
 */

// Finds the Deployment/StatefulSet doc for a component by its metadata.name,
// not just a text substring — helm template also renders a Service and
// ConfigMap per component, and other components' Deployments commonly
// reference e.g. "visionx-supabase-db" in env vars (DB_HOST). A plain
// substring match can silently resolve to the wrong resource (one with no
// strategy/replicas/probes at all), making every check below throw a false
// failure. Restrict the name match to the doc's header (first ~20 lines,
// where kind/metadata.name live) so a name mentioned deep in someone else's
// env vars can't match.
function findWorkloadDoc(rendered, resourceName) {
  const docs = rendered.split(/^---$/m);
  return (
    docs.find((doc) => {
      const header = doc.split("\n").slice(0, 20).join("\n");
      const isWorkload = /^kind:\s*(Deployment|StatefulSet)\s*$/m.test(header);
      const nameMatches = new RegExp(`^\\s*name:\\s*${resourceName}\\s*$`, "m").test(header);
      return isWorkload && nameMatches;
    }) || null
  );
}

function hasProbe(doc, probeName) {
  return new RegExp(`^\\s*${probeName}:\\s*$`, "m").test(doc);
}

// Minimum required probe coverage per component, per the validated
// breakdown: startupProbe is db-only; livenessProbe covers 7 components;
// readinessProbe covers 11 (all but db). This is a MINIMUM, not an exact
// match — a component having more probes than listed here is fine and
// never flagged; only genuinely missing required probes are a problem
// (learned the hard way: the real chart already exceeds this table
// almost everywhere, which is good, not an error).
const PROBE_EXPECTATIONS = {
  db: { startupProbe: true, livenessProbe: true, readinessProbe: false },
  studio: { startupProbe: false, livenessProbe: true, readinessProbe: true },
  auth: { startupProbe: false, livenessProbe: false, readinessProbe: true },
  rest: { startupProbe: false, livenessProbe: false, readinessProbe: true },
  realtime: { startupProbe: false, livenessProbe: true, readinessProbe: true },
  meta: { startupProbe: false, livenessProbe: false, readinessProbe: true },
  storage: { startupProbe: false, livenessProbe: true, readinessProbe: true },
  imgproxy: { startupProbe: false, livenessProbe: true, readinessProbe: true },
  kong: { startupProbe: false, livenessProbe: false, readinessProbe: true },
  analytics: { startupProbe: false, livenessProbe: true, readinessProbe: true },
  vector: { startupProbe: false, livenessProbe: true, readinessProbe: true },
  functions: { startupProbe: false, livenessProbe: false, readinessProbe: true },
};

// db must never rolling-update — that's the actual root cause fix (see
// supabase-db-wal-corruption-incident doc: overlapping old/new db pods
// during a RollingUpdate both wrote WAL to the same hostPath, corrupting
// the checkpoint record). Hardcoded directly rather than gated behind a
// values key, so it can't be silently missed by a values.yaml that wasn't
// fully updated on a given site (exactly what happened here — the manual
// hardening pass added probes but missed this).
function ensureDbRecreateStrategy(chartDir) {
  const deploymentPath = path.join(chartDir, "templates", "db", "deployment.yaml");
  if (!fs.existsSync(deploymentPath)) {
    consoleUtils.warn(`${deploymentPath} not found — skipping strategy: Recreate injection.`);
    return;
  }

  const content = fs.readFileSync(deploymentPath, "utf8");
  if (/strategy:\s*\n\s*type:\s*Recreate/.test(content)) {
    consoleUtils.info("db deployment already has strategy: Recreate.");
    return;
  }

  const lines = content.split(/\r?\n/);
  const selectorIndex = lines.findIndex((line) => /^ {2}selector:\s*$/.test(line));
  if (selectorIndex === -1) {
    throw new Error(
      `Could not find "  selector:" in ${deploymentPath} to anchor the strategy: Recreate injection — add it manually as a sibling of replicas:/selector:/template: under the Deployment's spec:.`,
    );
  }

  lines.splice(selectorIndex, 0, "  strategy:", "    type: Recreate");
  fs.writeFileSync(deploymentPath, lines.join("\n"), "utf8");
  consoleUtils.success(`Injected strategy: Recreate into ${deploymentPath}`);
}

// db.autoscaling.enabled defaults to `true` in the chart's OWN values.yaml
// (confirmed on the real VM: db.autoscaling: {enabled: true, minReplicas: 1,
// maxReplicas: 100, ...} — nothing site-specific overrides it). The db
// template only renders a `replicas:` line at all when
// `{{- if not .Values.db.autoscaling.enabled }}` is true, so with the
// chart's own default this field is silently OMITTED from the rendered
// manifest rather than rendering something obviously wrong — which is
// exactly what tripped the "db deployment does not have replicas: 1"
// pre-flight check. An HPA-eligible singleton Postgres backed by hostPath
// storage is the same class of problem strategy: Recreate exists to
// prevent (two Postgres processes writing to the same hostPath at once).
// Force both values explicitly into values.example.yaml (the file actually
// passed via -f to every helm command), not values.yaml, matching every
// other auto-injector in this file.
function ensureDbSingleReplica(chartDir) {
  const valuesPath = path.join(chartDir, "values.example.yaml");
  if (!fs.existsSync(valuesPath)) {
    consoleUtils.warn(`${valuesPath} not found — skipping db single-replica override.`);
    return false;
  }

  let lines = fs.readFileSync(valuesPath, "utf8").split(/\r?\n/);
  let changed = false;

  function forceScalarUnderDb(key, desiredLine) {
    const section = findComponentSection(lines, "db");
    if (!section) return;
    const idx = lines
      .slice(section.startIndex, section.endIndex)
      .findIndex((line) => new RegExp(`^ {2}${key}:\\s*\\S`).test(line));
    if (idx === -1) {
      lines.splice(section.startIndex + 1, 0, desiredLine);
      changed = true;
      consoleUtils.success(`Injected db.${key} into ${valuesPath}`);
      return;
    }
    const absoluteIdx = section.startIndex + idx;
    if (lines[absoluteIdx].trim() !== desiredLine.trim()) {
      lines[absoluteIdx] = desiredLine;
      changed = true;
      consoleUtils.success(`Set db.${key} in ${valuesPath}`);
    }
  }

  forceScalarUnderDb("replicaCount", "  replicaCount: 1");

  const section = findComponentSection(lines, "db");
  if (section) {
    const autoscalingIdx = lines
      .slice(section.startIndex, section.endIndex)
      .findIndex((line) => /^ {2}autoscaling:\s*$/.test(line));

    if (autoscalingIdx === -1) {
      lines.splice(section.startIndex + 1, 0, "  autoscaling:", "    enabled: false");
      changed = true;
      consoleUtils.success(`Injected db.autoscaling.enabled: false into ${valuesPath}`);
    } else {
      const absoluteStart = section.startIndex + autoscalingIdx;
      const blockEnd = findProbeBlockEnd(lines, absoluteStart, section.endIndex);
      const enabledOffset = lines
        .slice(absoluteStart + 1, blockEnd)
        .findIndex((line) => /^\s*enabled:\s*\S/.test(line));

      if (enabledOffset === -1) {
        lines.splice(absoluteStart + 1, 0, "    enabled: false");
        changed = true;
        consoleUtils.success(`Injected db.autoscaling.enabled: false into ${valuesPath}`);
      } else {
        const absoluteEnabledIdx = absoluteStart + 1 + enabledOffset;
        if (!/^\s*enabled:\s*false\s*$/.test(lines[absoluteEnabledIdx])) {
          const indent = lines[absoluteEnabledIdx].match(/^(\s*)/)[1];
          lines[absoluteEnabledIdx] = `${indent}enabled: false`;
          changed = true;
          consoleUtils.success(`Set db.autoscaling.enabled to false in ${valuesPath}`);
        }
      }
    }
  }

  if (changed) {
    fs.writeFileSync(valuesPath, lines.join("\n"), "utf8");
  }
  return changed;
}

// db's Deployment template already wires livenessProbe/readinessProbe via
// `{{- with .Values.db.<probe> }} ... {{- end }}` blocks (confirmed on the
// real VM: templates/db/deployment.yaml:118-125), but has NO such block for
// startupProbe at all. Auto-injecting startupProbe values into
// values.example.yaml (ensureProbeCoverage, below) is a no-op no matter
// what's in there — the template simply never emits the key — so this is a
// genuine template edit, not a values patch, mirroring exactly the
// reasoning ensureDbRecreateStrategy already uses for editing this same
// file. Anchored on the existing livenessProbe `{{- with }}` line so the
// new block lands with identical indentation/style, right before it.
function ensureDbStartupProbeTemplateBlock(chartDir) {
  const deploymentPath = path.join(chartDir, "templates", "db", "deployment.yaml");
  if (!fs.existsSync(deploymentPath)) {
    consoleUtils.warn(`${deploymentPath} not found — skipping db startupProbe template block injection.`);
    return;
  }

  const content = fs.readFileSync(deploymentPath, "utf8");
  if (content.includes(".Values.db.startupProbe")) {
    consoleUtils.info("db deployment template already wires startupProbe from values.");
    return;
  }

  const lines = content.split(/\r?\n/);
  const anchorIndex = lines.findIndex((line) =>
    /^\s*\{\{-\s*with\s+\.Values\.db\.livenessProbe\s*\}\}\s*$/.test(line),
  );
  if (anchorIndex === -1) {
    throw new Error(
      `Could not find "{{- with .Values.db.livenessProbe }}" in ${deploymentPath} to anchor the startupProbe template block injection — add it manually, matching the livenessProbe/readinessProbe block style already in that file.`,
    );
  }

  const indent = lines[anchorIndex].match(/^(\s*)/)[1];
  const block = [
    `${indent}{{- with .Values.db.startupProbe }}`,
    `${indent}startupProbe:`,
    `${indent}  {{- toYaml . | nindent 12 }}`,
    `${indent}{{- end }}`,
  ];

  lines.splice(anchorIndex, 0, ...block);
  fs.writeFileSync(deploymentPath, lines.join("\n"), "utf8");
  consoleUtils.success(`Injected {{- with .Values.db.startupProbe }} template block into ${deploymentPath}`);
}

// Realtime's readinessProbe/livenessProbe templates are already correctly
// wired via `{{- with .Values.realtime.readinessProbe }}` (confirmed on
// the real VM: templates/realtime/deployment.yaml:127-130), so the fix
// belongs in values.example.yaml — the file actually passed via -f to
// every helm command in this usecase — not the template itself.
// readinessProbe: httpGet path:/ port:4000 next to livenessProbe:
// tcpSocket port:4000 is a unique fingerprint: no other component in
// values.example.yaml pairs those two probe shapes on port 4000.
function ensureRealtimeReadinessProbe(chartDir) {
  const valuesPath = path.join(chartDir, "values.example.yaml");
  if (!fs.existsSync(valuesPath)) {
    consoleUtils.warn(`${valuesPath} not found — skipping Realtime readinessProbe fix.`);
    return;
  }

  const content = fs.readFileSync(valuesPath, "utf8");
  const lines = content.split(/\r?\n/);

  const readinessIndex = lines.findIndex((line, i) => {
    if (!/^ {2}readinessProbe:\s*$/.test(line)) return false;
    if (lines[i + 1] !== "    httpGet:") return false;
    if (lines[i + 2] !== "      path: /") return false;
    if (lines[i + 3] !== "      port: 4000") return false;
    const window = lines.slice(i, i + 15).join("\n");
    return /livenessProbe:\s*\n\s*tcpSocket:\s*\n\s*port:\s*4000/.test(window);
  });

  if (readinessIndex === -1) {
    consoleUtils.info(
      "Realtime readinessProbe: httpGet path:/ port:4000 pattern not found in values.example.yaml (already fixed, or in an unexpected shape — the pre-flight check below will catch it either way).",
    );
    return;
  }

  lines.splice(readinessIndex + 1, 3, "    tcpSocket:", "      port: 4000");
  fs.writeFileSync(valuesPath, lines.join("\n"), "utf8");
  consoleUtils.success(`Fixed Realtime readinessProbe to use tcpSocket in ${valuesPath}`);
}

function detectContainerPort(doc) {
  const match = doc.match(/containerPort:\s*(\d+)/);
  return match ? match[1] : null;
}

// Finds the rendered Service doc for a component, same name/header-match
// discipline as findWorkloadDoc.
function findServiceDoc(rendered, resourceName) {
  const docs = rendered.split(/^---$/m);
  return (
    docs.find((doc) => {
      const header = doc.split("\n").slice(0, 20).join("\n");
      const isService = /^kind:\s*Service\s*$/m.test(header);
      const nameMatches = new RegExp(`^\\s*name:\\s*${resourceName}\\s*$`, "m").test(header);
      return isService && nameMatches;
    }) || null
  );
}

// Fallback for components whose container spec never declares a
// containerPort at all — confirmed real case: `functions` (supabase/
// edge-runtime), whose Deployment template has no `ports:` block, only its
// Service does (`functions.service.port: 9000` in the chart's own
// values.yaml). Kubernetes can only route Service traffic to a port the
// pod is actually listening on, so the Service's declared port is a safe
// stand-in for the probe port whenever the container spec itself is silent
// about it.
function detectServicePort(rendered, component) {
  const doc = findServiceDoc(rendered, `visionx-supabase-${component}`);
  if (!doc) return null;
  const match = doc.match(/^\s*port:\s*(\d+)\s*$/m);
  return match ? match[1] : null;
}

// Finds a top-level `component:` key's line range in values.example.yaml —
// from the key itself to the line before the next top-level (0-indent) key,
// or EOF. Flush-left `#comment` lines (found for real in this site's hand
// edited file — old GOTRUE_* URLs disabled by commenting from column 0
// under `auth.environment`) don't count as the next key, or the section
// gets cut off dozens of lines early, well before probes are even reached.
function findComponentSection(lines, component) {
  const startIndex = lines.findIndex((line) => new RegExp(`^${component}:\\s*$`).test(line));
  if (startIndex === -1) return null;

  let endIndex = lines.length;
  for (let i = startIndex + 1; i < lines.length; i++) {
    if (/^\S/.test(lines[i]) && !/^#/.test(lines[i])) {
      endIndex = i;
      break;
    }
  }
  return { startIndex, endIndex };
}

function findProbeBlockEnd(lines, blockStart, sectionEnd) {
  for (let i = blockStart + 1; i < sectionEnd; i++) {
    if (/^ {2}\S/.test(lines[i])) return i;
  }
  return sectionEnd;
}

// Prefers inserting right after an existing sibling probe (keeps probes
// grouped together, matching the file's existing style), falling back to
// right before `resources:` (present in nearly every component section
// observed on the real VM), else the end of the section.
function findProbeInsertionPoint(lines, sectionStart, sectionEnd) {
  for (const probeName of ["readinessProbe", "livenessProbe", "startupProbe"]) {
    const blockStart = lines
      .slice(sectionStart, sectionEnd)
      .findIndex((line) => new RegExp(`^ {2}${probeName}:\\s*$`).test(line));
    if (blockStart !== -1) {
      return findProbeBlockEnd(lines, sectionStart + blockStart, sectionEnd);
    }
  }
  for (let i = sectionStart; i < sectionEnd; i++) {
    if (/^ {2}resources:\s*$/.test(lines[i])) return i;
  }
  return sectionEnd;
}

// tcpSocket-only by design — never httpGet — so an auto-injected probe can
// never reproduce the log-bloat incident regardless of which component it
// lands on (matches the "shallow fallback" reasoning already used for
// Realtime and db's hardening).
function buildProbeBlock(probeName, port) {
  const periodSeconds = probeName === "startupProbe" ? 5 : 60;
  const failureThreshold = probeName === "startupProbe" ? 60 : 3;
  return [
    `  ${probeName}:`,
    `    tcpSocket:`,
    `      port: ${port}`,
    `    periodSeconds: ${periodSeconds}`,
    `    timeoutSeconds: 3`,
    `    failureThreshold: ${failureThreshold}`,
  ];
}

// Steady-state liveness/readiness checks shipped at periodSeconds: 5-10
// (see PROBE_EXPECTATIONS), which turned out too frequent/noisy in
// practice. Normalizes both to periodSeconds: 60 across all 12 components.
// startupProbe is deliberately left untouched — it only runs once during
// boot, and its faster cadence is what lets a slow-starting component
// (e.g. db, see ensureDbStartupProbeWindow below) actually reach ready
// within its failureThreshold instead of wasting most of that window
// between checks.
function ensureSteadyStateProbePeriod(chartDir) {
  const valuesPath = path.join(chartDir, "values.example.yaml");
  if (!fs.existsSync(valuesPath)) {
    consoleUtils.warn(`${valuesPath} not found — skipping probe period normalization.`);
    return false;
  }

  const lines = fs.readFileSync(valuesPath, "utf8").split(/\r?\n/);
  let changed = false;

  for (const component of Object.keys(PROBE_EXPECTATIONS)) {
    const section = findComponentSection(lines, component);
    if (!section) continue;

    for (const probeName of ["readinessProbe", "livenessProbe"]) {
      const blockStart = lines
        .slice(section.startIndex, section.endIndex)
        .findIndex((line) => new RegExp(`^ {2}${probeName}:\\s*$`).test(line));
      if (blockStart === -1) continue;

      const absoluteStart = section.startIndex + blockStart;
      const blockEnd = findProbeBlockEnd(lines, absoluteStart, section.endIndex);

      for (let i = absoluteStart + 1; i < blockEnd; i++) {
        const match = lines[i].match(/^(\s*)periodSeconds:\s*(\d+)\s*$/);
        if (match && match[2] !== "60") {
          lines[i] = `${match[1]}periodSeconds: 60`;
          changed = true;
          consoleUtils.success(`Set ${component}.${probeName}.periodSeconds to 60 in values.example.yaml`);
        }
      }
    }
  }

  if (changed) {
    fs.writeFileSync(valuesPath, lines.join("\n"), "utf8");
  }
  return changed;
}

// db's startupProbe window (failureThreshold * periodSeconds, plus
// initialDelaySeconds) shipped at ~10 minutes, too tight for a slow
// crash-recovery boot. Doubles failureThreshold to 120, giving ~20
// minutes — matched to the `helm upgrade --timeout 20m` already used
// below, since a longer startup window than the upgrade itself will wait
// for wouldn't help. periodSeconds stays at 10s: the check frequency
// during boot was already fine, it's the ceiling that was short.
const DB_STARTUP_FAILURE_THRESHOLD = 120;

function ensureDbStartupProbeWindow(chartDir) {
  const valuesPath = path.join(chartDir, "values.example.yaml");
  if (!fs.existsSync(valuesPath)) {
    consoleUtils.warn(`${valuesPath} not found — skipping db startupProbe window extension.`);
    return false;
  }

  const lines = fs.readFileSync(valuesPath, "utf8").split(/\r?\n/);
  const section = findComponentSection(lines, "db");
  if (!section) {
    consoleUtils.warn(`Could not find "db:" section in ${valuesPath} — skipping db startupProbe window extension.`);
    return false;
  }

  const blockStart = lines
    .slice(section.startIndex, section.endIndex)
    .findIndex((line) => /^ {2}startupProbe:\s*$/.test(line));
  if (blockStart === -1) {
    consoleUtils.warn(`db has no startupProbe block in ${valuesPath} — skipping window extension.`);
    return false;
  }

  const absoluteStart = section.startIndex + blockStart;
  const blockEnd = findProbeBlockEnd(lines, absoluteStart, section.endIndex);

  let changed = false;
  for (let i = absoluteStart + 1; i < blockEnd; i++) {
    const match = lines[i].match(/^(\s*)failureThreshold:\s*(\d+)\s*$/);
    if (match && Number(match[2]) < DB_STARTUP_FAILURE_THRESHOLD) {
      lines[i] = `${match[1]}failureThreshold: ${DB_STARTUP_FAILURE_THRESHOLD}`;
      changed = true;
      consoleUtils.success(`Set db.startupProbe.failureThreshold to ${DB_STARTUP_FAILURE_THRESHOLD} (~20min window) in values.example.yaml`);
    }
  }

  if (changed) {
    fs.writeFileSync(valuesPath, lines.join("\n"), "utf8");
  }
  return changed;
}

// Self-healing pre-pass: on any site that already hit runs of this tool
// from before ensureProbeCoverage's duplicate-injection guard existed,
// values.example.yaml can have TWO `<probeName>:` keys under the same
// component (confirmed real case: db.startupProbe, one stale
// failureThreshold:60 block, one correct failureThreshold:120 block —
// ensureProbeCoverage kept re-injecting because the rendered chart never
// showed the probe, since the template itself lacked the capability
// block). Field operators running this tool have no way to hand-fix
// invalid duplicate YAML keys, so this runs first and repairs whatever's
// already on disk automatically. Keeps the LAST occurrence of each
// duplicate and drops the earlier one(s) — that's already what Helm's own
// YAML-to-map unmarshaling does with duplicate keys today, so this only
// makes that implicit behavior into valid, unambiguous YAML; it doesn't
// change what actually gets applied.
function dedupeDuplicateProbeBlocks(chartDir) {
  const valuesPath = path.join(chartDir, "values.example.yaml");
  if (!fs.existsSync(valuesPath)) return false;

  let lines = fs.readFileSync(valuesPath, "utf8").split(/\r?\n/);
  let changed = false;

  for (const component of Object.keys(PROBE_EXPECTATIONS)) {
    for (const probeName of ["startupProbe", "livenessProbe", "readinessProbe"]) {
      for (;;) {
        const section = findComponentSection(lines, component);
        if (!section) break;

        const indices = [];
        for (let i = section.startIndex + 1; i < section.endIndex; i++) {
          if (new RegExp(`^ {2}${probeName}:\\s*$`).test(lines[i])) indices.push(i);
        }
        if (indices.length <= 1) break;

        const removeStart = indices[0];
        const removeEnd = findProbeBlockEnd(lines, removeStart, section.endIndex);
        lines.splice(removeStart, removeEnd - removeStart);
        changed = true;
        consoleUtils.warn(
          `Removed a duplicate ${component}.${probeName} block from values.example.yaml left behind by an earlier run (kept the later one).`,
        );
      }
    }
  }

  if (changed) {
    fs.writeFileSync(valuesPath, lines.join("\n"), "utf8");
  }
  return changed;
}

// Auto-injects any required-but-missing probe (per PROBE_EXPECTATIONS)
// into values.example.yaml, assuming the template already has the
// `{{- with .Values.<component>.<probeType> }}` capability — confirmed
// present for db and realtime using an identical pattern, treated as the
// working assumption for the rest since this is one mechanical hardening
// pass by one author. Components/probes where that assumption doesn't
// hold (template lacks the capability) get caught by checkProbeCoverage
// afterward, which re-renders and reports exactly what's still missing
// rather than silently doing nothing.
function ensureProbeCoverage(chartDir, rendered) {
  const valuesPath = path.join(chartDir, "values.example.yaml");
  if (!fs.existsSync(valuesPath)) {
    consoleUtils.warn(`${valuesPath} not found — skipping probe coverage injection.`);
    return false;
  }

  const lines = fs.readFileSync(valuesPath, "utf8").split(/\r?\n/);
  let changed = false;
  const skipped = [];

  for (const [component, expected] of Object.entries(PROBE_EXPECTATIONS)) {
    const doc = findWorkloadDoc(rendered, `visionx-supabase-${component}`);
    if (!doc) continue;

    for (const probeName of ["startupProbe", "livenessProbe", "readinessProbe"]) {
      if (!expected[probeName] || hasProbe(doc, probeName)) continue;

      const section = findComponentSection(lines, component);
      if (!section) {
        skipped.push(`${component}.${probeName}: could not find "${component}:" section in values.example.yaml`);
        continue;
      }

      // The rendered doc says this probe is missing, but if values.example.yaml
      // ALREADY has a `${probeName}:` block for this component, injecting
      // another one would create a duplicate YAML key rather than fixing
      // anything — this happens when the chart template lacks the
      // `{{- with .Values.<component>.<probeType> }}` capability block, so
      // no values injection could ever make it render (confirmed real case:
      // db.startupProbe piled up two duplicate blocks across repeated runs
      // before the template itself was fixed). Surface it as a template gap
      // instead of silently duplicating.
      const alreadyInValues = lines
        .slice(section.startIndex, section.endIndex)
        .some((line) => new RegExp(`^ {2}${probeName}:\\s*$`).test(line));
      if (alreadyInValues) {
        skipped.push(
          `${component}.${probeName}: already defined in values.example.yaml but not rendered — the chart template likely lacks the {{- with .Values.${component}.${probeName} }} capability block and needs a manual template edit, not another values injection`,
        );
        continue;
      }

      const port = detectContainerPort(doc) || detectServicePort(rendered, component);
      if (!port) {
        skipped.push(`${component}.${probeName}: could not detect containerPort or Service port in rendered chart`);
        continue;
      }

      const insertAt = findProbeInsertionPoint(lines, section.startIndex + 1, section.endIndex);
      lines.splice(insertAt, 0, ...buildProbeBlock(probeName, port));
      changed = true;
      consoleUtils.success(`Injected ${probeName} (tcpSocket:${port}) for ${component} into values.example.yaml`);
    }
  }

  if (changed) {
    fs.writeFileSync(valuesPath, lines.join("\n"), "utf8");
  }
  if (skipped.length > 0) {
    consoleUtils.warn(`Could not auto-inject some probes — add manually:\n  - ${skipped.join("\n  - ")}`);
  }
  return changed;
}

const PROBE_HANDLER_KEYS = ["httpGet", "tcpSocket", "exec", "grpc"];

// Returns the list of handler keys (httpGet/tcpSocket/exec/grpc) present
// under a `<probeName>:` block in a rendered manifest doc, bounded by
// indentation — the block ends at the first following non-blank line
// indented at or below the probe key's own indent. Shared by the static
// collision check and the live-drift check below.
function extractProbeHandlers(doc, probeName) {
  const lines = doc.split("\n");
  const startIndex = lines.findIndex((line) => new RegExp(`^(\\s*)${probeName}:\\s*$`).test(line));
  if (startIndex === -1) return null;

  const indent = lines[startIndex].match(/^(\s*)/)[1].length;
  const handlers = [];
  for (let i = startIndex + 1; i < lines.length; i++) {
    const line = lines[i];
    if (line.trim() === "") continue;
    const curIndent = line.match(/^(\s*)/)[1].length;
    if (curIndent <= indent) break;
    const match = line.match(/^\s*(httpGet|tcpSocket|exec|grpc):\s*$/);
    if (match) handlers.push(match[1]);
  }
  return handlers;
}

// Static defense-in-depth: Kubernetes rejects any probe with more than one
// handler type. The current chart has none of these (confirmed by scanning
// every rendered probe block), but nothing previously checked for it, so a
// future manual chart edit could reintroduce it silently.
function checkProbeHandlerCollisions(rendered) {
  const collisions = [];

  for (const component of Object.keys(PROBE_EXPECTATIONS)) {
    const doc = findWorkloadDoc(rendered, `visionx-supabase-${component}`);
    if (!doc) continue;

    for (const probeName of ["startupProbe", "livenessProbe", "readinessProbe"]) {
      const handlers = extractProbeHandlers(doc, probeName);
      if (handlers && handlers.length > 1) {
        collisions.push(`${component}.${probeName}: multiple handler types (${handlers.join(", ")}) — Kubernetes allows only one`);
      }
    }
  }

  if (collisions.length > 0) {
    throw new Error(
      `Pre-flight check failed: rendered chart has probe blocks with more than one handler type:\n  - ${collisions.join("\n  - ")}`,
    );
  }
}

// Reads the live workload's first container (Deployment for most
// components, StatefulSet for db) straight from the cluster. Returns null
// if neither kind exists yet (fresh install — nothing to drift from).
function getLiveContainer(component) {
  const name = `visionx-supabase-${component}`;
  for (const kind of ["deployment", "statefulset"]) {
    try {
      const json = execSync(`kubectl get ${kind} ${name} -n supabase -o json`, {
        stdio: ["ignore", "pipe", "pipe"],
      }).toString();
      return JSON.parse(json).spec.template.spec.containers[0];
    } catch (err) {
      continue;
    }
  }
  return null;
}

function handlerTypeOf(probe) {
  if (!probe) return null;
  return PROBE_HANDLER_KEYS.find((key) => probe[key] !== undefined) || null;
}

// Detects the actual failure mode behind the 2026-07-22 realtime incident:
// helm computes its upgrade patch by diffing its OWN release history, not
// the live object, so if a probe's handler type was changed on the live
// resource out-of-band (e.g. a manual `kubectl edit` during an earlier
// incident) helm's patch can add the new handler without clearing the old
// one — the API then rejects the merged object with "may not specify more
// than 1 handler type". `kubectl apply --dry-run=server` doesn't catch this
// because Server-Side Apply merges correctly; only the real `helm upgrade`
// is exposed to it. Block-and-report only — this never mutates live cluster
// state itself, matching every other check in this file.
function checkLiveProbeDrift(rendered) {
  const drifted = [];

  for (const component of Object.keys(PROBE_EXPECTATIONS)) {
    const doc = findWorkloadDoc(rendered, `visionx-supabase-${component}`);
    if (!doc) continue;

    const liveContainer = getLiveContainer(component);
    if (!liveContainer) continue;

    for (const probeName of ["startupProbe", "livenessProbe", "readinessProbe"]) {
      const desiredHandler = (extractProbeHandlers(doc, probeName) || [])[0] || null;
      const liveHandler = handlerTypeOf(liveContainer[probeName]);
      if (liveHandler && desiredHandler && liveHandler !== desiredHandler) {
        drifted.push(
          `${component}.${probeName}: live cluster has "${liveHandler}" but the chart now wants "${desiredHandler}" — helm's patch may add ${desiredHandler} without clearing ${liveHandler}, causing "Forbidden: may not specify more than 1 handler type". Reconcile first by removing the whole probe (never just the handler key — that leaves 0 handlers, which Kubernetes also rejects) and let helm add it back clean: kubectl patch deployment visionx-supabase-${component} -n supabase --type=json -p='[{"op":"remove","path":"/spec/template/spec/containers/0/${probeName}"}]'`,
        );
      }
    }
  }

  if (drifted.length > 0) {
    throw new Error(
      `Pre-flight check failed: live cluster probes have drifted from what helm tracks — helm upgrade would try to patch this and fail:\n  - ${drifted.join("\n  - ")}`,
    );
  }
}

function checkProbeCoverage(rendered) {
  const missing = [];

  for (const [component, expected] of Object.entries(PROBE_EXPECTATIONS)) {
    const doc = findWorkloadDoc(rendered, `visionx-supabase-${component}`);
    if (!doc) {
      missing.push(`${component}: not found in rendered chart`);
      continue;
    }

    for (const probeName of ["startupProbe", "livenessProbe", "readinessProbe"]) {
      if (expected[probeName] && !hasProbe(doc, probeName)) {
        missing.push(`${component}: missing ${probeName}`);
      }
    }
  }

  if (missing.length > 0) {
    throw new Error(
      `Pre-flight check failed: required probes still missing after auto-injection — the template likely lacks the {{- with .Values.<component>.<probeType> }} capability block and needs a manual template edit, not just a values change:\n  - ${missing.join("\n  - ")}`,
    );
  }
}

async function hardenSupabaseChart(askHelper) {
  const chartDir = process.env.SUPABASE_CHART_DIR;
  if (!chartDir) {
    throw new Error("Missing required environment variable: SUPABASE_CHART_DIR");
  }

  consoleUtils.info(`Using Supabase chart at: ${chartDir}`);

  dedupeDuplicateProbeBlocks(chartDir);
  ensureDbRecreateStrategy(chartDir);
  ensureDbSingleReplica(chartDir);
  ensureDbStartupProbeTemplateBlock(chartDir);
  ensureRealtimeReadinessProbe(chartDir);
  ensureSteadyStateProbePeriod(chartDir);
  ensureDbStartupProbeWindow(chartDir);

  consoleUtils.info("Running helm lint...");
  execSync("helm lint .", { cwd: chartDir, stdio: "inherit" });

  consoleUtils.info("Rendering chart with helm template...");
  let rendered = execSync(
    "helm template visionx . -f values.example.yaml -n supabase",
    { cwd: chartDir },
  ).toString();

  const injected = ensureProbeCoverage(chartDir, rendered);
  if (injected) {
    consoleUtils.info("Re-rendering chart after probe injection...");
    rendered = execSync(
      "helm template visionx . -f values.example.yaml -n supabase",
      { cwd: chartDir },
    ).toString();
  }

  const dbDoc = findWorkloadDoc(rendered, "visionx-supabase-db");
  if (!dbDoc) {
    throw new Error("Pre-flight check failed: could not find visionx-supabase-db in rendered chart.");
  }
  if (!/strategy:\s*\n?\s*type:\s*Recreate/.test(dbDoc)) {
    throw new Error("Pre-flight check failed: db deployment is not using strategy: Recreate.");
  }
  if (!/replicas:\s*1\b/.test(dbDoc)) {
    throw new Error("Pre-flight check failed: db deployment does not have replicas: 1.");
  }

  const realtimeDoc = findWorkloadDoc(rendered, "visionx-supabase-realtime");
  if (!realtimeDoc) {
    throw new Error("Pre-flight check failed: could not find visionx-supabase-realtime in rendered chart.");
  }
  if (/readinessProbe:[\s\S]*?httpGet:\s*\n\s*path:\s*\/(?!\S)/.test(realtimeDoc)) {
    throw new Error(
      "Pre-flight check failed: Realtime readinessProbe still points at httpGet path: / — this is the exact endpoint that caused the analytics log-bloat incident. Fix the chart repo before retrying.",
    );
  }
  if (!/readinessProbe:[\s\S]*?tcpSocket:\s*\n\s*port:\s*4000/.test(realtimeDoc)) {
    throw new Error("Pre-flight check failed: Realtime readinessProbe is not using tcpSocket on port 4000.");
  }
  if (!/livenessProbe:[\s\S]*?tcpSocket:\s*\n\s*port:\s*4000/.test(realtimeDoc)) {
    throw new Error("Pre-flight check failed: Realtime livenessProbe is not using tcpSocket on port 4000.");
  }

  checkProbeCoverage(rendered);
  checkProbeHandlerCollisions(rendered);
  checkLiveProbeDrift(rendered);

  consoleUtils.success(
    "Pre-flight checks passed (db strategy/replicas, Realtime probes, required probe coverage, no multi-handler probes, no live/chart probe drift across all 12 components — auto-injecting any that were missing).",
  );

  consoleUtils.info("Running kubectl apply --dry-run=server against rendered chart...");
  execSync("kubectl apply --dry-run=server -f -", {
    cwd: chartDir,
    input: rendered,
    stdio: ["pipe", "inherit", "inherit"],
  });

  consoleUtils.warn(
    "This will run `helm upgrade` with strategy: Recreate for the db component, causing a brief db pod restart/downtime.",
  );
  const answer = await askHelper.ask("Proceed with helm upgrade? (y/n) ");
  if (answer.toLowerCase() !== "y") {
    consoleUtils.skipped("Helm upgrade cancelled by operator.");
    return;
  }

  try {
    consoleUtils.info(
      `Running helm upgrade visionx . -f values.example.yaml -n supabase --atomic --wait --timeout 20m (cwd=${chartDir})...`,
    );
    execSync(
      "helm upgrade visionx . -f values.example.yaml -n supabase --atomic --wait --timeout 20m",
      { cwd: chartDir, stdio: "inherit" },
    );
    consoleUtils.success("helm upgrade completed.");
  } catch (err) {
    consoleUtils.error(`helm upgrade failed: ${err.message}`);
    throw err;
  }
}

module.exports = hardenSupabaseChart;
