/**
 * Every ⓘ tooltip's text. Wording follows the server's metrics reference
 * (server/docs/metrics.md, "Dashboard definitions"); keep the two in step.
 */
export interface StatCopy {
  title: string;
  meaning: string;
  computation: string;
  caveat?: string;
}

const PROXY_ONLY =
  "Only Play installs that passed attestation are visible; sideloaded and bring-your-own-key installs never reach the server.";
const SESSION_UNDERCOUNT =
  "Session days undercount daily opens: the 24-hour token is only refreshed near expiry, so an install opened every day can skip days. Weekly and monthly numbers are robust.";
const SMS_DRIVEN =
  "Classify activity follows bank SMS volume, not engagement: background classification counts, messages handled on the phone never do.";
const COUNTERS_SINCE = "Recorded since the capture deploy; earlier days are empty.";
/**
 * The app release that first reports message counts. The release owner
 * replaces this with "app version <versionCode>" (for example
 * "app version 22") when that release is cut.
 */
export const MESSAGE_COUNTS_RELEASE = "the first app release that reports message counts";
const MESSAGES_REPORTED = `Only Play installs on ${MESSAGE_COUNTS_RELEASE} or later report message counts; earlier installs show calls only.`;

export const statCopy = {
  attestedInstalls: {
    title: "Attested installs",
    meaning: "Installs that passed Play Integrity attestation at least once.",
    computation: "Count of install records. A reinstall gets a new install ID, so it counts again.",
    caveat: `${PROXY_ONLY} Play Console has the real install count.`,
  },
  newInstalls: {
    title: "New installs",
    meaning: "Installs first seen in the selected range.",
    computation:
      "Installs whose first attestation falls in the range, compared with the same-length range before it.",
  },
  "dau.any": {
    title: "Daily active installs",
    meaning: "Installs active today: they made a classify call or minted a session.",
    computation: "Distinct installs with a usage row or a session day today (UTC).",
    caveat: SESSION_UNDERCOUNT,
  },
  "wau.any": {
    title: "Weekly active installs",
    meaning: "Installs active at least once in the last 7 days.",
    computation: "Distinct installs with a classify call or a session in the 7 days ending today.",
  },
  "mau.any": {
    title: "Monthly active installs",
    meaning: "Installs active at least once in the last 30 days.",
    computation: "Distinct installs with a classify call or a session in the 30 days ending today.",
  },
  callsToday: {
    title: "Calls today",
    meaning: "Classify calls the server admitted today, against the global daily cap.",
    computation:
      "Sum of today's per-install call counters (UTC). The bar shows the share of the global cap used.",
    caveat: "Lags live traffic by up to 10 seconds.",
  },
  tokensToday: {
    title: "Tokens today",
    meaning: "LLM tokens used by today's successful classify calls.",
    computation: "Sum of today's per-install token counters, as reported by OpenRouter.",
  },
  successRateToday: {
    title: "LLM success today",
    meaning: "Share of today's classify calls that reached the LLM step and succeeded.",
    computation:
      "ok ÷ (ok + upstream 429 + upstream retryable + upstream rejected + internal). Client errors, quota denials and cancellations are left out.",
    caveat: COUNTERS_SINCE,
  },
  callsPerActiveInstallDay: {
    title: "Calls per active install-day",
    meaning: "How many messages an active install sends to the LLM on a typical day.",
    computation: "Calls in the range ÷ install-days with at least one call.",
    caveat: "Mixes SMS volume with how often the on-device model escalates; read it as a trend.",
  },
  "chart.callsPerDay": {
    title: "Calls per day",
    meaning: "Classify calls admitted each day.",
    computation: "Sum of per-install daily call counters.",
  },
  "chart.activeInstallsPerDay": {
    title: "Active installs per day",
    meaning: "Installs that classified or minted a session each day.",
    computation: 'Distinct installs active each day (the "Any" definition).',
    caveat: SESSION_UNDERCOUNT,
  },
  "chart.newInstallsPerDay": {
    title: "New installs per day",
    meaning: "Installs attesting for the first time each day.",
    computation: "Installs grouped by the UTC day of their first attestation.",
  },
  serverInfo: {
    title: "Server",
    meaning: "The limits and models pawletd is running with.",
    computation: "Published by pawletd each time it starts.",
  },
  "col.hash": {
    title: "Install",
    meaning: "The first characters of the install's anonymous ID hash.",
    computation: "SHA-256 of the app's random install ID; the server never sees the ID itself.",
  },
  "col.firstSeen": {
    title: "First seen",
    meaning: "When the install first attested.",
    computation: "Time of its first successful session.",
  },
  "col.lastSeen": {
    title: "Last seen",
    meaning: "When the install last attested.",
    computation: "Time of its most recent successful session (about daily while the app is used).",
  },
  "col.version": {
    title: "Version",
    meaning: "App versionCode from the install's latest attestation.",
    computation: "Read from the Play Integrity verdict on each session.",
    caveat: "Empty until the install attests again after the capture deploy.",
  },
  "col.tier": {
    title: "Device tier",
    meaning:
      "STRONG: hardware-backed integrity and a recent security patch. DEVICE: a genuine Play-certified device.",
    computation:
      "Strongest device verdict in the latest attestation. Devices below DEVICE never get a session.",
  },
  "col.callsToday": {
    title: "Today",
    meaning: "Classify calls admitted today.",
    computation: "The install's call counter for today (UTC).",
  },
  "col.calls7d": {
    title: "7 days",
    meaning: "Classify calls admitted in the last 7 days.",
    computation: "Sum of the install's daily call counters over the 7 days ending today.",
  },
  "col.callsTotal": {
    title: "Total calls",
    meaning: "Every classify call admitted for this install.",
    computation: "Sum of all its daily call counters.",
  },
  "col.tokensTotal": {
    title: "Total tokens",
    meaning: "Every LLM token this install's successful calls used.",
    computation: "Sum of all its daily token counters.",
  },
  "col.quotaHitDays": {
    title: "Quota days",
    meaning: "Days the install reached its daily call limit.",
    computation: "Days whose call count is at or above the per-install daily limit.",
  },
  "col.status": {
    title: "Status",
    meaning: "Active, dormant (nothing for over 14 days) or banned.",
    computation: "Dormant: not banned and no session or classify call in more than 14 days.",
    caveat: "The server cannot see uninstalls; dormancy stands in for churn.",
  },
  "detail.licensing": {
    title: "Licensing",
    meaning:
      "LICENSED: installed from Play. UNLICENSED: not acquired through Play, e.g. a copied APK. UNEVALUATED: Google could not decide.",
    computation: "Play's licensing verdict from the latest attestation. Recorded, not enforced.",
  },
  "detail.sdk": {
    title: "Android SDK",
    meaning: "The device's Android API level.",
    computation: "From the verdict's device attributes.",
    caveat:
      'Empty unless "device attributes" is enabled in Play Console\'s Integrity API settings.',
  },
  "detail.activity": {
    title: "Activity",
    meaning: "Each day since the install appeared: classified, opened only, or idle.",
    computation: "Classified = at least one call; opened only = a session day without calls.",
    caveat: SESSION_UNDERCOUNT,
  },
  "chart.installCalls": {
    title: "Calls per day",
    meaning: "This install's admitted classify calls each day.",
    computation: "Its daily call counter.",
  },
  "chart.installTokens": {
    title: "Tokens per day",
    meaning: "Tokens this install's successful calls used each day.",
    computation: "Its daily token counter.",
  },
  "chart.active.any": {
    title: "Active installs",
    meaning: "Daily, weekly and monthly active installs, counting classify calls and sessions.",
    computation:
      "For each day: distinct installs active that day, in the 7 days, and in the 30 days ending that day.",
    caveat: SESSION_UNDERCOUNT,
  },
  "chart.active.classify": {
    title: "Active installs",
    meaning: "Daily, weekly and monthly installs that made classify calls.",
    computation:
      "For each day: distinct installs with calls that day, in the 7 days, and in the 30 days ending that day.",
    caveat: SMS_DRIVEN,
  },
  "chart.stickiness.any": {
    title: "Stickiness",
    meaning: "How many days a month the typical monthly user shows up. 30% ≈ 9 days.",
    computation: "Daily active ÷ monthly active, each day.",
    caveat: SESSION_UNDERCOUNT,
  },
  "chart.stickiness.classify": {
    title: "Stickiness",
    meaning: "How many days a month the typical monthly classifier sends calls.",
    computation: "Daily active ÷ monthly active (classify calls only), each day.",
    caveat: SMS_DRIVEN,
  },
  "chart.cohorts.any": {
    title: "Weekly retention",
    meaning: "Of the installs that appeared in a week, the share active in each later week.",
    computation:
      "Cohort = UTC week (Monday start) of first attestation. Cell = share with a classify call or session in that week. Last 12 cohorts.",
    caveat: "The current week is partial.",
  },
  "chart.cohorts.classify": {
    title: "Weekly retention",
    meaning:
      "Of the installs that appeared in a week, the share that made classify calls in each later week.",
    computation:
      "Cohort = UTC week (Monday start) of first attestation. Cell = share with a classify call in that week. Last 12 cohorts.",
    caveat: SMS_DRIVEN,
  },
  "chart.callsDistribution": {
    title: "Calls per active day",
    meaning: "How busy an active install's day is.",
    computation:
      "Every install-day with at least one call in the range, bucketed by its call count. The last bucket is days at or over the daily limit.",
  },
  dormant: {
    title: "Dormant installs",
    meaning: "Installs with no session or classify call for more than 14 days.",
    computation:
      "Not banned, and the latest of last session and last call day is over 14 days ago.",
    caveat: "Includes uninstalls and reinstalls (which get new IDs).",
  },
  "chart.successRate": {
    title: "LLM success rate",
    meaning: "Share of classify calls that reached the LLM step and succeeded, per day.",
    computation: "ok ÷ (ok + upstream 429 + upstream retryable + upstream rejected + internal).",
    caveat: COUNTERS_SINCE,
  },
  "chart.classifyFailures": {
    title: "Failed classify calls",
    meaning: "Classify requests that did not succeed, by kind.",
    computation:
      "Daily outcome counters, grouped: rate limited (quota or global cap), upstream error (OpenRouter), internal, client error (bad or stale token, bad request, banned), cancelled (client went away).",
    caveat: COUNTERS_SINCE,
  },
  "chart.sessionFailures": {
    title: "Failed sessions",
    meaning: "Attestation attempts that did not produce a session, by kind.",
    computation:
      "Daily session outcome counters, grouped: attestation rejected, Google unavailable or internal, challenge refused, client error.",
    caveat: COUNTERS_SINCE,
  },
  "chart.attestReasons": {
    title: "Why attestation failed",
    meaning: "Which Play Integrity check rejected the install.",
    computation: "Session outcome counters for each verification failure over the range.",
    caveat: "device_integrity usually means a rooted phone, emulator or custom ROM.",
  },
  "chart.latency": {
    title: "Classify latency",
    meaning: "How long successful classify calls took, median and 95th percentile.",
    computation:
      "Estimated from per-day latency buckets by interpolating inside the bucket that crosses the rank.",
    caveat: "An estimate within one bucket; calls over 32 s show as 32 s.",
  },
  "chart.models": {
    title: "Served model",
    meaning: "Which model OpenRouter actually answered with.",
    computation: "Successful classify calls per served model over the range.",
    caveat: COUNTERS_SINCE,
  },
  "chart.categories": {
    title: "Message categories",
    meaning: "What the LLM decided successful calls were.",
    computation: "Daily counts of transaction, bill and none (not financial).",
    caveat: COUNTERS_SINCE,
  },
  "chart.tokensPerCall": {
    title: "Tokens per call",
    meaning: "Average tokens a successful classify call used, per day.",
    computation: "Daily tokens ÷ daily ok calls.",
    caveat: COUNTERS_SINCE,
  },
  fleetActive: {
    title: "Recently active installs",
    meaning: "The installs the fleet page describes.",
    computation: "Not banned, with a classify call or session in the last 30 days.",
  },
  "chart.versions": {
    title: "App versions",
    meaning: "Which app version recently active installs run.",
    computation: "versionCode from each install's latest attestation.",
    caveat: "unknown = not attested since the capture deploy.",
  },
  "chart.adoption": {
    title: "Version adoption",
    meaning: "Which versions attested each day over the last 90 days.",
    computation: "Session days per versionCode; the five most common versions, the rest as Other.",
    caveat: COUNTERS_SINCE,
  },
  "chart.tier": {
    title: "Device tier",
    meaning:
      "STRONG: hardware-backed integrity and a recent patch. DEVICE: genuine but older or unpatched.",
    computation: "Strongest device verdict from each recently active install's latest attestation.",
    caveat: "Shows what tightening policy to STRONG would cost.",
  },
  "chart.licensing": {
    title: "Licensing",
    meaning: "LICENSED: from Play. UNLICENSED: copied APK. UNEVALUATED: undecided.",
    computation: "Play's licensing verdict from each recently active install's latest attestation.",
  },
  "chart.sdk": {
    title: "Android SDK",
    meaning: "Android API levels of recently active installs.",
    computation: "From the verdict's device attributes.",
    caveat: 'unknown unless "device attributes" is enabled in Play Console.',
  },
  "chart.localModel": {
    title: "Local model",
    meaning:
      "Share of messages the on-device model handled without the LLM, and how that changes over time.",
    computation:
      "On-device rate = accepted ÷ (accepted + declined). The change is in percentage points against the previous period of the same length. The line is a 7-day weighted average (each day and the 6 before it, pooled); dots are single days; a dashed line marks a day a new app version handled over half of at least 20 messages.",
    caveat: `Model errors (no prediction) are counted but left out of the rate. The ring's LLM count is messages the model declined; the footer's "via LLM" also includes model errors, since those go on to the LLM too. ${MESSAGES_REPORTED}`,
  },
  "col.messagesToday": {
    title: "Today",
    meaning: "Messages the install classified today, with its LLM calls underneath.",
    computation:
      "Accepted + declined + model errors from today's local-model counts (UTC). Every message passes the on-device model first, so this is the total.",
    caveat: MESSAGES_REPORTED,
  },
  "col.messages7d": {
    title: "7 days",
    meaning: "Messages the install classified in the last 7 days, with its LLM calls underneath.",
    computation: "Sum of its daily message counts over the 7 days ending today.",
    caveat: MESSAGES_REPORTED,
  },
  "col.messagesTotal": {
    title: "Total",
    meaning: "Every message the install classified, with its LLM calls underneath.",
    computation:
      "All its daily message counts, including the totals archived once days are older than 90 days.",
    caveat: MESSAGES_REPORTED,
  },
  "chart.installMessages": {
    title: "Messages and calls per day",
    meaning: "Messages this install classified each day, next to the LLM calls it made.",
    computation:
      "Messages: its daily local-model counts, last 90 days only. LLM calls: its daily call counter.",
    caveat: MESSAGES_REPORTED,
  },
  "chart.messagesDistribution": {
    title: "Messages per active day",
    meaning: "How many bank messages an install handles on a day it gets any.",
    computation:
      "Every install-day with at least one message, summed across app versions, bucketed by its message count.",
    caveat: `Covers at most the last 90 days: older per-install counts are archived without install identity. ${MESSAGES_REPORTED}`,
  },
  "chart.messagesPerDay": {
    title: "Messages per day",
    meaning: "Messages classified each day, next to the LLM calls they needed.",
    computation:
      "Messages: accepted + declined + model errors across installs, archived days included. LLM calls: sum of per-install daily call counters.",
    caveat: MESSAGES_REPORTED,
  },
  messagesPerActiveInstallDay: {
    title: "Messages per active install-day",
    meaning:
      "How many messages an install classifies on a typical day it gets any, with LLM calls per active install-day in brackets.",
    computation:
      "Messages in the range ÷ install-days with at least one message (archived days bring their folded install-days). Bracket: calls ÷ install-days with at least one call.",
    caveat: MESSAGES_REPORTED,
  },
} satisfies Record<string, StatCopy>;

export type StatId = keyof typeof statCopy;
