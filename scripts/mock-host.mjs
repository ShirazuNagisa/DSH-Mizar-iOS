/**
 * A stand-in host, for verifying UI that needs state the real host cannot be
 * asked to produce on demand.
 *
 * A pending approval only exists while an agent is blocked on a tool call, so
 * the only ways to see one are to catch it live or to fake it. Catching it live
 * depends on a model deciding to call a tool, which makes it useless as a test.
 * This serves the real protocol -- the same frames, the same shapes, taken from
 * the recorded fixtures -- so the app renders actual decoded responses rather
 * than a special-cased path.
 *
 * It is a test fixture, not a host: it authenticates nothing and stores nothing.
 *
 * Usage: node scripts/mock-host.mjs [port]
 */
import { createServer } from 'node:http'
import ws from '../node_modules/ws/index.js'

const { WebSocketServer } = ws

const port = Number(process.argv[2] ?? 19395)
const CODE = 'MOCK-CODE'

/**
 * The second listener: a stand-in for the relay, on `port + 2`.
 *
 * A real pairing can carry two routes to the same computer: the direct address
 * (`h=`) and a reverse tunnel's base URL (`u=`), whose path names the room --
 * `https://relay.example.com/r/ROOM`. The app turns the base into
 * `wss://relay.example.com/r/ROOM/mizar/v1/ws`. Serving the same path from a
 * second listener in this process is what makes "the LAN died and the relay is
 * still reachable" a fixture: one pairing, one device token, one fixture, two
 * sockets at two addresses.
 *
 * `port + 2` keeps the two fixture computers apart -- 19395's relay is 19397 and
 * 19396's is 19398 -- so a test cannot fail over to the *other* mock's relay.
 */
const RELAY_PORT = port + 2
/** The room this stand-in relay serves. */
const RELAY_ROOM = 'mock-room'
/** The path the app dials the computer at, directly. */
const WS_PATH = '/mizar/v1/ws'
/** The path the app dials the same computer at, through the relay. */
const RELAY_WS_PATH = `/r/${RELAY_ROOM}${WS_PATH}`

/**
 * Which machine this instance is pretending to be.
 *
 * A phone that is paired with two computers draws one computer's state under another's
 * name unless every read is tagged with the machine it came from, and one mock
 * on one port cannot tell that apart from a working app: both hosts would answer
 * with the same host id, the same sessions and the same providers. Running a
 * second instance on another port is what makes "this belongs to that computer"
 * observable, so the identity is derived from the port rather than fixed.
 *
 * 19395 stays exactly what it was -- every existing test measures *that* computer.
 */
const SECOND_IDENTITY = port === 19396

/** This machine's id, as it reports at pairing and in `welcome`. */
const HOST_ID = SECOND_IDENTITY
  ? 'mock-host-1111-4000-8000-000000000000'
  : 'mock-host-0000-4000-8000-000000000000'
/** This machine's own name, which is the only label on screen that differs. */
const HOST_NAME = SECOND_IDENTITY ? 'Mock Mac (second)' : 'Mock Mac (fixture)'
/** The device id this machine issues at pairing. */
const DEVICE_ID = SECOND_IDENTITY
  ? 'mock-device-1111-4000-8000-000000000000'
  : 'mock-device-0000-4000-8000-000000000000'
// A real host rarely has pending requests and a conversation at the same time;
// the flag lets each be seen on its own.
/**
 * Whether a pending approval and question are on offer.
 *
 * A launch flag, and switchable at runtime by `/reset`. The two cards take most
 * of a phone screen, which is right -- an agent blocked on a decision is the
 * most urgent thing there is -- but it leaves a test about the conversation
 * measuring a screenful of card. A test says which it wants.
 */
let withPending = process.env['MIZAR_MOCK_PENDING'] !== '0'

/**
 * Whether the fixture's first turn declares a delivered file.
 *
 * Off by default so every suite that existed before this feature measures the
 * same screen it measured then: the card is a row under the answer, and a row is
 * enough to move everything below it. A test about previews turns it on with
 * `/deliverables?on=1` and `/reset` turns it off again.
 */
let deliverablesPresent = false

// Optional official-account fixture. Existing tests stay on an old plugin and
// therefore cannot accidentally issue balance queries or expose account data.
let balanceVariant = 'old'
let longReaderFixture = false
let hideSessionFromList = false
let markdownReaderFixture = false
const performanceMarkdown = (turn, role) => `# 固定性能样本 ${turn} ${role}\n\n正文 **强调** 与中文，保持布局可重复。\n\n- 第一项\n- 第二项\n\n\`\`\`swift\nlet value = ${turn}\n\`\`\`\n\n| 列A | 列B |\n| --- | --- |\n| 甲 | 乙 |`
const forkRequests = []

/**
 * How long to stall every answer, in milliseconds.
 *
 * For the two screens that exist to say how long something is taking, and which
 * are therefore impossible to observe against a mock that answers instantly: a
 * progress bar that appears and vanishes inside one runloop turn is a progress
 * bar no test can see. Set by `/reset?slow=NNN`, and zero otherwise so the rest
 * of the suite is not slowed down for it.
 */
let answerDelayMs = 0

/**
 * Whether the mock should refuse every connection.
 *
 * A computer that is asleep, or on a network that has gone away. Switchable at
 * runtime by `/offline?on=1` so a test can take the host away *after* the phone
 * has synced from it -- which is the only way to check that an unreachable computer
 * does not take away what the phone already stored.
 */
let offline = false

/**
 * Whether the LAN route is down: live sockets dropped, new ones refused.
 *
 * A different failure from ``offline``, and the one the reported bug is about.
 * The phone is connected over the direct address when the operator walks out of
 * Wi-Fi range: that socket dies, and the address stops answering, while the
 * relay in the same pairing is still there and would work. The app used to keep
 * dialling the lost address and never try the relay, so the phone sat in a
 * reconnect loop.
 *
 * `/lan?off=1` destroys every live socket on the main listener and refuses new
 * WebSocket upgrades on it. Ordinary HTTP stays up on purpose: `/lan?on=1`,
 * `/reset` and the rest of the control surface are how a test (and the mock's
 * own operator) gets the fixture back. The relay listener is untouched -- that
 * is the whole point. `/reset` restores it.
 */
let lanOff = false

/**
 * Whether the mock also lists a forked conversation and a delegated child.
 *
 * DSH's "branch in a new conversation" creates a *new top-level session* whose
 * header keeps the source as its parent -- an ordinary conversation the
 * operator asked for. Read off a real header on this machine it is
 * `parentSession: <source>` and `isSeeded: true`, with no `origin` at all.
 * A delegated child is the different thing: the same parent, plus
 * `origin: "subagent"` and a delegation depth.
 *
 * The phone's sidebar used to treat *any* parent as the subagent mark, so the
 * fork was filtered out of the list forever -- refresh included. Both rows
 * exist here so the two can be told apart: the fork has to be drawn, the
 * delegated child has to stay hidden. They are absent unless `/forked?on=1`
 * asks for them, so the default fixture -- which every other suite measures --
 * is exactly what it was.
 */
let forkedSessionPresent = false

/**
 * A method whose answers should fail from now on, until `/reset`.
 *
 * For the screens that read the same thing more than once. `session.stats` is
 * re-read every time a session screen reloads, and a failure used to erase the
 * model and context figures that an earlier read had already put on screen --
 * "刚点进去一个会话，然后该会话的标题、正在使用的模型、上下文用量显示全部消失".
 * Arming this after the first read has landed is what makes that reproducible:
 * `/fail?method=session.stats`.
 */
let failMethod = null

/**
 * Whether `session.stats` should answer like a session whose agent is cold.
 *
 * Each field of that frame comes from its own projection on the host, and a
 * projection answers with what it has right now: a cold session has a token
 * meter and nothing else -- no title, no model selection, no context pressure.
 * So this is not a broken answer, it is an *ordinary* one, and a screen that
 * replaces what it has with it loses three figures it was already showing.
 * `/stats?variant=cold` and back with `/stats?variant=full`.
 */
let statsVariant = 'full'

/**
 * A clock offset, in milliseconds, applied to every record the mock sends.
 *
 * The host's clock and the phone's are two clocks, and the app does arithmetic
 * across them: a running turn's start comes off the host, `now` off the phone.
 * A computer whose clock is ahead is the case that produced a negative duration on
 * screen, and it cannot be reproduced by a fixture whose times are all the
 * phone's. Set by `/reset?skew=NNN`.
 */
let clockSkewMs = 0

/**
 * The largest `maxMessages` the mock will answer, when a test sets one.
 *
 * The host refuses an answer it cannot deliver with `RESPONSE_TOO_LARGE` rather
 * than sending it and closing the socket, and the client's answer to that is to
 * ask for less. `Infinity` unless `/reset?pageLimit=NNN` says otherwise.
 */
let pageLimit = Infinity

/**
 * Whether the mock's main session reports itself as running.
 *
 * The Live Activity has two states, and the finished one -- a check, and the
 * words "every session has finished" -- is only ever reached by *updating* an
 * activity that was started while something was running. Flipping this at
 * runtime is the only way to get there without waiting for an agent to stop.
 */
let sessionRunning = true

/**
 * Whether this reset asks the mock to play a live state sequence.
 *
 * The real host pushes 13-byte state frames on a binary channel while a turn
 * runs; without them the phone has no status lines and no stream to draw, so a
 * UI test for the stream is a test of an empty page. `/reset?states=1` schedules
 * one sequence per reset for the fixture session.
 */
let stateStream = ''
let stateStreamPlayed = false
let stateStreamEntries = []

/**
 * The fixture session's permission preset, as the host last reported it.
 *
 * `session.permission.set` changes it, `session.stats` reports it, and `/reset`
 * restores it. It has to be *state* rather than a fixed answer, because the
 * defect 0.9.4 fixes is precisely that the phone drew the choice it had just
 * made and then went back to the host's old report: a fixture that always says
 * `workspace-write` cannot tell "the switch stuck" from "the switch was only
 * drawn".
 */
let permissionPreset = 'workspace-write'

/**
 * The presets the fixture's catalogue offers, and the only ones it accepts.
 *
 * A real host refuses a value it does not have a preset for, and the phone has
 * to say so rather than pretend. Validating here keeps a typo in a test honest
 * instead of letting it become an accepted switch nobody can reproduce.
 */
const PERMISSION_PRESETS = ['read-only', 'workspace-write', 'danger-full-access']

/**
 * Sessions archived since the last reset.
 *
 * Archived is host-side state, not a deletion: the log stays on the computer,
 * `session.list` and `workspace.list` stop mentioning the session, and `/reset`
 * puts the fixture's list back. The phone's job is to make both of those true
 * at once, so the mock has both lists to be wrong in.
 */
const archivedSessionIds = new Set()

/**
 * How many WebSocket connections the mock has accepted since the last reset.
 *
 * A reconnect is invisible from the app's screen -- the data looks the same
 * afterwards -- so the only way to assert that a failure did *not* cost a fresh
 * socket is to count them from the host's side.
 *
 * This is the **direct** listener's count: `GET /connections` on the main port.
 * The relay stand-in keeps its own -- see ``relayConnections`` -- because "the
 * phone is on the relay now" is the assertion, and one shared counter could not
 * tell a direct socket from a relayed one.
 */
let connections = 0

/**
 * How many WebSocket connections the relay stand-in has accepted since reset.
 *
 * Read from the *relay* port's `GET /connections`. Zero means nothing tried the
 * relay; a number means the app dialled the fallback route, which is exactly the
 * failover this fixture exists to observe.
 */
let relayConnections = 0

/**
 * How many pairing requests the main listener has answered since the last reset.
 *
 * A UI test launches the app with a pairing URI, and whether that launch really
 * carried it is otherwise invisible: a launch the system performed on its own --
 * restoring a Live Activity, say -- connects from the stored pairing and looks
 * exactly like the one the test asked for. The pairing request is the fact that
 * tells the two apart, so the test can relaunch until it is the one in charge.
 * Reported on `/loads` as `pairings`.
 */
let pairingRequests = 0

/**
 * How many unauthenticated `hello` probes have reached the host since the last
 * reset.
 *
 * This is the LAN scan's observable footprint. `AppModel.scanForLocalNetwork`
 * probes each candidate address with `GET /mizar/v1/hello` before it decides
 * whether the local network answers, and whether that scan runs at all is the
 * setting under test: with "Local network first" off, a manual refresh must do
 * no probing; with it on, the refresh is allowed to ask.
 *
 * Read from `GET /hellos` on the main listener, as one number. Deliberately not
 * folded into `/loads`: that endpoint reports frame counters, and this one is
 * about plain HTTP requests the app made *before* it opened a socket. A probe is
 * invisible on screen -- the scan either finds something or silently does not --
 * so the host's count is the only place the difference is a fact.
 */
let hellos = 0

/**
 * How many frames the mock has answered, by method, since the last reset.
 *
 * A second load on one socket is invisible from the app's side -- every request
 * is answered, and the screen settles on the same content -- so "one load was in
 * flight, not two" can only be asserted by counting what the host was actually
 * asked. `session.messages` is the read that two overlapping loads both make.
 */
const methodCounts = {}

/**
 * One method whose answers are stalled, while the rest answer immediately.
 *
 * `/slow` stalls *every* method, which also stalls the launch, the send and the
 * reads that carry the screen the assertion is about -- so a test that wants two
 * loads to overlap ends up measuring a stalled app instead. Naming the method
 * makes the overlap reachable: the reload being observed is slow, and everything
 * the test needs in order to start a second load is not.
 */
let slowMethod = null

/**
 * How many `session.messages` reads are being answered at once, and the most
 * that ever were.
 *
 * Two loads overlapping on one socket is the failure this counts, and neither
 * the screens nor the answers can show it: both requests are answered correctly
 * and the conversation that settles on screen is the same one. In flight at the
 * same time is the whole of the defect, so the count is read at the host, where
 * it is a fact.
 */
