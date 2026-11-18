<script setup>
import { computed, ref, watch } from 'vue'
import { checkPlacement, getGameEvents, submitGame } from './api.js'
import Demographics from './components/Demographics.vue'
import Timeline from './components/Timeline.vue'
import Result from './components/Result.vue'

const ID_KEY = 'timeline.playerId'
const DEMO_KEY = 'timeline.demographicsDone'
const BEST_KEY = 'timeline.bestCards'
const LEVELS = {
  1: 'Easy',
  2: 'In between',
  3: 'Niche',
}

const phase = ref('intro')
const playerId = ref(readPlayerId())
const pendingDemo = ref({})
const events = ref([])
const placed = ref([])
const placements = ref([])
const cursor = ref(0)
const shownAt = ref(0)
const freshId = ref(null)
const verdict = ref(null)
const pendingDrop = ref(null)
const skipsLeft = ref(3)
const lives = ref(3)
const score = ref(0)
const misses = ref({})
const level = ref(1)
const died = ref(false)
const bestScore = ref(0)
const newBest = ref(false)
const round = ref(0)
const result = ref(null)
const loading = ref(false)
const error = ref(null)
const privacyEl = ref(null)

const contactEmail = String(import.meta.env.VITE_CONTACT_EMAIL || '').trim()
const mailto = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(contactEmail) ? contactEmail : ''

const levelName = computed(() => LEVELS[level.value] || 'Easy')
const current = computed(() => events.value[cursor.value] || null)

watch(phase, () => window.scrollTo(0, 0))

function readPlayerId() {
  try {
    const existing = localStorage.getItem(ID_KEY)
    if (existing) return existing
    const created = crypto.randomUUID()
    localStorage.setItem(ID_KEY, created)
    return created
  } catch {
    return crypto.randomUUID()
  }
}

function bestKey(n) {
  return BEST_KEY + '.' + n
}

function readBest(n) {
  try {
    const value = Number(localStorage.getItem(bestKey(n)))
    return Number.isInteger(value) && value >= 0 ? value : 0
  } catch {
    return 0
  }
}

function rememberBest(score) {
  const value = Math.round(Number(score) || 0)
  const previous = readBest(level.value)
  newBest.value = value > previous
  bestScore.value = newBest.value ? value : previous
  if (!newBest.value) return
  try {
    localStorage.setItem(bestKey(level.value), String(value))
  } catch {
    /* private mode can still finish this visit */
  }
}

function sawDemographics() {
  try {
    return localStorage.getItem(DEMO_KEY) === '1'
  } catch {
    return false
  }
}

function markDemographics() {
  try {
    localStorage.setItem(DEMO_KEY, '1')
  } catch {
    /* private mode can still finish this visit */
  }
}

function messageFor(err, kind) {
  const raw = [err?.message, err?.details, err?.hint].filter(Boolean).join(' ')
  if (raw === 'config') {
    return { kind, text: 'Add VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY to .env, then refresh.', detail: '' }
  }
  if (raw === 'secret') {
    return { kind, text: 'That value is a secret key. Paste the publishable key (sb_publishable_...) instead, then refresh.', detail: '' }
  }
  if (/could not find the function/i.test(raw) && /get_game_events/.test(raw)) {
    return { kind, text: 'Run db/api.sql in the Supabase SQL editor, then refresh.', detail: '' }
  }
  if (raw === 'short') return { kind, text: 'Not enough events are available for this level.', detail: '' }
  if (raw === 'bad result') return { kind, text: 'The reveal came back empty.', detail: '' }
  return { kind, text: 'The game could not reach the database. Try again.', detail: raw }
}

function play(nextLevel) {
  const picked = Number(nextLevel)
  if (![1, 2, 3].includes(picked)) return
  level.value = picked
  error.value = null
  if (!sawDemographics()) {
    phase.value = 'demographics'
    return
  }
  pendingDemo.value = {}
  startRound()
}

function onDemo(demo) {
  const empty = !demo || Object.keys(demo).length === 0
  pendingDemo.value = empty ? {} : demo
  if (empty) markDemographics()
  startRound()
}

function playAgain() {
  pendingDemo.value = {}
  phase.value = 'intro'
}

async function startRound() {
  phase.value = 'play'
  loading.value = true
  error.value = null
  result.value = null
  events.value = []
  placed.value = []
  placements.value = []
  freshId.value = null
  verdict.value = null
  pendingDrop.value = null
  skipsLeft.value = 3
  lives.value = 3
  score.value = 0
  misses.value = {}
  died.value = false
  newBest.value = false
  bestScore.value = readBest(level.value)
  round.value += 1
  try {
    const data = await getGameEvents(level.value)
    if (!Array.isArray(data) || data.length < 2) throw new Error('short')
    events.value = data
    const first = events.value[0]
    placed.value = [first]
    placements.value = [{ event_id: first.id, insert_index: 0, response_ms: 0 }]
    freshId.value = first.id
    cursor.value = 1
    shownAt.value = Date.now()
  } catch (err) {
    error.value = messageFor(err, 'load')
  } finally {
    loading.value = false
  }
}

function onSkip() {
  const event = current.value
  if (!event || loading.value || error.value || skipsLeft.value < 1) return
  skipsLeft.value -= 1
  verdict.value = null
  cursor.value += 1
  if (!events.value[cursor.value]) finish()
  else shownAt.value = Date.now()
}

function onPlace(insertIndex) {
  const event = current.value
  if (!event || loading.value || error.value) return
  if (insertIndex < 0 || insertIndex > placed.value.length) return
  if (placements.value.some((item) => item.event_id === event.id)) return
  pendingDrop.value = {
    event,
    index: insertIndex,
    responseMs: Math.max(0, Math.min(Date.now() - shownAt.value, 2147483647)),
  }
  resolveDrop()
}

