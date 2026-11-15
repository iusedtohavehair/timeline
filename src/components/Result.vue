<script setup>
import { computed, ref } from 'vue'

const props = defineProps({
  result: { type: Object, required: true },
})

const emit = defineEmits(['again'])

const mode = ref('yours')
const copied = ref(false)
const fallback = ref(false)

const labels = {
  pop_culture: 'Pop culture',
  music: 'Music',
  film_tv: 'Film & TV',
  politics: 'Politics',
  sports: 'Sports',
  tech_internet: 'Tech',
  scandal: 'Scandal',
  viral_meme: 'Viral',
  covid: 'COVID',
  world_news: 'World',
}

const timeline = computed(() => {
  const rows = Array.isArray(props.result.timeline) ? props.result.timeline : []
  return rows.map((row) => ({ ...row, shift: Number(row.shift) || 0 }))
})

const score = computed(() => {
  const value = Number(props.result.score)
  return Number.isFinite(value) ? Math.round(value) : 0
})

const standout = computed(() => {
  const amounts = timeline.value.map((row) => Math.abs(row.shift)).filter(Boolean)
  if (!amounts.length) return new Set()
  const max = Math.max(...amounts)
  const majors = new Set([max])
  const alone = timeline.value.filter((row) => Math.abs(row.shift) === max).length === 1
  const next = Math.max(0, ...amounts.filter((amount) => amount < max))
  if (alone && next) majors.add(next)
  return majors
})

const shown = computed(() => {
  const rows = [...timeline.value]
  if (mode.value === 'true') rows.sort((a, b) => Number(a.true_pos) - Number(b.true_pos))
  return rows
})

const shareText = computed(() => {
  const rows = timeline.value
  const right = rows.filter((row) => row.shift === 0).length
  let text = `I ordered ${right}/${rows.length} events right.`
  const featured = rows.reduce((best, row) => {
    if (row.shift === 0) return best
    if (!best || Math.abs(row.shift) > Math.abs(best.shift)) return row
    return best
  }, null)
  if (featured) {
    const how = featured.shift > 0 ? 'way more recent' : 'way older'
    text += ` "${featured.title}" felt ${how} than it was.`
  }
  text += ` ${location.origin}`
  return text
})

function label(category) {
  return labels[category] || category
}

function formatWhen(dateText, precision) {
  const [year, month, day] = String(dateText || '').split('-').map(Number)
  if (!year || !month) return dateText || ''
  const utc = new Date(Date.UTC(year, month - 1, day || 1))
  if (precision === 'month' || !day) {
    return new Intl.DateTimeFormat('en-US', {
      month: 'short',
      year: 'numeric',
      timeZone: 'UTC',
    }).format(utc)
  }
  return new Intl.DateTimeFormat('en-US', {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
    timeZone: 'UTC',
  }).format(utc)
}

function cardClass(card) {
  const amount = Math.abs(card.shift)
  return {
    'is-major': amount > 0 && standout.value.has(amount),
    'is-off': amount > 0 && !standout.value.has(amount),
  }
}

async function copy() {
  copied.value = false
  try {
    await navigator.clipboard.writeText(shareText.value)
    copied.value = true
    window.setTimeout(() => { copied.value = false }, 2000)
  } catch {
    fallback.value = true
  }
}
</script>

<template>
  <section>
    <p class="score">You ordered {{ score }}% correctly</p>
    <div class="switch" role="group" aria-label="Which order to show">
      <button type="button" :aria-pressed="mode === 'yours'" @click="mode = 'yours'">Your order</button>
      <button type="button" :aria-pressed="mode === 'true'" @click="mode = 'true'">True order</button>
    </div>
    <p class="hint">
      {{ mode === 'yours' ? 'This is the order you built.' : 'This is the real sequence.' }}
    </p>
    <div class="bleed">
      <div class="scroller" tabindex="0" aria-label="Revealed timeline">
        <div class="row">
          <p class="end">← earlier</p>
          <article v-for="card in shown" :key="card.id" class="mini" :class="cardClass(card)">
            <p class="tag">{{ label(card.category) }}</p>
            <h3>{{ card.title }}</h3>
            <p class="when">{{ formatWhen(card.date_text, card.precision) }}</p>
            <p v-if="card.shift > 0" class="shift">Felt more recent than it really was</p>
            <p v-else-if="card.shift < 0" class="shift">Felt older than it really was</p>
          </article>
          <p class="end">later →</p>
        </div>
      </div>
    </div>
    <div class="actions">
      <button class="primary" type="button" @click="emit('again')">Play again</button>
      <button class="secondary" type="button" @click="copy">{{ copied ? 'Copied' : 'Copy result' }}</button>
    </div>
    <textarea v-if="fallback" readonly :value="shareText" aria-label="Result text"></textarea>
  </section>
</template>