let messagesInFlight = 0
let messagesPeak = 0

/**
 * Whether `session.messages` answers are being held, and what is waiting.
 *
 * A stall is a race: a delay long enough to be measured on a loaded machine is a
 * delay long enough for the thing being overlapped to have finished first. Held,
 * the answer waits for the test to release it, so "the reload is still in
 * flight" is a fact rather than a hope -- which is what makes the assertion
 * about a *second* load landing on top of it deterministic.
 */
let holdingMessages = false
let heldMessages = []

/** Every `session.model.set` the mock was asked to make, in order. */
const modelSets = []
/** How many times each method was refused, by method. */
const refusedCounts = {}

// Declared before the two interaction fixtures, which carry its session id.
const SESSION = {
  sessionId: SECOND_IDENTITY ? 'session-mock-second' : 'session-mock-0001',
  cwd: '/Users/you/projects/demo',
  // Epoch milliseconds, which is what the host reports.
  updatedAt: Date.now() - 120_000,
  running: true,
  blank: false,
  agentAvailable: true,
  parentSessionId: null,
  origin: null,
}

/** A pending approval, shaped like the one the bridge builds. */
const APPROVAL = {
  requestId: 'a1b2c3d4-0000-4000-8000-000000000001',
  sessionId: SESSION.sessionId,
  toolName: 'write_file',
  callId: 'call-1',
  reason: 'Writing to a path outside the workspace',
  displayReason: {
    en: 'Writing to a path outside the workspace',
    zh: '正在写入工作区之外的路径',
  },
  requestedAt: Date.now() / 1000,
}

/** A question batch, including a plan review, which is the interesting shape. */
const QUESTION = {
  callId: 'call-2',
  sessionId: SESSION.sessionId,
  requestedAt: Date.now() / 1000,
  questions: [
    {
      id: 'q1',
      header: 'Approach',
      question: 'How should I handle the schema change?',
      detail: 'The migration is not reversible without a backup.',
      multiSelect: false,
      options: [
        { label: 'Migrate in place', description: 'Fast, and needs a backup first.' },
        { label: 'Add a new column', description: 'Slower, and reversible.' },
      ],
    },
    {
      id: 'q2',
      header: 'Plan',
      question: 'Proceed with this plan?',
      intent: { kind: 'plan-review', approve: 'Approve plan' },
      multiSelect: false,
      options: [{ label: 'Approve plan', description: 'Start implementing.' }],
    },
  ],
}

/** A session whose working directory the host has no workspace for.
 *
 * The shape of the bug: deleting a workspace removes the host's registry entry
 * and leaves the session log on disk, so `session.list` keeps returning it. A
 * phone that grouped sessions by working directory drew a row for a workspace
 * that had been deleted.
 */
const ORPHANED_SESSION = {
  sessionId: SECOND_IDENTITY ? 'session-mock-second-orphan' : 'session-mock-orphan',
  cwd: '/Users/you/projects/deleted-workspace',
  updatedAt: Date.now() - 900_000,
  running: false,
  blank: false,
  agentAvailable: false,
  parentSessionId: null,
  origin: null,
}

/**
 * A conversation "branched" out of the fixture's session, as DSH creates it.
 *
 * The shape that was missing from every fixture, and the whole reason for the
 * report: the host copies the source into a new session and records the source
 * as that session's `parentSession`, while `origin` stays empty. It is the
 * operator's own conversation -- the host's session list draws it, and DSH's
 * desktop sidebar shows it -- so the phone has to draw it too.
 *
 * Newest activity in the list on purpose: it belongs at the top of its
 * workspace, where a missing row is hardest to explain away as "below the
 * fold". `updatedAt` is offset from the fixture session's rather than from
 * `Date.now()` at answer time, so its position cannot change under a refresh.
 */
const FORKED_SESSION = {
  sessionId: SECOND_IDENTITY ? 'mock-forked-session-second-0001' : 'mock-forked-session-0001',
  cwd: SESSION.cwd,
  updatedAt: SESSION.updatedAt + 60_000,
  running: false,
  blank: false,
  agentAvailable: true,
  parentSessionId: SESSION.sessionId,
  origin: null,
}

/**
 * The delegated child that must *not* be drawn, told apart by the host's mark.
 *
 * The same parent as the fork and the same working directory -- so nothing but
 * `origin` can separate them. If a reading of the list keys on the parent, it
 * shows this row and hides the fork; the fixture asks for both behaviours at
 * once so which one happened is visible in one screen.
 *
 * Deliberately given no title (its `session.stats` answer has none) so a row
 * that leaked would read as `<dir> · <id prefix>` rather than pretend to be a
 * conversation; the sidebar query for a leaked row names that id prefix.
 */
const SUBAGENT_SESSION = {
  sessionId: SECOND_IDENTITY ? 'mock-subagent-session-second-0001' : 'mock-subagent-session-0001',
  cwd: SESSION.cwd,
  updatedAt: SESSION.updatedAt + 120_000,
  running: false,
  blank: false,
  agentAvailable: true,
  parentSessionId: SESSION.sessionId,
  origin: 'subagent',
}

/**
 * The file the fixture's first turn delivers, when `/deliverables?on=1`.
 *
 * Small on purpose: the preview page is asserted by finding a line of its text,
 * and a fixture whose content is longer than a phone screen would make that
 * assertion depend on scrolling.
 */
const DELIVERED_FILES = {
  md: {
    path: 'docs/delivered.md',
    description: 'A delivered report',
    body: Buffer.from('# Delivered report\n\nThis file was read from the computer.\n', 'utf8'),
    mediaType: 'text/markdown',
  },
  code: {
    path: 'src/demo.swift',
    description: 'A source file',
    body: Buffer.from('import Foundation\n\nstruct Demo {\n    // MIZAR_SOURCE_MARKER\n    let value = 42\n}\n', 'utf8'),
    mediaType: 'text/plain',
  },
  image: {
    path: 'shots/chart.png',
    description: 'A chart',
    // A 64x64 gradient. The real bytes matter: the app decides what to draw
    // from the extension, then ImageIO reads this header and pixels.
    body: Buffer.from('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', 'base64'),
    mediaType: 'image/png',
  },
}

/** Which delivered file the fixture's first turn declares. */
let deliveredVariant = 'md'

/** The delivered file the fixture currently names. */
function deliveredFile() {
  return DELIVERED_FILES[deliveredVariant] ?? DELIVERED_FILES.md
}

/** The fixture file a path names, whichever variant is selected. */
function deliveredFileByPath(path) {
  return Object.values(DELIVERED_FILES).find((file) => file.path === path) ?? null
}

/** The extra sessions the list reports while `/forked?on=1` is set. */
function forkedSessions() {
  return forkedSessionPresent ? [FORKED_SESSION, SUBAGENT_SESSION] : []
}

/**
 * The second session's conversation, which says different things.
 *
 * One view draws every session, so every value it holds has to belong to the
 * session it was filled from -- and a fixture where both sessions answer with
 * the same page cannot tell "the tag works" from "the tag is ignored", because
 * the screen looks right either way. This one is deliberately *unlike* the
 * other: its own prompt and answer, and `hasMore: true` on the newest page so
 * that "can older history still be asked for" is state that differs between the
 * two sessions too.
 *
 * - Parameter beforeSeq: the position the client is paging back from, or `null`
 *   for the newest page.
 * - Returns: one page, in the shape `session.messages` answers with.
 */
function orphanMessages(beforeSeq) {
  const now = Date.now()
  // Positions descend as the pages get older, so the client's `oldestSeq`
  // arithmetic -- and its decision to stop -- sees what a real log looks like.
  let counter = beforeSeq === null ? 900 : 780
  const record = (type, data) => {
    counter += 1
    return {
      type: 'event',
      event: { type, seq: counter, time: now + clockSkewMs - (950 - counter) * 1000, data },
    }
  }
  if (beforeSeq !== null) {
    // The page before the one the phone already has. One finished turn, and
    // nothing older behind it.
    return {
      sessionId: ORPHANED_SESSION.sessionId,
      asOfSeq: 790,
      hasMore: false,
      records: [
        record('turn/start', { turn: 1 }),
        record('step/start', { turn: 1, step: 1 }),
        record('user/message', {
          content: [{ type: 'text', text: 'Older history from the other session.' }],
          source: { kind: 'user' },
          role: 'user',
          id: 'orphan-m1',
        }),
        record('assistant/message', {
          turn: 1,
          step: 1,
          message: {
            role: 'assistant',
            content: [{ type: 'text', text: 'Answered a long time ago.' }],
          },
        }),
        record('turn/end', { turn: 1, reason: { kind: 'completed' } }),
      ],
    }
  }
  return {
    sessionId: ORPHANED_SESSION.sessionId,
    asOfSeq: 910,
    hasMore: true,
    records: [
      record('turn/start', { turn: 2 }),
      record('step/start', { turn: 2, step: 1 }),
      record('user/message', {
        content: [{ type: 'text', text: 'A prompt from the other session.' }],
        source: { kind: 'user' },
        role: 'user',
        id: 'orphan-m2',
      }),
      record('assistant/message', {
        turn: 2,
        step: 1,
        message: {
          role: 'assistant',
          content: [{ type: 'text', text: 'A different session, a different answer.' }],
        },
      }),
      record('turn/end', { turn: 2, reason: { kind: 'completed' } }),
    ],
  }
}

/**
 * A forked conversation's history: one finished turn, and nothing behind it.
 *
 * Small on purpose. What the test has to see is that the row opens and its
 * history syncs -- a user message and the answer it got, in the shape the host
 * sends them (the prompt inside its turn, after `turn/start` and `step/start`,
 * and a summary assistant message). There is no older page: `hasMore: false`
 * says the walk is over, and a `beforeSeq` read is answered the way the host
 * answers one -- nothing older.
 *
 * - Parameter beforeSeq: the position the client is paging back from, or `null`
 *   for the newest page.
 * - Returns: one page, in the shape `session.messages` answers with.
 */
function forkedMessages(beforeSeq) {
  const now = Date.now()
  if (beforeSeq !== null) {
    return {
      sessionId: FORKED_SESSION.sessionId,
      asOfSeq: 5,
      hasMore: false,
      records: [],
    }
  }
  let counter = 0
  const record = (type, data) => {
    counter += 1
    return {
      type: 'event',
      event: { type, seq: counter, time: now + clockSkewMs - (5 - counter) * 1000, data },
    }
  }
  return {
    sessionId: FORKED_SESSION.sessionId,
    asOfSeq: 5,
    hasMore: false,
    records: [
      record('turn/start', { turn: 1 }),
      record('step/start', { turn: 1, step: 1 }),
      record('user/message', {
        content: [{ type: 'text', text: 'A branch of the parser work.' }],
        source: { kind: 'user' },
        role: 'user',
        id: 'fork-m1',
      }),
      record('assistant/message', {
        turn: 1,
        step: 1,
        message: {
          role: 'assistant',
          content: [{ type: 'text', text: 'The branch kept the parser tests.' }],
        },
      }),
      record('turn/end', { turn: 1, reason: { kind: 'completed' } }),
    ],
  }
}

/**
 * The main conversation's prompt and answer on this machine.
 *
 * Deliberately different on the second instance. A test that switches computers has
 * to be able to say *whose* conversation is on screen, and two hosts serving the
 * same text cannot answer that -- the screen looks the same whichever machine's
 * page was drawn under it.
 */
const MAIN_PROMPT = SECOND_IDENTITY
  ? 'The second computer’s own prompt, and nothing else.'
  : 'Refactor the parser and run the tests.'
const MAIN_ANSWER = SECOND_IDENTITY
  ? 'The second computer answered this one.'
  : 'The parser is now two files.'

/**
 * Prompts the client has sent, in order.
 *
 * The mock used to answer every prompt with `accepted` and then return a fixed
 * log, so a sent message never appeared in the conversation -- which made the
 * send path untestable and, worse, would have let a real defect through: the app
 * did not refresh the conversation after sending, so a message did not show up
 * until the operator pulled to refresh.
 */
const sentPrompts = []
/**
 * How each of `sentPrompts` was delivered, in the same order.
 *
 * `queue` or `steer` exactly as the app sent it, with an absent `mode` recorded
 * as `queue` -- which is what a host reads it as. Kept beside the texts rather
 * than replacing them because the conversation fixture takes strings, and
 * because this is the only way a test can tell guidance from a queue: both
 * produce one accepted `session.prompt` on the wire.
 */
const sentPromptModes = []
/**
 * Sessions the phone started with `session.create`, and what was said in each.
 *
 * Kept apart from the fixture's own session so a test that starts one sees a
 * conversation of its own -- its first prompt and nothing else -- and so
 * `/reset` can put the list back as it was.
 */
const createdSessions = []

/**
 * How many `session.activity` polls the mock has answered since `/reset`.
 *
 * The paid detail feed is live: each poll returns one more line, up to the
 * fixture's eight. That is what makes the app's "new rows descend as the turn
 * progresses" behaviour observable instead of a static list that arrives whole.
 */
let activityPolls = 0

/**
 * How many entries the long activity fixture exposes, or zero for the default.
 *
 * `/activity?count=NNN` sets it and `/reset` puts it back. The default fixture
 * -- `ACTIVITY_ENTRIES`, growing three rows per poll up to its eight -- is what
 * every other suite measures, and must stay exactly as it was. The long one is
 * a fixed log of N distinct entries, so a test can scroll the detail area back
 * and prove the phone asked the host for an older page instead of treating the
 * window it was given as the whole turn.
 */
let activityLongCount = 0

/**
 * How many `session.activity` requests carried `beforeSeq` since the last
 * reset.
 *
 * Lazy loading is invisible from the screen -- the rows that arrive look like
 * the rows that were already there -- so "an older page was asked for" is a
 * fact only the host holds. Reported on `/loads` as `activityPages`.
 */
let activityPageRequests = 0

