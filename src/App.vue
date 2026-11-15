<script setup>
import { computed, ref, watch } from 'vue'
import { getGameEvents, submitGame } from './api.js'
import Timeline from './components/Timeline.vue'
import Result from './components/Result.vue'

const ID_KEY = 'timeline.playerId'

const phase = ref('intro')
const playerId = ref(readPlayerId())
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

function messageFor(err, kind) {
  const raw = String(err?.message || '')
  if (raw === 'config') {
    return { kind, text: 'Add VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY to .env, then refresh.' }
  }
  if (raw === 'short') return { kind, text: 'Fewer than 10 events are available right now.' }
  if (raw === 'bad result') return { kind, text: 'The reveal came back empty.' }
  return { kind, text: raw || 'The game could not reach the database. Try again.' }
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
    let data = await submitGame(playerId.value, {}, placements.value)
    if (typeof data === 'string') data = JSON.parse(data)
    if (!data || !Array.isArray(data.timeline)) throw new Error('bad result')
    result.value = data
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
</script>

<template>
  <div class="wrap">
    <header class="top">
      <h1>Timeline</h1>
    </header>

    <section v-if="phase === 'intro'" class="panel">
      <p class="pitch">Since 2020, a lot of years feel like the same year. Put them back in order.</p>
      <ol class="steps">
        <li>You get 10 events. No dates.</li>
        <li>Tap a gap to place each one earlier or later.</li>
        <li>At the end, the true dates come out.</li>
      </ol>
      <button class="primary" type="button" @click="startRound">Play</button>
    </section>

    <section v-else-if="phase === 'result' && result">
      <Result :result="result" @again="startRound" />
    </section>

    <section v-else>
      <p v-if="loading && !events.length" class="hint" aria-live="polite">Shuffling 10 events…</p>
      <div v-if="error" class="notice">
        <p>{{ error.text }}</p>
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
  </div>
</template>