async function resolveDrop() {
  const drop = pendingDrop.value
  if (!drop || loading.value) return
  loading.value = true
  error.value = null
  try {
    let data = await checkPlacement(placed.value.map((card) => card.id), drop.event.id, drop.index)
    if (typeof data === 'string') data = JSON.parse(data)
    const at = Number(data?.insert_index)
    if (!Number.isInteger(at) || at < 0 || at > placed.value.length) throw new Error('bad check')
    placements.value.push({
      event_id: drop.event.id,
      insert_index: drop.index,
      response_ms: drop.responseMs,
    })
    placed.value.splice(at, 0, drop.event)
    freshId.value = drop.event.id
    verdict.value = { correct: data.correct === true, id: drop.event.id }
    if (data.correct === true) score.value += 1
    else {
      misses.value = {
        ...misses.value,
        [String(drop.event.id)]: drop.index > at ? 'recent' : 'older',
      }
      lives.value -= 1
      if (lives.value <= 0) died.value = true
    }
    pendingDrop.value = null
    cursor.value += 1
    if (died.value || cursor.value >= events.value.length) await finish()
    else {
      shownAt.value = Date.now()
      loading.value = false
    }
  } catch (err) {
    error.value = messageFor(err, 'check')
    loading.value = false
  }
}

async function finish() {
  loading.value = true
  error.value = null
  try {
    let data = await submitGame(playerId.value, pendingDemo.value || {}, placements.value)
    if (typeof data === 'string') data = JSON.parse(data)
    if (!data || !Array.isArray(data.timeline)) throw new Error('bad result')
    result.value = data
    rememberBest(score.value)
    pendingDemo.value = {}
    markDemographics()
    phase.value = 'result'
  } catch (err) {
    error.value = messageFor(err, 'submit')
  } finally {
    loading.value = false
  }
}

function retry() {
  if (error.value?.kind === 'submit') finish()
  else if (error.value?.kind === 'check') {
    error.value = null
    resolveDrop()
  } else startRound()
}

function openPrivacy() {
  privacyEl.value?.showModal()
}

function closePrivacy() {
  privacyEl.value?.close()
}

function onPrivacyClick(event) {
  if (event.target === privacyEl.value) privacyEl.value.close()
}
</script>

<template>
  <div class="wrap">
    <header class="top">
      <h1>Timeline</h1>
      <p v-if="phase === 'play'" class="top-score" aria-live="polite">
        <span>Score</span>
        {{ score }}
      </p>
      <button class="texty" type="button" @click="openPrivacy">Privacy</button>
    </header>

    <section v-if="phase === 'intro'" class="panel">
      <p class="pitch">Since 2020, a lot of years feel like the same year. Put them back in order.</p>
      <ol class="steps">
        <li>The first card stays on the line, with its date. Drag each new one into place.</li>
        <li>You have 3 lives. A miss costs one, and the card jumps to its real spot. Three misses and it's over.</li>
        <li>You can skip 3 events you do not know. A skip moves on and does not cost a life.</li>
        <li>The score is how many cards you get right. Chase the best one.</li>
      </ol>
      <p class="hint">Pick a level. 1 is the easiest. 3 is niche.</p>
      <div class="levels" role="group" aria-label="Choose a level">
        <button class="level" type="button" @click="play(1)">
          <strong>Level 1</strong>
          <span>Easy</span>
        </button>
        <button class="level" type="button" @click="play(2)">
          <strong>Level 2</strong>
          <span>In between</span>
        </button>
        <button class="level" type="button" @click="play(3)">
          <strong>Level 3</strong>
          <span>Niche</span>
        </button>
      </div>
    </section>

    <Demographics v-else-if="phase === 'demographics'" @done="onDemo" />

    <section v-else-if="phase === 'result' && result">
      <Result
        :result="result"
        :died="died"
        :best="bestScore"
        :new-best="newBest"
        :level-name="levelName"
        :cards="score"
        :misses="misses"
        @again="playAgain"
      />
    </section>

    <section v-else>
      <p v-if="loading && !events.length" class="hint" aria-live="polite">Shuffling events…</p>
      <div v-if="error" class="notice">
        <p>{{ error.text }}</p>
        <p v-if="error.detail" class="detail">{{ error.detail }}</p>
        <p v-if="error.kind === 'submit' || error.kind === 'check'" class="hint">Your placements are still on this device.</p>
        <button class="primary" type="button" :disabled="loading" @click="retry">Retry</button>
      </div>
      <Timeline
        v-if="events.length"
        :key="round"
        :placed="placed"
        :current="current"
        :busy="loading"
        :fresh-id="freshId"
        :verdict="verdict"
        :skips-left="skipsLeft"
        :lives="lives"
        :level-name="levelName"
        @place="onPlace"
        @skip="onSkip"
      />
    </section>

    <dialog ref="privacyEl" @click="onPrivacyClick">
      <h2>Privacy</h2>
      <p>
        This game can store an optional age bracket, sex, country, and the order of your answers.
        A random id stays in this browser so later games can be grouped. That id is not your name.
      </p>
      <p>Not collected: your name, your email address, or your IP address.</p>
      <p>The reason is anonymous statistics about how people place recent events.</p>
      <p v-if="mailto">
        To ask for deletion, write to <a :href="'mailto:' + mailto">{{ mailto }}</a>.
      </p>
      <p v-else>To ask for deletion, write to the site owner. This build has no contact email yet.</p>
      <div class="actions">
        <button class="primary" type="button" @click="closePrivacy">Close</button>
      </div>
    </dialog>
  </div>
</template>