/**
 * How many rows the long fixture's forward (newest) answer carries.
 *
 * Deliberately smaller than the host's own log and than the phone's ask: the
 * paging path only exists for a turn longer than one window, so the fixture
 * serves a short newest window in long mode and the rest of the log by
 * `beforeSeq`. A test then reaches the paging code after a couple of drags
 * rather than after scrolling through the whole turn.
 */
const LONG_ACTIVITY_FORWARD = 12

/** The log position of the long fixture's oldest entry. */
const LONG_ACTIVITY_FIRST_SEQ = 100

/** The kinds the long fixture cycles through, so the rows look like a turn. */
const LONG_ACTIVITY_KINDS = ['thinking', 'command', 'output', 'tool']

/**
 * The long activity fixture: N distinct rows, oldest first.
 *
 * Every row belongs to the running turn and has a distinct id, seq and
 * one-line text ending in "Activity line <n> of <N>". The numbering is what
 * lets a test name a row the newest window cannot contain, and then find it
 * after paging back to it.
 *
 * @param count - how many rows the log holds.
 * @param turn - the running turn they belong to.
 * @returns the log, oldest first.
 */
function longActivityEntries(count, turn) {
  const now = Date.now()
  return Array.from({ length: count }, (_, index) => ({
    id: `activity-long-${index + 1}`,
    seq: LONG_ACTIVITY_FIRST_SEQ + index,
    at: now - (count - index) * 900,
    kind: LONG_ACTIVITY_KINDS[index % LONG_ACTIVITY_KINDS.length],
    title: '',
    text: `Activity line ${index + 1} of ${count}`,
    turn,
  }))
}

/**
 * The paid full-detail feed for the fixture's running turn.
 *
 * Shaped like the host's `session.activity` entries: compact one-liners the
 * phone draws without further work. Deliberately one of each kind, so all four
 * category labels can be seen on one screen.
 */
const ACTIVITY_ENTRIES = [
  { id: 'seq-28', kind: 'thinking', title: '', text: 'Planning the parser refactor and the tests it needs' },
  { id: 'seq-29-command', kind: 'command', title: 'Bash', text: 'rg -n "assistant/message" src/protocol' },
  { id: 'seq-30-output', kind: 'output', title: 'Bash', text: 'src/protocol/frames.ts:88: assistant/message' },
  { id: 'seq-31-tool', kind: 'tool', title: 'Read', text: 'src/protocol/frames.ts (1-240)' },
  { id: 'seq-32-thinking', kind: 'thinking', title: '', text: 'The reader folds markers into turns; a summary row is enough' },
  { id: 'seq-33-command', kind: 'command', title: 'Bash', text: 'npm test' },
  { id: 'seq-34-output', kind: 'output', title: 'Bash', text: 'Tests: 184 passed, 184 total' },
  { id: 'seq-35-tool', kind: 'tool', title: 'Write', text: 'src/protocol/summaries.ts' },
]

