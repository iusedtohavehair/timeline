<script setup>
import { computed, ref, watch } from 'vue'
import { getGameEvents, submitGame } from './api.js'
import Demographics from './components/Demographics.vue'
import Timeline from './components/Timeline.vue'
import Result from './components/Result.vue'

const ID_KEY = 'timeline.playerId'
const DEMO_KEY = 'timeline.demographicsDone'

const phase = ref('intro')
const playerId = ref(readPlayerId())
const pendingDemo = ref({})
const events = ref([])
const placed = ref([])
const placements = ref([])
const cursor = ref(0)
const shownAt = ref(0)
const freshId = ref(null)
const round = ref(0)
const result = ref(null)
const loading = ref(false)
const error = ref(null)
const privacyEl = ref(null)

const contactEmail = String(import.meta.env.VITE_CONTACT_EMAIL || '').trim()
const mailto = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(contactEmail) ? contactEmail : ''

const current = computed(() => events.value[cursor.value] || null)
const step = computed(() => Math.min(cursor.value + 1, events.value.length || 10))

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
    return { kind, text: 'Add VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY to .env, then refresh.', detail: '' }
  }
  if (raw === 'short') return { kind, text: 'Fewer than 10 events are available right now.', detail: '' }
  if (raw === 'bad result') return { kind, text: 'The reveal came back empty.', detail: '' }
  return { kind, text: 'The game could not reach the database. Try again.', detail: raw }
}

function play() {
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
  startRound()
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
  round.value += 1
  try {
    const data = await getGameEvents()
    if (!Array.isArray(data) || data.length < 10) throw new Error('short')
    events.value = data.slice(0, 10)
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

function onPlace(insertIndex) {
  const event = current.value
  if (!event || loading.value || error.value) return
  if (insertIndex < 0 || insertIndex > placed.value.length) return
  if (placements.value.some((item) => item.event_id === event.id)) return
  const responseMs = Math.max(0, Math.min(Date.now() - shownAt.value, 2147483647))
  placements.value.push({
    event_id: event.id,
    insert_index: insertIndex,
    response_ms: responseMs,
  })
  placed.value.splice(insertIndex, 0, event)
  freshId.value = event.id
  cursor.value += 1
  if (cursor.value >= events.value.length) finish()
  else shownAt.value = Date.now()
}

async function finish() {
  if (loading.value) return
  loading.value = true
  error.value = null
  try {
    let data = await submitGame(playerId.value, pendingDemo.value || {}, placements.value)
    if (typeof data === 'string') data = JSON.parse(data)
    if (!data || !Array.isArray(data.timeline)) throw new Error('bad result')
    result.value = data
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
  else startRound()
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
      <button class="texty" type="button" @click="openPrivacy">Privacy</button>
    </header>

    <section v-if="phase === 'intro'" class="panel">
      <p class="pitch">Since 2020, a lot of years feel like the same year. Put them back in order.</p>
      <ol class="steps">
        <li>You get 10 events. No dates.</li>
        <li>Tap a gap to place each one earlier or later.</li>
        <li>At the end, the true dates come out.</li>
      </ol>
      <button class="primary" type="button" @click="play">Play</button>
    </section>

    <Demographics v-else-if="phase === 'demographics'" @done="onDemo" />

    <section v-else-if="phase === 'result' && result">
      <Result :result="result" @again="playAgain" />
    </section>

    <section v-else>
      <p v-if="loading && !events.length" class="hint" aria-live="polite">Shuffling 10 events…</p>
      <div v-if="error" class="notice">
        <p>{{ error.text }}</p>
        <p v-if="error.detail" class="detail">{{ error.detail }}</p>
        <p v-if="error.kind === 'submit'" class="hint">Your placements are still on this device.</p>
        <button class="primary" type="button" :disabled="loading" @click="retry">Retry</button>
      </div>
      <Timeline
        v-if="events.length"
        :key="round"
        :placed="placed"
        :current="current"
        :step="step"
        :total="events.length"
        :busy="loading"
        :fresh-id="freshId"
        @place="onPlace"
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
