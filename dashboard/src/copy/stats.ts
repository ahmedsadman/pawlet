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

const WHO_REPORTS =
  "Installs using Pawlet's server or their own API key report; installs with no AI service never do. Installs that never passed Play Integrity are included and marked unattested.";
/**
 * The app release that first sends heartbeats. The release owner replaces
 * this with "app version <versionCode>" when that release is cut.
 */
export const HEARTBEAT_RELEASE = "the first app release that sends heartbeats";
const HEARTBEAT_LAG = `Heartbeats are recorded since ${HEARTBEAT_RELEASE}; older installs count only their sessions until they update. Today is usually current within minutes but can lag up to a day; days spent offline arrive late.`;
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
  installs: {
    title: "Installs",
    meaning: "Installs that have reported at least once, with how many passed Play Integrity.",
    computation:
      "Count of install records; attested = has minted a session at least once. A reinstall gets a new install ID, so it counts again.",
    caveat: `${WHO_REPORTS} Play Console has the real install count.`,
  },
  newInstalls: {
    title: "New installs",
    meaning: "Installs first seen in the selected range.",
    computation:
      "Installs whose first report (heartbeat or session) falls in the range, compared with the same-length range before it.",
    caveat: `The week ${HEARTBEAT_RELEASE} rolls out, installs that never attested (own API key, sideloaded) appear for the first time and count as new.`,
  },
  "dau.any": {
    title: "Daily active installs",
    meaning: "Installs that ran today: opened, ran in the background, or made a classify call.",
    computation: "Distinct installs with an activity row or a classify call today (UTC).",
    caveat: HEARTBEAT_LAG,
  },
  "wau.any": {
    title: "Weekly active installs",
    meaning: "Installs that ran at least once in the last 7 days.",
    computation:
      "Distinct installs with an activity row or a classify call in the 7 days ending today.",
  },
  "mau.any": {
    title: "Monthly active installs",
    meaning: "Installs that ran at least once in the last 30 days.",
    computation:
      "Distinct installs with an activity row or a classify call in the 30 days ending today.",
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
  "chart.activeInstallsPerDay": {
    title: "Active installs per day",
    meaning: "Installs that ran each day: opened, in the background, or classifying.",
    computation: 'Distinct installs active each day (the "Running" definition).',
    caveat: HEARTBEAT_LAG,
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
    meaning: "When the install first reported.",
    computation: "Time of its first heartbeat or session, whichever came first.",
  },
  "col.lastSeen": {
    title: "Last seen",
    meaning: "When the install last reported.",
    computation:
      "Time the server last received a heartbeat or session from it (usually once or twice a day while the app is in use or running).",
  },
  "col.version": {
    title: "Version",
    meaning: "The app versionCode the install last reported.",
    computation: "From its newest heartbeat day, or its latest Play Integrity verdict.",
  },
  "col.attested": {
    title: "Attested",
    meaning: "Whether the install has ever passed Play Integrity.",
    computation:
      "Yes once it mints a session. Heartbeat-only installs (own API key, sideloaded) say No.",
    caveat:
      "Heartbeats are unauthenticated: an install that never attested could be faked. Filter to attested installs to exclude them.",
  },
  "col.tier": {
    title: "Device tier",
    meaning:
      "STRONG: hardware-backed integrity and a recent security patch. DEVICE: a genuine Play-certified device.",
    computation:
      "Strongest device verdict in the latest attestation. Empty for installs that never attested.",
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
    computation:
      "Dormant: not banned and no heartbeat, session or classify call in more than 14 days.",
    caveat:
      "The server cannot see uninstalls. On app versions that send heartbeats, dormant mostly means uninstalled, force-stopped, or switched to no AI service.",
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
    meaning:
      "Each day since the install appeared: classified, opened, ran in the background only, or idle.",
    computation:
      "Classified = at least one call; opened = the app came to the screen (or minted a session); background only = the app ran without being opened.",
    caveat: HEARTBEAT_LAG,
  },
  "chart.installTokens": {
    title: "Tokens per day",
    meaning: "Tokens this install's successful calls used each day.",
    computation: "Its daily token counter.",
  },
  "chart.active.any": {
    title: "Active installs",
    meaning:
      "Running: daily, weekly and monthly installs whose app ran, in the foreground or the background.",
    computation:
      "For each day: distinct installs with an activity row or a classify call that day, in the 7 days, and in the 30 days ending that day.",
    caveat: HEARTBEAT_LAG,
  },
  "chart.active.opened": {
    title: "Active installs",
    meaning: "Opened: daily, weekly and monthly installs whose app came to the screen.",
    computation:
      "For each day: distinct installs that reported an open or minted a session (only done in the foreground) that day, in the 7 days, and in the 30 days ending that day.",
    caveat: HEARTBEAT_LAG,
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
    meaning: "How many days a month the typical monthly install runs. 30% ≈ 9 days.",
    computation: "Daily running ÷ monthly running, each day.",
    caveat: HEARTBEAT_LAG,
  },
  "chart.stickiness.opened": {
    title: "Stickiness",
    meaning: "How many days a month the typical monthly user opens the app. 30% ≈ 9 days.",
    computation: "Daily opened ÷ monthly opened, each day.",
    caveat: HEARTBEAT_LAG,
  },
  "chart.stickiness.classify": {
    title: "Stickiness",
    meaning: "How many days a month the typical monthly classifier sends calls.",
    computation: "Daily active ÷ monthly active (classify calls only), each day.",
    caveat: SMS_DRIVEN,
  },
  "chart.cohorts.any": {
    title: "Weekly retention",
    meaning: "Of the installs that appeared in a week, the share still running in each later week.",
    computation:
      "Cohort = UTC week (Monday start) of first report. Cell = share with any activity in that week. Last 12 cohorts.",
    caveat: "The current week is partial.",
  },
  "chart.cohorts.opened": {
    title: "Weekly retention",
    meaning:
      "Of the installs that appeared in a week, the share that opened the app in each later week.",
    computation:
      "Cohort = UTC week (Monday start) of first report. Cell = share that reported an open or minted a session in that week. Last 12 cohorts.",
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
  dormant: {
    title: "Dormant installs",
    meaning: "Installs with no heartbeat, session or classify call for more than 14 days.",
    computation:
      "Not banned, and the later of last seen and the last classify-call day is over 14 days ago.",
    caveat:
      "On app versions that send heartbeats, mostly uninstalls, force-stopped apps, and installs switched to no AI service. Reinstalls get new IDs.",
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
    computation: "Not banned, and ran (heartbeat, session or classify call) in the last 30 days.",
  },
  "chart.versions": {
    title: "App versions",
    meaning: "Which app version recently active installs run.",
    computation: "The versionCode each install last reported.",
    caveat: "unknown = never reported a version.",
  },
  "chart.adoption": {
    title: "Version adoption",
    meaning: "Which versions installs ran each day over the last 90 days.",
    computation: "Activity days per versionCode; the five most common versions, the rest as Other.",
    caveat: HEARTBEAT_LAG,
  },
  "chart.tier": {
    title: "Device tier",
    meaning:
      "STRONG: hardware-backed integrity and a recent patch. DEVICE: genuine but older or unpatched.",
    computation:
      "Strongest device verdict from each recently active install's latest attestation. Attested installs only.",
    caveat: "Shows what tightening policy to STRONG would cost.",
  },
  "chart.licensing": {
    title: "Licensing",
    meaning: "LICENSED: from Play. UNLICENSED: copied APK. UNEVALUATED: undecided.",
    computation:
      "Play's licensing verdict from each recently active install's latest attestation. Attested installs only.",
  },
  "chart.sdk": {
    title: "Android SDK",
    meaning: "Android API levels of recently active installs.",
    computation: "From the verdict's device attributes. Attested installs only.",
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