/** Answer one client frame. */
function answer(frame) {
  const { id, type } = frame
  if (type === failMethod) {
    // Counted before the refusal, not after it. A refused method is the one a
    // test is most likely to be counting -- "did the app ask at all" -- and a
    // count that skipped it answered zero for a request that did arrive.
    refusedCounts[type] = (refusedCounts[type] ?? 0) + 1
    console.log('mock: refused ->', type)
    return { v: 1, type: 'error', code: 'INTERNAL', message: 'failed on purpose', id }
  }
  switch (type) {
    case 'hello':
      return {
        v: 1,
        type: 'welcome',
        id,
        hostId: HOST_ID,
        hostName: HOST_NAME,
        protocolVersion: 1,
        home: '/Users/you',
        deviceId: DEVICE_ID,
      }
    case 'host.info':
      // The real shape, including `addresses` -- the later, optional field the
      // host now sends so a relayed phone can find it directly. The mock is
      // bound to loopback, and says so: that is the address a phone on this
      // simulator could actually dial. `LocalNetwork` deliberately does not
      // treat loopback as a LAN, so this fixture cannot turn every existing
      // test into a LAN-unlocked account. The Debug-only `-mizarLocalNetwork`
      // launch flag is how a UI test asks for that state explicitly.
      return {
        v: 1,
        type: 'ok',
        id,
        result: {
          hostId: HOST_ID,
          hostName: HOST_NAME,
          home: '/Users/you',
          protocolVersion: 1,
          addresses: [`127.0.0.1:${port}`],
          // What the computer list draws under the name. The second machine is
          // still DSH on macOS; only the name distinguishes the two.
          desktop: { os: 'macOS', client: 'DSH' },
          ...(balanceVariant === 'missing' ? {} : {
            plugin: { id: balanceVariant === 'nonplugin' ? 'other-plugin' : 'dsh-mizar', capabilities: balanceVariant === 'old' ? [] : ['deepseek.balance.v1'] },
          }),
        },
      }
    case 'account.balance':
      if (balanceVariant === 'failed') return { v: 1, type: 'error', id, error: { code: 'UPSTREAM_FAILED', message: 'Fixture balance request failed' } }
      return { v: 1, type: 'ok', id, result:
        ['ready', 'long'].includes(balanceVariant) ? {
          status: 'ready', wallets: [{ currency: 'CNY', balance: balanceVariant === 'long' ? '12345678901234567890.000000000001' : '123.456789' }, { currency: 'USD', balance: '0' }],
          bonusWallets: balanceVariant === 'long' ? [{ currency: 'CNY', balance: '98765432109876543210.123456789012' }, { currency: 'USD', balance: '1.234567890123456789e-20' }] : [{ currency: 'CNY', balance: '2.5' }], topUpURL: 'https://platform.deepseek.com/top_up',
        } : { status: balanceVariant === 'signed-out' ? 'signed-out' : balanceVariant === 'nonofficial' ? 'unsupported' : 'unavailable' },
      }
    case 'session.fork':
      forkRequests.push({ ...frame.payload })
      forkedSessionPresent = true
      return { v: 1, type: 'ok', id, result: { sessionId: 'forked-child' } }
    case 'workspace.list':
      // The host's own workspace registry, which is not the session list: a
      // session outlives the workspace it was created in, so a phone that
      // grouped on the working directory drew rows for workspaces that had been
      // deleted. `deleted-workspace` deliberately has a session and no
      // workspace, so a test can tell "filtered by the host's list" from
      // "grouped by cwd" -- on the session list *and* in the new-session picker.
      //
      // `fresh` deliberately holds no sessions: it is on the computer's sidebar, so
      // it has to be on the phone's list and in the count the refresh sheet
      // reports. `complete` is the host saying so -- without it the phone may
      // only add, which is what kept deleted workspaces on screen.
      return {
        v: 1,
        type: 'ok',
        id,
        result: {
          items: [
            {
              workspaceId: 'ws-demo',
              path: SESSION.cwd,
              title: 'demo',
              // Archived sessions leave the workspace's membership as well as
              // the session list. The host hides them from both, so a phone
              // that trusted only one would draw a row under a workspace that
              // says it holds nothing.
              sessionIds: [
                SESSION.sessionId,
                ...createdSessions.filter((c) => c.cwd === SESSION.cwd).map((c) => c.sessionId),
                // Both extra rows are members of the workspace on the host:
                // the operator's fork belongs there, and the delegated child is
                // filed under it too. The phone has to draw exactly one of
                // them, which makes "filtered by membership" wrong and
                // "filtered by origin" the only reading that fits.
                ...forkedSessions().map((session) => session.sessionId),
              ].filter((id) => !archivedSessionIds.has(id)),
            },
            { workspaceId: 'ws-fresh', path: '/Users/you/projects/fresh', title: 'fresh', sessionIds: [] },
          ],
          complete: true,
        },
      }
    case 'file.stat':
      // The other direction of `upload.*`: what the phone needs before it pays
      // for a document's bytes. Only the delivered fixture answers; anything
      // else is refused exactly as the real host refuses a path outside the
      // session's workspace.
      const statFile = deliveredFileByPath(frame.payload?.path)
      if (statFile === null) {
        return {
          v: 1,
          type: 'error',
          id,
          error: { code: 'FILE_UNKNOWN', message: 'no such file in this fixture' },
        }
      }
      return {
        v: 1,
        type: 'ok',
        id,
        result: {
          path: statFile.path,
          name: statFile.path.split('/').pop(),
          byteSize: statFile.body.length,
          modifiedAt: 1_760_000_000_000,
          mediaType: statFile.mediaType,
          previewable: true,
        },
      }
    case 'file.read': {
      const readFile = deliveredFileByPath(frame.payload?.path)
      if (readFile === null) {
        return {
          v: 1,
          type: 'error',
          id,
          error: { code: 'FILE_UNKNOWN', message: 'no such file in this fixture' },
        }
      }
      const body = readFile.body
      const offset = Math.max(0, Number(frame.payload?.offset ?? 0))
      const length = Math.max(0, Math.min(Number(frame.payload?.length ?? 0), body.length - offset))
      const slice = body.subarray(offset, offset + length)
      return {
        v: 1,
        type: 'ok',
        id,
        result: {
          offset,
          length: slice.length,
          byteSize: body.length,
          data: slice.toString('base64'),
          eof: offset + slice.length >= body.length,
        },
      }
    }
    case 'session.list':
      // Two sessions, one of them in a directory `workspace.list` does not
      // mention, so a test can tell "filtered by the host's workspace list"
      // apart from "grouped by working directory".
      return {
        v: 1,
        type: 'ok',
        id,
        result: {
          items: [
            ...createdSessions
              .filter((c) => !archivedSessionIds.has(c.sessionId))
              .map(({ prompts, ...row }) => row),
            // An archived session is gone from the list, exactly as an archived
            // one is gone from the workspace that held it.
            ...(archivedSessionIds.has(SESSION.sessionId) || hideSessionFromList
              ? []
              : [{ ...SESSION, running: sessionRunning }]),
            ...(archivedSessionIds.has(ORPHANED_SESSION.sessionId) ? [] : [ORPHANED_SESSION]),
            // A forked conversation and a delegated child, both optional. The
            // fork is a top-level session with a parent and no `origin`; the
            // subagent is the same parent *with* the host's mark. They are
            // absent by default so every other suite measures exactly the
            // fixture it measured before.
            ...forkedSessions().filter((session) => !archivedSessionIds.has(session.sessionId)),
          ],
        },
      }
    case 'usage.overview':
      // What the home page's six readings are folded from. Small and exact so
      // a UI test can assert the figures, and shaped like the host's: the
      // kernel already merged every agent into one row per day.
      return {
        v: 1,
        type: 'ok',
        id,
        result: {
          sessions: 3,
          days: [
            {
              date: '2026-10-31',
              messages: 12,
              inputTokens: 1200,
              outputTokens: 800,
              hours: [...Array(24)].map((_, hour) => (hour === 10 ? 5 : hour === 14 ? 7 : 0)),
              models: [{ model: 'deepseek-v4.1', messages: 12, inputTokens: 1200, outputTokens: 800 }],
            },
            {
              date: '2026-11-01',
              messages: 8,
              inputTokens: 600,
              outputTokens: 400,
              hours: [...Array(24)].map((_, hour) => (hour === 14 ? 8 : 0)),
              models: [{ model: 'deepseek-v4.1', messages: 8, inputTokens: 600, outputTokens: 400 }],
            },
          ],
        },
      }
    case 'interactions.pending':
      return {
        v: 1,
        type: 'ok',
        id,
        result: withPending ? { approvals: [APPROVAL], questions: [QUESTION] } : { approvals: [], questions: [] },
      }
    case 'session.stats':
      // A frame per session, because the app draws one session at a time out of
      // one view: a title that is the same for both cannot show whether the
      // figures on screen belong to the session they were read for.
      // A session the phone started has no figures yet: a frame with nothing
      // in it, which is what a real host answers for a session that has not run.
      if (createdSessions.some((c) => c.sessionId === frame.payload?.sessionId)) {
        return {
          v: 1,
          type: 'ok',
          id,
          result: {
            sessionId: frame.payload.sessionId,
            asOfSeq: 1,
            stats: {
              title: 'Started from the phone',
              tokenUsage: null,
              cacheHit: null,
              context: null,
              stats: null,
              model: null,
              permissionPreset: null,
            },
          },
        }
      }
      if (frame.payload?.sessionId === ORPHANED_SESSION.sessionId) {
        return {
          v: 1,
          type: 'ok',
          id,
          result: {
            sessionId: ORPHANED_SESSION.sessionId,
            asOfSeq: 910,
            stats: {
              title: 'Orphan session',
              tokenUsage: null,
              cacheHit: null,
              context: null,
              stats: null,
              model: null,
              permissionPreset: null,
            },
          },
        }
      }
      // The forked conversation's title. This is what makes the row findable
      // by a name rather than by a directory-and-id fallback: the phone learns
      // a session's title from this frame, one request per drawn row, so the
      // title arriving is itself evidence the row was built and drawn.
      if (frame.payload?.sessionId === FORKED_SESSION.sessionId) {
        return {
          v: 1,
          type: 'ok',
          id,
          result: {
            sessionId: FORKED_SESSION.sessionId,
            asOfSeq: 5,
            stats: {
              title: 'Forked session',
              tokenUsage: null,
              cacheHit: null,
              context: null,
              stats: null,
              model: null,
              permissionPreset: null,
            },
          },
        }
      }
      // The delegated child answers without a title. It should never be asked:
      // a row the sidebar filters out is never drawn, and titles are fetched
      // for drawn rows. Answering anyway keeps a fixture that leaked one from
      // pretending it is a conversation with a name.
      if (frame.payload?.sessionId === SUBAGENT_SESSION.sessionId) {
        return {
          v: 1,
          type: 'ok',
          id,
          result: {
            sessionId: SUBAGENT_SESSION.sessionId,
            asOfSeq: 1,
            stats: {
              title: null,
              tokenUsage: null,
              cacheHit: null,
              context: null,
              stats: null,
              model: null,
              permissionPreset: null,
            },
          },
        }
      }
      // The cold shape: the same frame with every projection that needs a warm
      // agent left empty. See `statsVariant`.
      if (statsVariant === 'cold') {
        return {
          v: 1,
          type: 'ok',
          id,
          result: {
            sessionId: SESSION.sessionId,
            asOfSeq: 17,
            stats: {
              title: null,
              tokenUsage: {
                uncachedInputTokens: 12_480,
                outputTokens: 3_712,
                cacheReadTokens: 180_320,
                cacheWriteTokens: 4_096,
                billedInputTokens: 196_896,
              },
              cacheHit: null,
              context: null,
              stats: null,
              model: null,
              // Not a projection that needs a warm agent: the preset is the
              // session's own, so even the cold answer keeps saying which one
              // is in force after `session.permission.set` changed it.
              permissionPreset,
            },
          },
        }
      }
      // Field names and nesting copied from the fixture recorded off a live
      // host. The first version of this used plausible-looking names that the
      // client could not decode, so the usage screen silently rendered "no
      // usage yet" and the UI test for it failed -- which is how the mistake
      // was found rather than shipped.
      return {
        v: 1,
        type: 'ok',
        id,
        result: {
          sessionId: SESSION.sessionId,
          asOfSeq: 17,
          stats: {
            title: 'Mock session',
            tokenUsage: {
              uncachedInputTokens: 12_480,
              outputTokens: 3_712,
              cacheReadTokens: 180_320,
              cacheWriteTokens: 4_096,
              billedInputTokens: 196_896,
            },
            // A bare number, no percent sign: the host formats it that way and the
            // app appends the symbol. Returning '92%' here made the app render
            // '92%%', which the test caught.
            cacheHit: { ratio: 0.92, displayPercent: '92' },
            context: {
              window: 128_000,
              pressureTokens: 41_000,
              projectedTokens: 44_500,
              percent: 35,
              breakdown: { systemTokens: 1_455, toolsTokens: 5_157, messageTokens: 34_388 },
            },
            stats: {
              turns: 6,
              steps: 14,
              llmMs: 48_200,
              toolMs: 6_100,
              ttftMs: 640,
              decodeTokensPerSecond: 58,
            },
            model: {
              lastUsed: {
                provider: 'deepseek-official',
                model: 'deepseek-flash',
                reasoningEffort: 'high',
              },
              next: null,
            },
            permissionPreset,
          },
        },
      }
    case 'model.catalog':
      // Copied from the real catalog. The first version invented `low/medium/high`
      // efforts; the host offers `off/low/high/max`, so the picker was being
      // tested against options that do not exist.
      //
      // The second instance offers a provider the first one has never heard of,
      // and no DeepSeek at all. A catalogue is read once per connection and kept
      // in the app, so a phone that switches computers without forgetting the first
      // one's catalogue draws models this machine does not have -- which is only
      // visible if the two machines disagree about what they offer.
      return {
        v: 1,
        type: 'ok',
        id,
        result: SECOND_IDENTITY
          ? {
              default: { provider: 'moonshot', model: 'kimi-k2', reasoningEffort: 'high' },
              providers: [
                {
                  id: 'moonshot',
                  name: 'Moonshot',
                  models: [
                    {
                      id: 'kimi-k2',
                      name: 'Kimi-K2',
                      defaultEffort: 'high',
                      efforts: [
                        { id: 'off', name: 'Off', description: 'Use for simple tasks.' },
                        { id: 'high', name: 'High', description: 'The default balance.' },
                      ],
                    },
                  ],
                },
              ],
              failures: [],
            }
          : {
              default: { provider: 'deepseek-official', model: 'deepseek-flash', reasoningEffort: 'high' },
              providers: [
                {
                  id: 'deepseek-official',
                  name: 'DeepSeek',
                  models: [
                    {
                      id: 'deepseek-flash',
                      name: 'DeepSeek-V41-Flash',
                      defaultEffort: 'high',
                      efforts: [
                        { id: 'off', name: 'Off', description: 'Use for simple tasks that do not need reasoning.' },
                        { id: 'low', name: 'Low', description: 'Prefer for routine or latency-sensitive tasks.' },
                        { id: 'high', name: 'High', description: 'The default balance for most tasks.' },
                        { id: 'max', name: 'Max', description: 'Reserve for the hardest quality-first tasks.' },
                      ],
                    },
                    {
                      id: 'deepseek-v4-pro',
                      name: 'DeepSeek-V4-Pro',
                      description: 'Stronger agentic coding at higher cost.',
                      defaultEffort: 'high',
                      efforts: [
                        { id: 'off', name: 'Off', description: 'Use for simple tasks.' },
                        { id: 'high', name: 'High', description: 'The default balance.' },
                      ],
                    },
                  ],
                },
              ],
              failures: [{ id: 'openrouter', name: 'OpenRouter', message: 'not signed in' }],
            },
      }
    case 'permissions.catalog':
      return {
        v: 1,
        type: 'ok',
        id,
        result: {
          defaultPreset: 'workspace-write',
          defaults: [],
          options: [
            { value: 'read-only', name: 'Read only', description: 'Can look, cannot touch.' },
            { value: 'workspace-write', name: 'Workspace write', description: 'Writes inside the workspace.' },
            { value: 'danger-full-access', name: 'Full access', description: 'Unrestricted access to this machine.' },
          ],
        },
      }
    case 'session.permission.set': {
      // The switch the permission picker makes. The host is the authority, so
      // the answer is a `commandResult` -- success or the host's refusal -- and
      // the fixture remembers an accepted preset so the next `session.stats`
      // reports it. A test then has something to observe beyond the tick the
      // picker drew: what the host will go on saying.
      const preset = frame.payload?.preset
      const target = frame.payload?.sessionId
      if (!PERMISSION_PRESETS.includes(preset)) {
        return {
          v: 1,
          type: 'error',
          id,
          code: 'INVALID_INPUT',
          message: `unknown permission preset ${JSON.stringify(preset)}`,
        }
      }
      const created = createdSessions.find((session) => session.sessionId === target)
      if (target !== SESSION.sessionId && created === undefined) {
        return { v: 1, type: 'error', id, code: 'REMOTE_ERROR', message: `unknown session ${target}` }
      }
      if (created !== undefined) created.permissionPreset = preset
      else permissionPreset = preset
      console.log('mock: permission preset ->', preset, 'for', target)
      return {
        v: 1,
        type: 'ok',
        id,
        result: { commandResult: { kind: 'success', text: `permission preset is now ${preset}` } },
      }
    }
    case 'session.archive': {
      // Archive is the host taking a session off its two lists without deleting
      // the log. A running session is refused by the real host unless the caller
      // asks it to be stopped as well; the fixture answers the call the phone
      // makes in 0.9.4, which is the non-destructive one, so it accepts and the
      // tests can observe both lists agreeing.
      const sessionId = frame.payload?.sessionId
      const known = sessionId === SESSION.sessionId
        || sessionId === ORPHANED_SESSION.sessionId
        || createdSessions.some((session) => session.sessionId === sessionId)
      if (!known) {
        return { v: 1, type: 'error', id, code: 'REMOTE_ERROR', message: `unknown session ${sessionId}` }
      }
      archivedSessionIds.add(sessionId)
      console.log('mock: archived ->', sessionId, '| stopActivity', frame.payload?.stopActivity === true)
      return { v: 1, type: 'ok', id, result: { archived: true } }
    }
    case 'session.model.set': {
      // The host's real answer, which the mock did not send at all until a test
      // needed to tell a switch that worked from one that did not. `?fail=` is
      // how a refusal is produced; this is what agreement looks like, and its
      // absence is why every model switch on this fixture used to fail to decode
      // with nobody noticing.
      const selected = {
        provider: frame.payload?.provider ?? 'deepseek-official',
        model: frame.payload?.model ?? 'deepseek-flash',
        reasoningEffort: frame.payload?.reasoningEffort ?? null,
      }
      modelSets.push(selected)
      console.log('mock: model set ->', JSON.stringify(selected))
      return {
        v: 1,
        type: 'ok',
        id,
        result: { sessionId: frame.payload?.sessionId ?? SESSION.sessionId, selected },
      }
    }
    case 'session.create': {
      const cwd = typeof frame.payload?.cwd === 'string' ? frame.payload.cwd : SESSION.cwd
      const created = {
        ...SESSION,
        sessionId: `session-mock-created-${createdSessions.length + 1}`,
        cwd,
        updatedAt: Date.now(),
        running: false,
        prompts: [],
      }
      createdSessions.push(created)
      console.log('mock: session created ->', created.sessionId, cwd)
      return { v: 1, type: 'ok', id, result: { sessionId: created.sessionId } }
    }
    case 'session.prompt': {
      const text = typeof frame.payload?.text === 'string' ? frame.payload.text : ''
      const created = createdSessions.find((s) => s.sessionId === frame.payload?.sessionId)
      if (created !== undefined) {
        if (text !== '') created.prompts.push(text)
        created.updatedAt = Date.now()
        console.log('mock: prompt for', created.sessionId, '->', JSON.stringify(text))
        return {
          v: 1,
          type: 'ok',
          id,
          result: { accepted: true, requestId: frame.payload?.requestId ?? 'mock-request' },
        }
      }
      if (text !== '') {
        sentPrompts.push(text)
        sentPromptModes.push(frame.payload?.mode === 'steer' ? 'steer' : 'queue')
      }
      console.log('mock: prompt received ->', JSON.stringify(text), '| log now', sentPrompts.length)
      return {
        v: 1,
        type: 'ok',
        id,
        result: { accepted: true, requestId: frame.payload?.requestId ?? 'mock-request' },
      }
    }
    case 'session.activity': {
      // The paid full-detail feed: only the running turn's compact process
      // details. Free accounts never ask, so this is only reachable from a paid
      // launch -- but the mock answers it for anyone, like a real host would.
      const payload = frame.payload ?? {}
      const now = Date.now()
      const requested = Number(payload.maxEntries)
      const cap = Number.isFinite(requested) && requested > 0 ? Math.min(requested, 300) : 200
      const created = createdSessions.find((s) => s.sessionId === payload.sessionId)
      const sessionId = created !== undefined
        ? created.sessionId
        : payload.sessionId ?? SESSION.sessionId
      // The same running turn the conversation fixture draws: turn 4 while the
      // session runs with nothing sent since, otherwise the newest prompt's
      // turn. Nothing running -- `/session?running=0` -- is turn:null.
      const runningTurn = created !== undefined
        ? (sessionRunning && created.prompts.length > 0 ? created.prompts.length : null)
        : (sessionRunning ? (sentPrompts.length === 0 ? 4 : 4 + sentPrompts.length) : null)

      // A backwards read: the page before `beforeSeq`, for one turn. Counted
      // whether or not it is well formed, because the count is about what the
      // phone asked for, not about what it was told.
      if (typeof payload.beforeSeq === 'number') {
        activityPageRequests += 1
        const beforeSeq = payload.beforeSeq
        if (typeof payload.turn !== 'number') {
          // The protocol makes the turn mandatory here: a page can be cut
          // through a turn by definition, so beforeSeq without one cannot say
          // whose older rows are wanted.
          return {
            v: 1,
            type: 'error',
            id,
            code: 'MALFORMED_FRAME',
            message: 'session.activity with beforeSeq needs the turn it pages back through',
          }
        }
        const turn = payload.turn
        if (activityLongCount > 0 && runningTurn !== null && turn === runningTurn) {
          // The long fixture's log is flat: every row belongs to the running
          // turn. This answer is the whole remainder of the turn behind
          // `beforeSeq`, trimmed only by the protocol's own 300-row ceiling --
          // a real host would read a log page of its own size, and this fixture
          // deliberately makes that page the rest of the log so a test reaches
          // the turn's beginning in one round trip and can then prove the walk
          // stops rather than paging through a wall of fixture.
          const log = longActivityEntries(activityLongCount, runningTurn)
          const older = log.filter((entry) => entry.seq < beforeSeq).slice(-300)
          const oldestSeq = older.length > 0 ? older[0].seq : null
          const hasOlderRecords = older.length > 0 && log[0].seq < older[0].seq
          console.log(
            'mock: activity page before', beforeSeq,
            'turn', turn, '->', older.length, 'entries',
            '| hasMore', hasOlderRecords,
          )
          return {
            v: 1,
            type: 'ok',
            id,
            result: {
              sessionId,
              asOfSeq: 27 + sentPrompts.length,
              turn: runningTurn,
              entries: older.map(({ turn: _turn, ...entry }) => entry),
              // Widened: the log has older records *and* this page contributed
              // rows of the turn. Empty, or the turn's beginning, stops the
              // walk.
              hasMore: hasOlderRecords,
              oldestSeq,
            },
          }
        }
        // The default fixture holds its whole eight-row log in the forward
        // answer, so there is nothing behind it: an empty page with `hasMore`
        // false is the host saying the walk is over.
        return {
          v: 1,
          type: 'ok',
          id,
          result: {
            sessionId,
            asOfSeq: 27 + sentPrompts.length,
            turn: runningTurn,
            entries: [],
            hasMore: false,
            oldestSeq: null,
          },
        }
      }

      // A forward read: the newest window of the running turn.
      activityPolls += 1
      if (runningTurn === null) {
        return {
          v: 1,
          type: 'ok',
          id,
          result: {
            sessionId,
            asOfSeq: 27 + sentPrompts.length,
            turn: null,
            entries: [],
            hasMore: false,
            oldestSeq: null,
          },
        }
      }
      if (activityLongCount > 0) {
        const log = longActivityEntries(activityLongCount, runningTurn)
        const window = Math.min(cap, LONG_ACTIVITY_FORWARD, log.length)
        const entries = log.slice(log.length - window)
        return {
          v: 1,
          type: 'ok',
          id,
          result: {
            sessionId,
            asOfSeq: 27 + sentPrompts.length,
            turn: runningTurn,
            entries: entries.map(({ turn: _turn, ...entry }) => entry),
            hasMore: entries.length < log.length,
            oldestSeq: entries.length > 0 ? entries[0].seq : null,
          },
        }
      }
      const count = Math.min(ACTIVITY_ENTRIES.length, 3 + activityPolls)
      let entries = ACTIVITY_ENTRIES.slice(0, count).map((entry, index) => ({
        ...entry,
        seq: (created !== undefined ? 0 : 27) + 28 + index,
        at: now - (count - index) * 900,
      }))
      const hasMore = entries.length > cap
      if (hasMore) entries = entries.slice(entries.length - cap)
      return {
        v: 1,
        type: 'ok',
        id,
        result: {
          sessionId,
          asOfSeq: 27 + sentPrompts.length,
          turn: runningTurn,
          entries,
          hasMore,
          // The smallest position in this page. The default fixture's log is
          // exactly these rows, so there is nothing older to reach; the value
          // is here because the contract has the field on every answer.
          oldestSeq: entries.length > 0 ? entries[0].seq : null,
        },
      }
    }
    case 'session.stream':
      return {
        v: 1,
        type: 'ok',
        id,
        result: {
          sessionId: frame.payload?.sessionId ?? SESSION.sessionId,
          turn: 4,
          state: stateStreamEntries.length === 0 ? 0 : stateStreamEntries[stateStreamEntries.length - 1].state,
          interval: stateStreamEntries.length === 0 ? 0 : stateStreamEntries[stateStreamEntries.length - 1].interval,
          textSeq: 0,
          truncated: false,
          entries: stateStreamEntries.map((entry) => ({ ...entry })),
        },
      }
    case 'session.messages':
      if (longReaderFixture) {
        const records = []
        let seq = 0
        for (let turn = 1; turn <= 24; turn += 1) {
          const rec = (type, data) => ({ type: 'event', event: { type, seq: seq++, time: Date.now() - (25 - turn) * 60000, data } })
          records.push(rec('turn/start', { turn }), rec('user/message', { role: 'user', content: [{ type: 'text', text: markdownReaderFixture ? performanceMarkdown(turn, 'user') : `Reader prompt ${turn}. ` + 'Earlier conversation body. '.repeat(10) }], source: { kind: 'user' } }), rec('assistant/message', { turn, message: { role: 'assistant', content: [{ type: 'text', text: markdownReaderFixture ? performanceMarkdown(turn, 'assistant') : `Reader answer ${turn}. ` + 'Stable visible message anchor. '.repeat(10) }] } }), rec('turn/end', { turn, reason: { kind: 'completed' }, mizarTokenUsage: { totalTokens: 12345 }, mizarBranchUnavailable: false }))
        }
        return { v: 1, type: 'ok', id, result: { sessionId: frame.payload?.sessionId, throughSeq: seq - 1, hasMore: false, records } }
      }
      // A requested page the transport cannot carry. The host's own answer to
      // this is `RESPONSE_TOO_LARGE` rather than a truncated page or a closed
      // socket, and the client's answer is to ask for less -- so a page limit
      // is what makes that reachable in a test.
      if (typeof frame.payload?.maxMessages === 'number' && frame.payload.maxMessages > pageLimit) {
        return {
          v: 1,
          type: 'error',
          code: 'RESPONSE_TOO_LARGE',
          message: `the answer to ${id} is 1400KB, too large to deliver`,
          retryable: false,
          id,
        }
      }
      const created = createdSessions.find((s) => s.sessionId === frame.payload?.sessionId)
      if (created !== undefined) {
        console.log('mock: messages for', created.sessionId, JSON.stringify(frame.payload))
        let seq = 0
        const now = Date.now()
        const record = (type, data) => {
          seq += 1
          return { type: 'event', event: { type, seq, time: now - (100 - seq) * 1000, data } }
        }
        return {
          v: 1,
          type: 'ok',
          id,
          result: {
            sessionId: created.sessionId,
            asOfSeq: created.prompts.length * 3,
            hasMore: false,
            records: created.prompts.flatMap((text, index) => [
              record('turn/start', { turn: index + 1 }),
              record('step/start', { turn: index + 1, step: 1 }),
              record('user/message', {
                content: [{ type: 'text', text }],
                source: { kind: 'user' },
                role: 'user',
                id: `${created.sessionId}-m${index + 1}`,
              }),
            ]),
          },
        }
      }
      if (frame.payload?.sessionId === FORKED_SESSION.sessionId) {
        console.log('mock: messages for', FORKED_SESSION.sessionId, JSON.stringify(frame.payload))
        return {
          v: 1,
          type: 'ok',
          id,
          result: forkedMessages(frame.payload?.beforeSeq ?? null),
        }
      }
      if (frame.payload?.sessionId === ORPHANED_SESSION.sessionId) {
        return {
          v: 1,
          type: 'ok',
          id,
          result: orphanMessages(frame.payload?.beforeSeq ?? null),
        }
      }
      // Record shapes copied from a real session log, in the shape the host now
      // sends: **summary-only history**. For each finished turn, the operator's
      // prompt, the turn's `turn/start`, its `turn/end`, one `step/start` per
      // step, and only the **last** `assistant/message` of the turn -- the
      // model's summary of it. The per-step narration, the tool calls, the
      // streaming attempts and the partial answer of a running turn are not sent
      // at all; the change was bandwidth-driven, because the full history was
      // too heavy through the relay.
      //
      // The *order* the records are written in is the host's, which is not the
      // order a reader assumes: inside a turn it is `turn/start`, then
      // `step/start`, then the operator's `user/message`. See the note on turn 1
      // below, which is where the measurement is written down.
      //
      // This fixture used to carry the old full-fidelity log -- streamed deltas,
      // a message per step, tool activity -- and that made the suite a test of a
      // transport the app no longer talks to. It is the app's fixture, so it
      // serves what the app will really see.
      //
      // Four turns, chosen for what they pin:
      //
      //   turn 1   finished, three steps, one summary at the end of them. The
      //            step count comes from the markers, not from the messages: had
      //            it been counted from messages it would read "1 steps".
      //   turn 2   ended `error` with nothing to show for it. That is the shape
      //            a turn takes on a host with no provider credential, and the
      //            one where a bare "未完成" row would leave the operator to
      //            guess what happened.
      //   turn 3   asked for, ended badly, and it *did* answer: the row keeps
      //            its warning and the answer stays.
      //   turn 4   **no `turn/end`**, and two steps with no answer after them.
      //            The running shape, and the one reported broken: the reader
      //            used to invent an end time from the last record it held, so a
      //            live turn was drawn as "已完成，用时 10 秒" with the seconds
      //            measuring the age of the newest message.
      const now = Date.now()
      // Numbered as they are built, so a record's `seq` and its position agree.
      // The client orders a conversation by `seq` where two records share a
      // millisecond, and hand-written numbers that drifted from the array would
      // be a fixture that tests something the host never sends.
      let counter = -1
      const record = (type, data) => {
        counter += 1
        return {
          type: 'event',
          event: {
            type,
            seq: counter,
            time: now + clockSkewMs - (20 - counter) * 1000,
            data: type === 'turn/end' ? {
              ...data,
              mizarTokenUsage: { totalTokens: data.turn === 1 ? 12345 : data.turn === 3 ? 67890 : 20 },
              mizarBranchUnavailable: data.reason?.kind === 'error',
            } : data,
          },
        }
      }
      return {
        v: 1,
        type: 'ok',
        id,
        result: {
          sessionId: SESSION.sessionId,
          asOfSeq: 27 + sentPrompts.length,
          hasMore: false,
          records: [
            record('permission/preset', { preset: 'workspace-write' }),

            // **The order inside a turn is the host's, and it is not the obvious
            // one.** Read off the durable log of a real session and confirmed on
            // the live wire: `turn/start` first, then `step/start`, and the
            // operator's `user/message` *after* both -- carrying no `data.turn`
            // of its own:
            //
            //     seq=92 turn/start {"turn":11}
            //     seq=94 step/start {"turn":11,"step":1}
            //     seq=95 user/message {…"source":{"kind":"user"}}
            //
            // This fixture used to write the prompt *before* its `turn/start`,
            // which is the order a reader assumes and not the one the host
            // sends. The suite passed while the app lost the newest turn: a
            // prompt written after its own `turn/start` cannot be paired by a
            // rule that only looks for a *later* turn, so a running turn -- for
            // which the host sends no `assistant/message` to claim the prompt
            // with -- held no prompt at all, and the row drawn over a working
            // agent read "已完成". The prompt is therefore written where the
            // host writes it, in every turn below, including the finished ones.

            // Turn 1: asked for, finished in three steps. The count comes from
            // the three markers, not from the messages -- the turn carries
            // **one** message, its summary, and a count taken from messages
            // would read "1 steps".
            record('turn/start', { turn: 1 }),
            record('step/start', { turn: 1, step: 1 }),
            record('step/end', { turn: 1, step: 1 }),
            record('step/start', { turn: 1, step: 2 }),
            record('step/end', { turn: 1, step: 2 }),
            record('step/start', { turn: 1, step: 3 }),
            record('user/message', {
              content: [{ type: 'text', text: MAIN_PROMPT }],
              source: { kind: 'user', rpcId: 'r1' },
              role: 'user',
              id: 'm1',
            }),
            // The model's *last* message of the turn, and the only one sent:
            // the three steps above are three markers and nothing else.
            record('assistant/message', {
              turn: 1,
              step: 3,
              message: {
                role: 'assistant',
                content: [{ type: 'text', text: MAIN_ANSWER }],
              },
            }),
            record('turn/end', {
              turn: 1,
              reason: { kind: 'completed' },
              ...(deliverablesPresent ? {
                mizarDeliverables: [{
                  path: deliveredFile().path,
                  description: deliveredFile().description,
                }],
              } : {}),
            }),

            // Turn 2: **ended badly with nothing to show for it**. That is the
            // shape a turn takes on a host with no provider credential -- the
            // model never ran -- and the shape that has to be drawn as a failure
            // rather than as an empty screen. It carries one marker and no
            // answer at all: the summary-only transport sends no streaming
            // attempt, so the reason on `turn/end` is the only thing left to
            // report it with.
            record('turn/start', { turn: 2 }),
            record('step/start', { turn: 2, step: 1 }),
            record('user/message', {
              content: [{ type: 'text', text: 'Now add a case for trailing commas.' }],
              // `source.kind` is not decoration: the reader shows a
              // `user/message` only when it says a person wrote it, because DSH
              // sends its own injected context through the same event. A fixture
              // without it is a prompt that never appears -- and, worse, a turn
              // with no prompt, which is what the reader folds into the turn above
              // it. Omitting it here made one turn out of three.
              source: { kind: 'user' },
              role: 'user',
              id: 'm2',
            }),
            record('turn/end', { turn: 2, reason: { kind: 'error' } }),

            // Turn 3: asked for, ended badly, and it *did* answer. The row keeps
            // its warning and the answer stays -- a failure card belongs to a
            // turn that produced nothing, not to one that produced something and
            // then stopped.
            record('turn/start', { turn: 3 }),
            record('step/start', { turn: 3, step: 1 }),
            record('step/start', { turn: 3, step: 2 }),
            record('user/message', {
              content: [{ type: 'text', text: 'And check the tokenizer.' }],
              source: { kind: 'user' },
              role: 'user',
              id: 'm3',
            }),
            record('assistant/message', {
              turn: 3,
              step: 2,
              message: {
                role: 'assistant',
                content: [{ type: 'text', text: 'Two files changed, and it still fails.' }],
              },
            }),
            record('turn/end', { turn: 3, reason: { kind: 'error' } }),

            // Turn 4: the running one. No `turn/end`, and no
            // `assistant/message` either -- a turn still going gets no summary,
            // because a half-written answer is not one. Its two markers are all
            // the reader has of it, which is why the count matters here more
            // than anywhere else.
            //
            // The prompt is written inside the turn, after the markers, exactly
            // as the host writes it -- and this is the turn where getting that
            // wrong cost the screen its running row: with the prompt held for a
            // turn that never came, this turn held no prompt, the group holding
            // it sorted after this one, and the fold absorbed the turn into that
            // group and lost both the number and the start the "深度求索中，用时"
            // row is drawn from.
            record('turn/start', { turn: 4 }),
            record('step/start', { turn: 4, step: 1 }),
            record('step/start', { turn: 4, step: 2 }),
            record('user/message', {
              content: [{ type: 'text', text: 'And run the whole suite.' }],
              source: { kind: 'user' },
              role: 'user',
              id: 'm4',
            }),

            // The end of turn 4, but only while the session has stopped and
            // nothing has been sent since. The fixture has to be consistent
            // about what "running" means: the session list says whether a turn
            // is executing, and a page that still showed turn 4 open after the
            // session reported it stopped would make "the running row goes
            // away" untestable -- the host would be telling the app two
            // different things. Flipped at runtime by `/session?running=0`,
            // which is the endpoint the report's own reproduction uses: the turn
            // finishes under the open conversation and the phone has to notice
            // without a tap. A prompt sent afterwards supersedes turn 4, so it
            // ends even while the fixture keeps the session running.
            ...(sessionRunning && sentPrompts.length === 0
              ? []
              : [record('turn/end', { turn: 4, reason: { kind: 'completed' } })]),

            // Anything the client has sent since, appended the way a host would:
            // each prompt opens a turn of its own, in the host's own record
            // order -- `turn/start`, then its marker, then the operator's
            // message. The newest of those turns is the one the session's
            // `running` flag is about, so stopping the fixture ends exactly the
            // turn the operator is watching. A prompt with no turn after it
            // would be the state every message is in for a moment, and would
            // leave a test that sends a prompt with nothing running to watch.
            ...sentPrompts.flatMap((text, index) => {
              const turn = 5 + index
              return [
                record('turn/start', { turn }),
                record('step/start', { turn, step: 1 }),
                record('user/message', {
                  content: [{ type: 'text', text }],
                  source: { kind: 'user' },
                  role: 'user',
                  id: `sent-${index}`,
                }),
                // Every earlier prompt ended when the next one was sent; the
                // newest follows the session's flag.
                ...(index < sentPrompts.length - 1 || !sessionRunning
                  ? [record('turn/end', { turn, reason: { kind: 'completed' } })]
                  : []),
              ]
            }),
          ],
        },
      }
    case 'ping':
      // What the real host answers: its own clock.
      return { v: 1, type: 'ok', id, result: { time: Date.now() } }
    case 'approval.answer':
    case 'question.answer':
      return { v: 1, type: 'ok', id, result: { accepted: true } }
    default:
      return { v: 1, type: 'ok', id, result: {} }
  }
}

// MARK: - Account fixture
//
// The account API is served from this same process so a UI test can run the real
// account client against a real HTTP server. Nothing here is a security
// boundary: passwords are compared in the clear and tokens are strings in a Map.
// The three behaviours the tests need are the three the app branches on -- a
// sign-in that succeeds, an invite that makes an account paid, and an App Store
// transaction that makes it paid another way.

/** The account API root. */
const ACCOUNT_PREFIX = '/account/v1'
/** The code that turns an account paid, for the redeem test. */
const INVITE_CODE = 'MOCK-INVITE'
/** How much paid time redeeming the invite adds. */
const INVITE_DAYS = 30
/** The survey the questionnaire test fills in. */
const SURVEY_ID = 'mock-survey'
/** What filling it in pays. */
const SURVEY_DAYS = 7
/** The banner the announcement socket sends on connection. */
const ANNOUNCEMENT = {
  id: 'mock-announcement',
  title: 'Mock announcement',
  body: 'A banner from the fixture relay.',
  symbol: 'megaphone.fill',
  tone: 'info',
  button: { label: 'Open notifications', target: 'notifications' },
  createdAt: Date.now(),
  expiresAt: null,
  active: true,
}
/** The password of the fixture account, for the sign-in test. */
const FIXTURE_PASSWORD = 'mizar-test-password'
/** The product the App Store transaction route accepts. */
const SUBSCRIPTION_PRODUCT = 'me.shirazu.dshmizar.paid.monthly'

/**
 * Accounts by user id, and sessions by bearer token.
 *
 * Recreated by `/reset`, so every test starts signed out and with one known
 * account to sign in to. The fixture account is the one the login test uses; the
 * register test creates its own so the two cannot pass by accident.
 */
let accounts = new Map()
let accountSessions = new Map()
let accountSerial = 0
/** Survey ids each user id has answered. */
let surveyResponses = new Map()
/** How many App Store transactions the fixture has been sent. */
let appStoreTransactions = 0

/** Put the account fixture back to its starting state. */
function resetAccounts() {
  const now = Date.now()
  accounts = new Map()
  accountSessions = new Map()
  accountSerial = 0
  appStoreTransactions = 0
  surveyResponses = new Map()
  const id = '11111111-2222-4333-8444-555555555555'
  accounts.set(id, {
    id,
    username: 'shirazu',
    email: 'shirazu@example.com',
    password: FIXTURE_PASSWORD,
    emailVerified: false,
    grantedPaidUntil: null,
    appStore: null,
    createdAt: now,
    devices: [],
  })
}
resetAccounts()

/**
 * The public user shape, exactly as `dsh-relay`'s `PublicUser` writes it.
 *
 * @param user - the fixture account.
 * @param deviceId - the install id the request came from, so `current` is true.
 * @returns the profile the phone decodes.
 */
function publicUser(user, deviceId) {
  const now = Date.now()
  const appStorePaidUntil = user.appStore?.paidUntil ?? null
  const paidUntil = Math.max(user.grantedPaidUntil ?? 0, appStorePaidUntil ?? 0) || null
  const sources = []
  if ((user.grantedPaidUntil ?? 0) > now) sources.push('invite')
  if ((appStorePaidUntil ?? 0) > now) sources.push('appstore')
  return {
    id: user.id,
    username: user.username,
    email: user.email ?? null,
    emailVerified: user.emailVerified,
    plan: paidUntil !== null && paidUntil > now ? 'paid' : 'free',
    paidUntil,
    paidSources: sources,
    grantedPaidUntil: user.grantedPaidUntil ?? null,
    appStore: user.appStore
      ? {
          paidUntil: appStorePaidUntil,
          productId: SUBSCRIPTION_PRODUCT,
          environment: 'Sandbox',
          autoRenew: true,
          revokedAt: null,
        }
      : null,
    avatar: {
      kind: 'generated',
      colors: ['#5b8def', '#8f6bff', '#2fc7a5'],
      initials: (user.username[0] ?? '?').toUpperCase(),
    },
    apple: user.apple === true,
    createdAt: user.createdAt,
    lastSeenAt: now,
    devices: user.devices.map((device) => ({
      id: device.id,
      name: device.name,
      model: device.model,
      platform: device.platform,
      loginAt: device.loginAt,
      lastSeenAt: device.lastSeenAt,
      current: device.id === deviceId,
    })),
  }
}

/** A fresh bearer token. */
function newAccountToken() {
  accountSerial += 1
  return `mza_mock_${accountSerial}`
}

/** The user behind a request, or `null`. */
function accountFor(request) {
  const header = request.headers['authorization'] ?? ''
  const token = header.replace(/^Bearer\s+/i, '')
  if (!token) return null
  const userId = accountSessions.get(token)
  return userId ? accounts.get(userId) ?? null : null
}

/** Record a device on sign-in, replacing the old record for this install. */
function noteDevice(user, device, now) {
  if (!device || typeof device.id !== 'string') return
  const entry = {
    id: device.id,
    name: String(device.name ?? 'iPhone'),
    model: String(device.model ?? ''),
    platform: String(device.platform ?? 'ios'),
    loginAt: now,
    lastSeenAt: now,
  }
  user.devices = user.devices.filter((existing) => existing.id !== device.id)
  user.devices.push(entry)
}

/** Answer one account route. Returns whether it handled the request. */
function handleAccount(request, response, url) {
  const path = url.pathname
  if (!path.startsWith(ACCOUNT_PREFIX)) return false
  const route = path.slice(ACCOUNT_PREFIX.length)
  const method = request.method ?? 'GET'
  const now = Date.now()

  const answer = (status, body) => {
    response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' })
    response.end(JSON.stringify(body))
  }
  const refusal = (status, code, message) => answer(status, { error: code, message })
  const withBody = (handler) => {
    let body = ''
    request.on('data', (chunk) => { body += chunk })
    request.on('end', () => {
      let parsed
      try { parsed = JSON.parse(body || '{}') } catch { parsed = null }
      if (parsed === null) return refusal(400, 'INVALID_INPUT', 'body was not JSON')
      handler(parsed)
    })
  }

  if (method === 'POST' && route === '/register/start') {
    withBody((parsed) => {
      const username = String(parsed.username ?? '').trim()
      const email = String(parsed.email ?? '').trim().toLowerCase()
      const password = String(parsed.password ?? '')
      if (username.length < 2 || !email.includes('@') || password.length < 8) {
        return refusal(400, 'INVALID_INPUT', 'those details are not acceptable')
      }
      for (const existing of accounts.values()) {
        if (existing.username.toLowerCase() === username.toLowerCase()) {
          return refusal(409, 'USERNAME_TAKEN', 'that username is taken')
        }
        if ((existing.email ?? '').toLowerCase() === email) {
          return refusal(409, 'EMAIL_TAKEN', 'that email already has an account')
        }
      }
      // No account is created here: the mock mirrors the real flow, where the
      // code proves the address before anything is written down.
      answer(200, { email, expiresAt: Date.now() + 600000, resendAfterSeconds: 60 })
    })
    return true
  }

  if (method === 'POST' && route === '/register') {
    withBody((parsed) => {
      const username = String(parsed.username ?? '').trim()
      const email = String(parsed.email ?? '').trim().toLowerCase()
      const password = String(parsed.password ?? '')
      const code = String(parsed.code ?? '').trim()
      if (username.length < 2 || !email.includes('@') || password.length < 8) {
        return refusal(400, 'INVALID_INPUT', 'those details are not acceptable')
      }
      if (!/^\d{6}$/.test(code)) {
        return refusal(428, 'EMAIL_VERIFICATION_REQUIRED', 'request a code with /register/start and send it as "code"')
      }
      for (const existing of accounts.values()) {
        if (existing.username.toLowerCase() === username.toLowerCase()) {
          return refusal(409, 'USERNAME_TAKEN', 'that username is taken')
        }
        if ((existing.email ?? '').toLowerCase() === email) {
          return refusal(409, 'EMAIL_TAKEN', 'that email already has an account')
        }
      }
      const id = crypto.randomUUID()
      const user = {
        id,
        username,
        email,
        password,
        emailVerified: true,
        grantedPaidUntil: null,
        appStore: null,
        createdAt: now,
        devices: [],
      }
      accounts.set(id, user)
      noteDevice(user, parsed.device, now)
      const token = newAccountToken()
      accountSessions.set(token, id)
      answer(200, { token, user: publicUser(user, parsed.device?.id) })
    })
    return true
  }

  if (method === 'POST' && route === '/password/reset/start') {
    withBody(() => {
      // The same answer whether or not the address exists, like the real one.
      answer(200, { ok: true, expiresAt: Date.now() + 600000, resendAfterSeconds: 60 })
    })
    return true
  }

  if (method === 'POST' && route === '/password/reset/complete') {
    withBody((parsed) => {
      const email = String(parsed.email ?? '').trim().toLowerCase()
      const code = String(parsed.code ?? '').trim()
      const password = String(parsed.password ?? '')
      if (!/^\d{6}$/.test(code)) return refusal(400, 'VERIFICATION_INVALID', 'that code is not right')
      if (password.length < 8) return refusal(400, 'INVALID_INPUT', 'those details are not acceptable')
      const user = [...accounts.values()].find((existing) => (existing.email ?? '').toLowerCase() === email)
      if (user === undefined) return refusal(400, 'VERIFICATION_INVALID', 'that code is not right')
      user.password = password
      user.emailVerified = true
      noteDevice(user, parsed.device, now)
      const token = newAccountToken()
      accountSessions.set(token, user.id)
      answer(200, { token, user: publicUser(user, parsed.device?.id) })
    })
    return true
  }

  if (method === 'POST' && route === '/login') {
    withBody((parsed) => {
      const identifier = String(parsed.identifier ?? '').trim().toLowerCase()
      for (const user of accounts.values()) {
        const matches = user.username.toLowerCase() === identifier
          || (user.email ?? '').toLowerCase() === identifier
        if (matches && user.password === String(parsed.password ?? '')) {
          noteDevice(user, parsed.device, now)
          const token = newAccountToken()
          accountSessions.set(token, user.id)
          return answer(200, { token, user: publicUser(user, parsed.device?.id) })
        }
      }
      refusal(401, 'UNAUTHENTICATED', 'wrong username or password')
    })
    return true
  }

  if (method === 'POST' && route === '/apple') {
    withBody((parsed) => {
      // Apple's JWT is not verified here; the fixture accepts anything shaped
      // like one and signs in (or creates) the fixture Apple account. The app's
      // job in the UI test is the nonce hand-off and the token exchange, which
      // this still exercises.
      if (typeof parsed.identityToken !== 'string' || typeof parsed.nonce !== 'string') {
        return refusal(400, 'APPLE_TOKEN_INVALID', 'missing identity token or nonce')
      }
      let user = [...accounts.values()].find((candidate) => candidate.username === 'apple-user')
      if (!user) {
        user = {
          id: crypto.randomUUID(),
          username: 'apple-user',
          email: 'apple@example.com',
          password: null,
          apple: true,
          emailVerified: true,
          grantedPaidUntil: null,
          appStore: null,
          createdAt: now,
          devices: [],
        }
        accounts.set(user.id, user)
      }
      noteDevice(user, parsed.device, now)
      const token = newAccountToken()
      accountSessions.set(token, user.id)
      answer(200, { token, user: publicUser(user, parsed.device?.id) })
    })
    return true
  }

  if (method === 'GET' && route === '/me') {
    const user = accountFor(request)
    if (!user) return refusal(401, 'SESSION_REVOKED', 'that session is gone'), true
    accountSessions.forEach((userId, token) => {
      if (userId === user.id) accountSessions.set(token, user.id)
    })
    return answer(200, { user: publicUser(user, user.devices.at(-1)?.id) }), true
  }

  if (method === 'POST' && route === '/logout') {
    const header = request.headers['authorization'] ?? ''
    accountSessions.delete(header.replace(/^Bearer\s+/i, ''))
    return answer(200, { ok: true }), true
  }

  if (method === 'POST' && route === '/delete') {
    const user = accountFor(request)
    if (!user) return refusal(401, 'UNAUTHENTICATED', 'sign in required'), true
    withBody((parsed) => {
      if (parsed.confirmation !== 'DELETE') {
        return refusal(400, 'INVALID_INPUT', 'confirmation must be DELETE')
      }
      accounts.delete(user.id)
      accountSessions.forEach((userId, token) => {
        if (userId === user.id) accountSessions.delete(token)
      })
      answer(200, { ok: true })
    })
    return true
  }

  if (method === 'POST' && route === '/invite/redeem') {
    const user = accountFor(request)
    if (!user) return refusal(401, 'UNAUTHENTICATED', 'sign in required'), true
    withBody((parsed) => {
      const code = String(parsed.code ?? '').trim()
      if (code !== INVITE_CODE) {
        return refusal(400, 'INVITE_INVALID', 'that invite code is not valid')
      }
      const base = Math.max(now, user.grantedPaidUntil ?? 0)
      user.grantedPaidUntil = base + INVITE_DAYS * 24 * 60 * 60 * 1000
      answer(200, { user: publicUser(user, user.devices.at(-1)?.id) })
    })
    return true
  }

  if (method === 'GET' && route === '/announcements') {
    const user = accountFor(request)
    if (!user) return refusal(401, 'UNAUTHENTICATED', 'sign in required'), true
    answer(200, { announcements: [ANNOUNCEMENT] })
    return true
  }

  if (method === 'GET' && route === '/surveys') {
    const user = accountFor(request)
    if (!user) return refusal(401, 'UNAUTHENTICATED', 'sign in required'), true
    const done = surveyResponses.get(user.id) ?? new Set()
    answer(200, {
      surveys: [
        {
          id: SURVEY_ID,
          title: 'How is 0.9.9?',
          summary: 'Two questions, seven days.',
          rewardDays: SURVEY_DAYS,
          active: true,
          expiresAt: null,
          completed: done.has(SURVEY_ID),
          completedAt: null,
          questions: [
            {
              id: 'rating',
              type: 'single',
              prompt: 'How is it?',
              required: true,
              options: [
                { id: 'good', label: 'Good' },
                { id: 'bad', label: 'Bad' },
              ],
            },
            {
              id: 'used',
              type: 'multi',
              prompt: 'What did you use?',
              required: false,
              options: [
                { id: 'banner', label: 'Banner' },
                { id: 'survey', label: 'Survey' },
              ],
            },
            {
              id: 'note',
              type: 'text',
              prompt: 'Anything else?',
              required: false,
              maxLength: 200,
            },
          ],
        },
      ],
    })
    return true
  }

  if (method === 'POST' && route === '/surveys/submit') {
    const user = accountFor(request)
    if (!user) return refusal(401, 'UNAUTHENTICATED', 'sign in required'), true
    withBody((parsed) => {
      const surveyId = String(parsed.surveyId ?? '')
      if (surveyId !== SURVEY_ID) {
        return refusal(404, 'SURVEY_NOT_FOUND', 'no such survey')
      }
      const done = surveyResponses.get(user.id) ?? new Set()
      if (done.has(SURVEY_ID)) {
        return refusal(409, 'SURVEY_ALREADY_DONE', 'already answered')
      }
      const answers = Array.isArray(parsed.answers) ? parsed.answers : []
      const rating = answers.find((answer) => answer.questionId === 'rating')
      if (!rating || !['good', 'bad'].includes(rating.value)) {
        return refusal(400, 'SURVEY_INVALID_ANSWERS', 'the rating is missing')
      }
      done.add(SURVEY_ID)
      surveyResponses.set(user.id, done)
      const base = Math.max(now, user.grantedPaidUntil ?? 0)
      user.grantedPaidUntil = base + SURVEY_DAYS * 24 * 60 * 60 * 1000
      answer(200, { user: publicUser(user, user.devices.at(-1)?.id), rewardDays: SURVEY_DAYS })
    })
    return true
  }

  if (method === 'POST' && route === '/appstore/transaction') {
    const user = accountFor(request)
    if (!user) return refusal(401, 'UNAUTHENTICATED', 'sign in required'), true
    withBody((parsed) => {
      if (typeof parsed.signedTransaction !== 'string' || parsed.signedTransaction.length === 0) {
        return refusal(400, 'APPSTORE_TOKEN_INVALID', 'missing signed transaction')
      }
      appStoreTransactions += 1
      user.appStore = {
        paidUntil: Math.max(now, user.appStore?.paidUntil ?? 0) + 31 * 24 * 60 * 60 * 1000,
        productId: SUBSCRIPTION_PRODUCT,
        environment: 'Sandbox',
        autoRenew: true,
        revokedAt: null,
      }
      answer(200, { user: publicUser(user, user.devices.at(-1)?.id) })
    })
    return true
  }

  if (method === 'POST' && route === '/appstore/sync') {
    const user = accountFor(request)
    if (!user) return refusal(401, 'UNAUTHENTICATED', 'sign in required'), true
    withBody((parsed) => {
      const transactions = Array.isArray(parsed.signedTransactions) ? parsed.signedTransactions : []
      if (transactions.length === 0 || transactions.length > 100) {
        return refusal(400, 'INVALID_INPUT', 'expected 1 to 100 transactions')
      }
      appStoreTransactions += transactions.length
      user.appStore = {
        paidUntil: Math.max(now, user.appStore?.paidUntil ?? 0) + 31 * 24 * 60 * 60 * 1000,
        productId: SUBSCRIPTION_PRODUCT,
        environment: 'Sandbox',
        autoRenew: true,
        revokedAt: null,
      }
      answer(200, { user: publicUser(user, user.devices.at(-1)?.id) })
    })
    return true
  }

  if (method === 'POST' && route === '/appstore/notifications') {
    return answer(200, { ok: true }), true
  }

  if (method === 'GET' && route === '/debug') {
    return answer(200, {
      users: [...accounts.values()].map((user) => ({
        username: user.username,
        plan: publicUser(user).plan,
        paidUntil: publicUser(user).paidUntil,
      })),
      sessions: accountSessions.size,
      appStoreTransactions,
    }), true
  }

  return refusal(404, 'INVALID_INPUT', `no account route ${method} ${route}`), true
}

const server = createServer((request, response) => {
  const url = new URL(request.url ?? '/', `http://127.0.0.1:${port}`)
  if (handleAccount(request, response, url)) return
  if (request.url?.startsWith('/connections')) {
    // How many sockets have been opened since the last reset. A reconnect is
    // invisible from the app's side -- the data looks the same afterwards -- so
    // this is the only way a test can say that a failure did *not* cost one.
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ connections }))
    return
  }
  if (request.url?.startsWith('/hellos')) {
    // How many LAN-scan probes have reached this process since the last reset.
    // See `hellos`: the scan is silent from the screen, so its cost can only be
    // counted here.
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ hellos }))
    return
  }
  if (request.url?.startsWith('/hold')) {
    // `?messages=1` holds every `session.messages` answer; `?messages=0`
    // releases what is waiting. The count is reported so a test can say it
    // released something rather than assuming it did.
    const previous = heldMessages.length
    holdingMessages = (request.url ?? '').includes('messages=1')
    if (!holdingMessages) {
      for (const waiting of heldMessages) waiting()
      heldMessages = []
    }
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ ok: true, holding: holdingMessages, released: previous }))
    return
  }
  if (request.url?.startsWith('/prompts')) {
    // What the app has actually sent, and how each one travelled. A held prompt
    // produces no request at all, and a guided one produces the same
    // `session.prompt` a queued one does -- so "did it leave the phone, and was
    // it guidance" is a question only this side of the wire can answer.
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({
      prompts: sentPrompts.slice(),
      modes: sentPromptModes.slice(),
    }))
    return
  }
  if (request.url?.startsWith('/loads')) {
    // How many `session.messages` reads the app asked for at the same time, and
    // the most that ever were. See `messagesInFlight`.
    const answer = {
      inFlight: messagesInFlight,
      peak: messagesPeak,
      methods: { ...methodCounts },
      refusedMethods: { ...refusedCounts },
      modelSets: modelSets.slice(),
      forks: forkRequests.slice(),
      // How many `session.activity` reads carried `beforeSeq`. A lazy page is
      // invisible from the screen -- the rows look like the rows that were
      // already there -- so this is the only place "the older history was
      // actually asked for" is a fact.
      activityPages: activityPageRequests,
      // The pairing handshakes that reached the host. A test uses this to prove
      // the app launched with the pairing URI it passed, rather than connecting
      // from a stored pairing after a launch the system made on its own.
      pairings: pairingRequests,
    }
    if ((request.url ?? '').includes('reset=1')) {
      messagesInFlight = 0
      messagesPeak = 0
      activityPageRequests = 0
      for (const key of Object.keys(methodCounts)) delete methodCounts[key]
    }
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify(answer))
    return
  }
  if (request.url?.startsWith('/activity')) {
    // How many rows the long detail fixture exposes, from now on. See
    // `activityLongCount`. Zero (or no `count`) is the default fixture every
    // other suite measures; a positive count is the fixed log a paging test
    // scrolls back through.
    const match = /count=(\d+)/.exec(request.url ?? '')
    activityLongCount = match === null ? 0 : Math.min(500, Number(match[1]))
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ ok: true, activityCount: activityLongCount }))
    return
  }
  if (request.url?.startsWith('/session')) {
    // Whether the session in the fixture is running, from now on. See
    // `sessionRunning`.
    sessionRunning = !(request.url ?? '').includes('running=0')
    // `/reset` restores the whole fixture, the delivered file included: a test
    // that leaves it on would put a card under every later test's answer.
    deliverablesPresent = false
    deliveredVariant = 'md'
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ ok: true, sessionRunning }))
    return
  }
  if (request.url?.startsWith('/offline')) {
    offline = (request.url ?? '').includes('on=1')
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ ok: true, offline }))
    return
  }
  if (request.url?.startsWith('/lan')) {
    // The LAN route goes away while the relay stays up. See `lanOff`.
    //
    // `?off=1` is the failure being reproduced: every socket the phone has on
    // the main listener is destroyed, and every new WebSocket upgrade on it is
    // refused. The HTTP server itself stays up, so this endpoint (and `/reset`,
    // and the whole account surface) keeps answering -- which is also what lets
    // the test put the fixture back after an aborted run.
    //
    // `?on=1` puts the LAN back without a full reset, for a test that wants to
    // watch it return.
    lanOff = !(request.url ?? '').includes('on=1')
    let dropped = 0
    if (lanOff) {
      for (const socket of wss.clients) {
        // Terminated rather than closed politely: a phone that walked out of
        // range does not get a close frame either, and a clean close would let
        // the app treat this as the host saying goodbye rather than as a link
        // that vanished.
        socket.terminate()
        dropped += 1
      }
    }
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ ok: true, lan: lanOff ? 'off' : 'on', dropped }))
    return
  }
  if (request.url?.startsWith('/forked')) {
    // Whether the list also reports a "branch in a new conversation" and a
    // delegated child, from now on. See `forkedSessionPresent`. Off is the
    // default and what `/reset` puts back, so the fixture every other suite
    // measures is the one it measured before.
    forkedSessionPresent = (request.url ?? '').includes('on=1')
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ ok: true, forked: forkedSessionPresent }))
    return
  }
  if (request.url?.startsWith('/reader')) {
    longReaderFixture = (request.url ?? '').includes('long=1')
    markdownReaderFixture = (request.url ?? '').includes('markdown=1')
    const texts = markdownReaderFixture ? Array.from({ length: 24 }, (_, i) => [performanceMarkdown(i + 1, 'user'), performanceMarkdown(i + 1, 'assistant')]).flat() : []
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ ok: true, long: longReaderFixture, markdown: markdownReaderFixture, markdownMessages: texts.length, utf8Bytes: texts.reduce((n, text) => n + Buffer.byteLength(text, 'utf8'), 0) }))
    return
  }
  if (request.url?.startsWith('/balance')) {
    balanceVariant = /variant=([\w-]+)/.exec(request.url ?? '')?.[1] ?? 'ready'
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ ok: true, variant: balanceVariant }))
    return
  }
  if (request.url?.startsWith('/stats')) {
    statsVariant = /variant=(\w+)/.exec(request.url ?? '')?.[1] ?? 'full'
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ ok: true, statsVariant }))
    return
  }
  if (request.url?.startsWith('/deliverables')) {
    // Turn the fixture's delivered file on or off. Off is the default so the
    // suites that predate previews keep measuring the screen they measured.
    deliverablesPresent = request.url.includes('on=1')
    // Which file the card should name: `md` (the default), `code`, or `image`.
    const requested = /file=([A-Za-z]+)/.exec(request.url ?? '')?.[1]
    if (requested !== undefined && DELIVERED_FILES[requested] !== undefined) {
      deliveredVariant = requested
    }
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ ok: true, deliverables: deliverablesPresent, file: deliveredVariant }))
    return
  }
  if (request.url?.startsWith('/fail')) {
    failMethod = /method=([A-Za-z.]+)/.exec(request.url ?? '')?.[1] ?? null
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ ok: true, failMethod }))
    return
  }
  if (request.url?.startsWith('/slow')) {
    // Set the stall *after* the app is up, so a test can make one screen slow
    // without also making the launch that leads to it slow.
    //
    // `?method=session.messages` narrows it to one method, which is what lets a
    // test hold a reload open without also holding back the send that has to
    // land while it is open. Absent, every answer is stalled, as before.
    const match = /ms=(\d+)/.exec(request.url ?? '')
    answerDelayMs = match === null ? 0 : Math.min(5000, Number(match[1]))
    slowMethod = /method=([A-Za-z.]+)/.exec(request.url ?? '')?.[1] ?? null
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ ok: true, delayMs: answerDelayMs, slowMethod }))
    return
  }
  if (request.url?.startsWith('/reset')) {
    // Between UI tests, so each one starts from the same fixture.
    //
    // `sentPrompts` is deliberate -- the conversation has to grow when something
    // is sent, or the send path is untestable -- but it grew for the life of the
    // process, which is the whole suite. Every test after the first send
    // therefore ran against a longer conversation than the one before it, and a
    // test that scrolled to find a message found a different amount of content
    // depending on which tests had run first. That is a suite whose failures
    // depend on test order, which is a suite nobody can trust.
    sentPrompts.length = 0
    sentPromptModes.length = 0
    createdSessions.length = 0
    forkRequests.length = 0
    longReaderFixture = false
    markdownReaderFixture = false
    balanceVariant = /balance=([\w-]+)/.exec(request.url ?? '')?.[1] ?? 'old'
    failMethod = null
    statsVariant = 'full'
    // The permission preset and the archived set are fixture state like the
    // rest: a test that switches the preset must not hand the next test a
    // session already in read-only, and a test that archives must not hand it a
    // list missing a row.
    permissionPreset = 'workspace-write'
    archivedSessionIds.clear()
    // The fork fixture goes back with everything else: a test that asked for
    // it must not hand the next test a list with two extra sessions in it.
    forkedSessionPresent = false
    // The account fixture goes back with everything else: a test that signs in
    // must not inherit the previous test's paid plan or its session tokens.
    resetAccounts()
    // The detail feed grows per poll; a test that starts from the fixture must
    // start from the beginning of it. The long fixture and its paging counter
    // go back with it, so a paging test cannot hand the next test a 120-row log.
    activityPolls = 0
    activityLongCount = 0
    activityPageRequests = 0
    // `?skew=NNN` moves the host's clock ahead of the phone's, which is what a
    // running turn's negative duration came from. `?pageLimit=NNN` makes the
    // host refuse a page it cannot carry.
    const skew = /skew=(\d+)/.exec(request.url ?? '')
    clockSkewMs = skew === null ? 0 : Number(skew[1])
    const limit = /pageLimit=(\d+)/.exec(request.url ?? '')
    pageLimit = limit === null ? Infinity : Number(limit[1])
    connections = 0
    relayConnections = 0
    pairingRequests = 0
    hellos = 0
    // The LAN route goes back with everything else: a test that took it away
    // must not hand the next test a computer that refuses its own address. The
    // relay listener was never down, so `/lan?on=1` and this are the same
    // restoration.
    lanOff = false
    // `?running=0` reports the fixture's session as stopped, which is how a test
    // avoids posting a Live Activity at all -- the widget extension is a separate
    // process, and a suite that has to draw one is a suite that fails for reasons
    // that have nothing to do with what it is testing.
    sessionRunning = !(request.url ?? '').includes('running=0')
    // `?states=1` plays one live state sequence for the fixture session; the
    // phone's stream is empty without the binary channel.
    hideSessionFromList = (request.url ?? '').includes('hideSession=1')
    stateStream = (request.url ?? '').includes('states=long')
      ? 'long'
      : (request.url ?? '').includes('states=1') ? 'short' : ''
    stateStreamPlayed = false
    stateStreamEntries = []
    // `/reset` restores the whole fixture, the delivered file included: a test
    // that leaves it on would put a card under every later test's answer.
    deliverablesPresent = false
    // `?pending=0` takes the two interaction cards off the screen, for a test
    // that is about what is underneath them. The default is to offer them.
    withPending = !(request.url ?? '').includes('pending=0')
    const slow = /slow=(\d+)/.exec(request.url ?? '')
    answerDelayMs = slow === null ? 0 : Math.min(5000, Number(slow[1]))
    slowMethod = null
    messagesInFlight = 0
    messagesPeak = 0
    holdingMessages = false
    heldMessages = []
    for (const key of Object.keys(methodCounts)) delete methodCounts[key]
    for (const key of Object.keys(refusedCounts)) delete refusedCounts[key]
    modelSets.length = 0
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ ok: true }))
    return
  }
  if (request.url?.startsWith('/mizar/v1/hello')) {
    if (request.method === 'GET') hellos += 1
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({
      protocolVersion: 1,
      hostId: HOST_ID,
      hostName: HOST_NAME,
      paired: false,
      pairingOpen: true,
    }))
    return
  }
  if (request.url?.startsWith('/mizar/v1/pair')) {
    let body = ''
    request.on('data', (chunk) => { body += chunk })
    request.on('end', () => {
      let parsed = {}
      try { parsed = JSON.parse(body) } catch { /* refuse below */ }
      if (parsed.code !== CODE) {
        response.writeHead(403, { 'content-type': 'application/json' })
        response.end(JSON.stringify({ code: 'BAD_CODE', message: 'wrong code' }))
        return
      }
      // Counted only for a request the fixture accepted: a probe with the wrong
      // code is not a pairing, and a test waiting for one would be waiting for
      // the wrong fact.
      pairingRequests += 1
      response.writeHead(200, { 'content-type': 'application/json' })
      response.end(JSON.stringify({
        deviceToken: 'mz_mock_token',
        deviceId: DEVICE_ID,
        hostId: HOST_ID,
        hostName: HOST_NAME,
        authority: `127.0.0.1:${port}`,
        protocolVersion: 1,
      }))
    })
    return
  }
  response.writeHead(404).end()
})

/** Refuse an upgrade, HTTP-style, and let the socket go. */
function refuseUpgrade(socket, status, reason) {
  socket.write(`HTTP/1.1 ${status} ${reason}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`)
  socket.destroy()
}

/**
 * Serve one accepted WebSocket, whichever listener it arrived on.
 *
 * One handler for both, because the point of the relay stand-in is that the
 * phone is talking to the *same host*: same fixture, same `answer()`, same
 * counters, same device token. Anything that differed between the two listeners
 * would be a difference the app would be right not to notice and this test would
 * be wrong to depend on.
 *
 * - Parameter socket - the open WebSocket.
 */
/** One 13-byte state-channel frame. */
function stateFrame(code, interval, flags, textSeq, text) {
  const payload = Buffer.from(text ?? '', 'utf8')
  const out = Buffer.alloc(13 + payload.length)
  out[0] = 0x53
  out[1] = code
  out[2] = flags
  out.writeUInt32BE(interval, 3)
  out.writeUInt32BE(textSeq, 7)
  out.writeUInt16BE(payload.length, 11)
  payload.copy(out, 13)
  return out
}

/** The socket envelope: one length byte, the session id, the frame. */
function stateEnvelope(sessionId, frame) {
  const id = Buffer.from(sessionId, 'utf8')
  return Buffer.concat([Buffer.from([id.length]), id, frame])
}

/** Play one turn: thinking, narration, tool, narration, final, completed. */
function playStateStream(socket) {
  const id = SESSION.sessionId
  const long = stateStream === 'long'
  const finalText = long
    ? ('这是一段用于滚动与打字压力的长回答。\n\n' +
       '- **第一项**：保留现有的路由选择；\n' +
       '- **第二项**：把会话流的块按 interval 排序；\n' +
       '- **第三项**：在没有 journal 时退回历史渲染。\n\n' +
       '然后是一段较长的说明，用来让 Markdown 解析、打字机和滚动锚点同时工作。').repeat(8)
    : '三处都改完了，测试全绿。'
  const steps = [
    [400, { interval: 1, state: 1, text: '', final: false }, stateFrame(1, 1, 4, 0, '')],
    [900, { interval: 2, state: 5, text: '我先看一下现有的实现。', final: false }, stateFrame(5, 2, 6, 0, '我先看一下现有的实现。')],
    [900, { interval: 3, state: 2, text: '', final: false }, stateFrame(2, 3, 4, 0, '')],
  ]
  if (long) {
    for (let index = 0; index < 12; index += 1) {
      const interval = 4 + index * 2
      const text = `第 ${index + 1} 段过程。` + '这是一段较长的过程正文，用于滚动压力测试。'.repeat(3)
      steps.push([220, { interval, state: 5, text, final: false }, stateFrame(5, interval, 6, 0, text)])
      steps.push([120, { interval: interval + 1, state: 2, text: '', final: false }, stateFrame(2, interval + 1, 4, 0, '')])
    }
  }
  const finalInterval = long ? 40 : 5
  steps.push([900, { interval: finalInterval, state: 6, text: finalText, final: true }, stateFrame(6, finalInterval, 6, 0, finalText)])
  steps.push([150, { interval: finalInterval, state: 6, text: '', final: true }, stateFrame(6, finalInterval, 8, 0, '')])
  steps.push([150, { interval: finalInterval + 1, state: 11, text: '', final: false }, stateFrame(11, finalInterval + 1, 0, 0, '')])
  let at = 0
  for (const [delay, entry, frame] of steps) {
    at += delay
    setTimeout(() => {
      if (entry.text !== '') stateStreamEntries.push(entry)
      if (socket.readyState === socket.OPEN) socket.send(stateEnvelope(id, frame), { binary: true })
      else console.log('mock: state socket closed before', entry.interval)
    }, at)
  }
  setTimeout(() => { sessionRunning = false }, at + 250)
}

function handleSocket(socket) {
  if (offline) {
    // Closed immediately rather than left hanging: a socket that opens and then
    // says nothing is what a network failure looks like from the app's side, and
    // that is the case being reproduced.
    socket.close(1011, 'mock offline')
    return
  }
  socket.on('message', (raw) => {
    let frame
    try { frame = JSON.parse(String(raw)) } catch { return }
    methodCounts[frame.type] = (methodCounts[frame.type] ?? 0) + 1
    // Counted around the whole answer, not around the delay: a read that is
    // still being answered when the next one arrives is the overlap being
    // measured, and whether it was slow is beside the point.
    if (stateStream !== '' && !stateStreamPlayed && frame.type === 'hello') {
      stateStreamPlayed = true
      console.log('mock: playing a live state stream')
      setTimeout(() => playStateStream(socket), 700)
    }
    const isLogRead = frame.type === 'session.messages'
    if (isLogRead) {
      messagesInFlight += 1
      messagesPeak = Math.max(messagesPeak, messagesInFlight)
    }
    const finish = () => {
      if (isLogRead) messagesInFlight -= 1
      socket.send(JSON.stringify(answer(frame)))
    }
    const delay = slowMethod === null || slowMethod === frame.type ? answerDelayMs : 0
    if (isLogRead && holdingMessages) {
      // Counted as in flight for as long as it is held: from the host's side
      // this request has not been answered, which is exactly what a second one
      // arriving alongside it means.
      heldMessages.push(finish)
      return
    }
    if (delay === 0) finish()
    else setTimeout(finish, delay)
  })
}

// MARK: - The main listener (the computer's own address)

// Upgrades are handled by hand rather than by passing `server` to the
// `WebSocketServer`, because `/lan?off=1` has to refuse a socket *before* it is
// accepted. A `WebSocketServer` handed the server would complete the handshake
// on its own schedule, and the refusal would arrive as a close after an accepted
// connection -- a different failure from an address that is not there.
const wss = new WebSocketServer({ noServer: true })
wss.on('connection', (socket) => {
  connections += 1
  handleSocket(socket)
})

const announcementWss = new WebSocketServer({ noServer: true })
announcementWss.on('connection', (socket) => {
  // The snapshot frame, exactly as the relay sends it: a phone that connects
  // while the banner is live draws it without waiting for a new one.
  socket.send(JSON.stringify({ type: 'snapshot', announcements: [ANNOUNCEMENT] }))
})

server.on('upgrade', (request, socket, head) => {
  const url = new URL(request.url ?? '/', `http://127.0.0.1:${port}`)
  if (url.pathname === '/app/v1/announcements') {
    console.log(`announcement socket: ${request.socket.remoteAddress} session=${request.headers['x-mizar-session'] ? 'yes' : 'no'}`)
    announcementWss.handleUpgrade(request, socket, head, (ws) => announcementWss.emit('connection', ws, request))
    return
  }
  if (url.pathname !== WS_PATH) {
    // The same refusal the library gives for an upgrade to a path this listener
    // does not serve; nothing in this fixture dials any other path except the
    // relay stand-in below, which has its own listener.
    refuseUpgrade(socket, 400, 'Bad Request')
    return
  }
  if (lanOff) {
    // The reported failure: the LAN is gone. Refused at the upgrade so the
    // phone's direct dial fails promptly, exactly as dialling a computer whose
    // address has moved does. The HTTP surface -- `/lan?on=1`, `/reset`, the
    // account routes -- stays up on the same listener.
    refuseUpgrade(socket, 503, 'Service Unavailable')
    return
  }
  wss.handleUpgrade(request, socket, head, (ws) => wss.emit('connection', ws, request))
})

// MARK: - The relay stand-in (a second address for the same computer)

/**
 * The relay listener's plain HTTP surface.
 *
 * Only what a test needs to read and what a phone might ask before upgrading:
 * its own connection count, and `hello` so the address identifies as the same
 * machine. Pairing is deliberately not served here -- the real relay forwards
 * pairing too, but this fixture pairs over the direct route and the phone only
 * ever reaches the relay *after* the LAN is gone, which is the case under test.
 */
const relayServer = createServer((request, response) => {
  const url = new URL(request.url ?? '/', `http://127.0.0.1:${RELAY_PORT}`)
  if (url.pathname === '/connections') {
    // The relay's own count. The main port's `/connections` counts direct
    // sockets; this one counts relayed ones. Separate on purpose: the assertion
    // "the phone failed over" is "this number went from zero to one".
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ connections: relayConnections }))
    return
  }
  if (url.pathname === '/mizar/v1/hello') {
    if (request.method === 'GET') hellos += 1
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({
      protocolVersion: 1,
      hostId: HOST_ID,
      hostName: HOST_NAME,
      paired: false,
      pairingOpen: false,
    }))
    return
  }
  response.writeHead(404).end()
})

const relayWss = new WebSocketServer({ noServer: true })
relayWss.on('connection', (socket) => {
  relayConnections += 1
  handleSocket(socket)
})

relayServer.on('upgrade', (request, socket, head) => {
  const url = new URL(request.url ?? '/', `http://127.0.0.1:${RELAY_PORT}`)
  if (url.pathname !== RELAY_WS_PATH) {
    refuseUpgrade(socket, 404, 'Not Found')
    return
  }
  relayWss.handleUpgrade(request, socket, head, (ws) => relayWss.emit('connection', ws, request))
})

server.listen(port, '127.0.0.1', () => {
  console.log(`mock host on 127.0.0.1:${port}, code ${CODE}`)
  console.log(`mizar://pair?h=127.0.0.1%3A${port}&c=${CODE}&n=Mock%20Mac&v=1`)
  console.log(`relay base for this host: http://127.0.0.1:${RELAY_PORT}/r/${RELAY_ROOM}`)
})

relayServer.on('error', (error) => {
  // The relay port is `port + 2`, so two mocks on adjacent fixture ports cannot
  // collide -- but a stray process from an interrupted run can. Say so and stop:
  // a host that answers direct and silently has no relay is a fixture that
  // would make the failover test fail for the wrong reason.
  console.error(
    `mock: the relay listener on 127.0.0.1:${RELAY_PORT} could not start `
    + `(${error.code ?? error.message}); another process may be using it`,
  )
  process.exit(1)
})

relayServer.listen(RELAY_PORT, '127.0.0.1')
