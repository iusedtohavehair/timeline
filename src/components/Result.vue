<script setup>
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'

const props = defineProps({
  result: { type: Object, required: true },
  died: { type: Boolean, default: false },
  best: { type: Number, default: 0 },
  newBest: { type: Boolean, default: false },
  levelName: { type: String, default: '' },
  cards: { type: Number, default: 0 },
})

const emit = defineEmits(['again'])

const mode = ref('yours')
const copied = ref(false)
const fallback = ref(false)
const flow = ref(null)
const arrows = ref([])

let observer = null
let frame = 0

function layoutArrows() {
  cancelAnimationFrame(frame)
  frame = requestAnimationFrame(() => {
    const el = flow.value
    if (!el) return
    const items = [...el.children].filter((node) => !node.classList.contains('continue'))
    const rows = []
    for (const node of items) {
      const mid = node.offsetTop + node.offsetHeight / 2
      const row = rows.find((entry) => Math.abs(entry.mid - mid) < 36)
      if (row) row.items.push(node)
      else rows.push({ mid, items: [node] })
    }
    const next = []
    for (let i = 0; i < rows.length - 1; i++) next.push(loopBetween(rows[i], rows[i + 1]))
    const same = next.length === arrows.value.length
      && next.every((arrow, index) => arrow.d === arrows.value[index].d)
    if (!same) arrows.value = next
  })
}

function loopBetween(row, following) {
  const last = row.items.reduce((best, node) => (
    node.offsetLeft + node.offsetWidth > best.offsetLeft + best.offsetWidth ? node : best
  ))
  const first = following.items.reduce((best, node) => (
    node.offsetLeft < best.offsetLeft ? node : best
  ))
  const sx = last.offsetLeft + last.offsetWidth - 1
  const sy = last.offsetTop + last.offsetHeight
  const ex = first.offsetLeft + Math.min(22, first.offsetWidth / 2)
  const ey = first.offsetTop
  const bulge = 16
  const left = Math.min(sx, ex) - 4
  const top = sy
  const width = Math.max(28, sx + bulge + 8 - left)
  const height = Math.max(20, ey - top + 2)
  const x1 = sx - left
  const y1 = 1
  const x2 = ex - left
  const y2 = ey - top
  const midY = y1 + (y2 - y1) * 0.58
  const d = `M ${x1} ${y1} C ${x1 + bulge} ${y1}, ${x1 + bulge} ${midY}, ${(x1 + x2) / 2} ${midY} L ${x2} ${midY} L ${x2} ${y2}`
  return { top, left, width, height, d }
}

onMounted(() => {
  observer = new ResizeObserver(() => layoutArrows())
  if (flow.value) observer.observe(flow.value)
  layoutArrows()
})

onBeforeUnmount(() => {
  observer?.disconnect()
  cancelAnimationFrame(frame)
})

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

const scored = computed(() => timeline.value.filter((row) => row.skipped !== true))

const standout = computed(() => {
  const amounts = scored.value.map((row) => Math.abs(row.shift)).filter(Boolean)
  if (!amounts.length) return new Set()
  const max = Math.max(...amounts)
  const majors = new Set([max])
  const alone = scored.value.filter((row) => Math.abs(row.shift) === max).length === 1
  const next = Math.max(0, ...amounts.filter((amount) => amount < max))
  if (alone && next) majors.add(next)
  return majors
})

const shown = computed(() => {
  const rows = [...timeline.value]
  if (mode.value === 'true') rows.sort((a, b) => Number(a.true_pos) - Number(b.true_pos))
  return rows
})

watch(shown, async () => {
  await nextTick()
  layoutArrows()
})

const shareText = computed(() => {
  const rows = timeline.value.filter((row) => row.skipped !== true)
  const right = rows.filter((row) => row.shift === 0).length
  let text = props.died ? 'Out of lives. ' : ''
  text += `I ordered ${right}/${rows.length} events right.`
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
  if (card.skipped) return {}
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
    <p v-if="levelName" class="hint level-played">{{ levelName }}</p>
    <p class="outcome">{{ died ? 'Out of lives' : 'You cleared the line' }}</p>
    <p class="score">Score {{ cards }}</p>
    <p class="hint">You ordered {{ score }}% correctly</p>
    <p v-if="newBest" class="hint best">New best.</p>
    <p v-else-if="best > cards" class="hint best">Best {{ best }}</p>
    <div class="switch" role="group" aria-label="Which order to show">
      <button type="button" :aria-pressed="mode === 'yours'" @click="mode = 'yours'">Your order</button>
      <button type="button" :aria-pressed="mode === 'true'" @click="mode = 'true'">True order</button>
    </div>
    <p class="hint">
      {{ mode === 'yours' ? 'This is the order you built.' : 'This is the real sequence.' }}
    </p>
    <div class="bleed">
      <div ref="flow" class="flow" aria-label="Revealed timeline. A long line continues on the next row.">
        <p class="end">← earlier</p>
        <article v-for="card in shown" :key="card.id + '-' + mode" class="mini" :class="cardClass(card)">
          <p class="tag">{{ label(card.category) }}</p>
          <h3>{{ card.title }}</h3>
          <p class="when">{{ formatWhen(card.date_text, card.precision) }}</p>
          <p v-if="card.skipped" class="shift">Skipped</p>
          <p v-else-if="card.shift > 0" class="shift">Felt more recent than it really was</p>
          <p v-else-if="card.shift < 0" class="shift">Felt older than it really was</p>
        </article>
        <p class="end">later →</p>
        <svg
          v-for="(arrow, index) in arrows"
          :key="'arrow-' + index"
          class="continue"
          :width="arrow.width"
          :height="arrow.height"
          :viewBox="`0 0 ${arrow.width} ${arrow.height}`"
          :style="{ top: arrow.top + 'px', left: arrow.left + 'px' }"
          aria-hidden="true"
        >
          <defs>
            <marker :id="'result-loop-' + index" markerWidth="8" markerHeight="8" refX="6" refY="4" orient="auto">
              <path d="M0 0 L8 4 L0 8 Z" fill="currentColor" />
            </marker>
          </defs>
          <path :d="arrow.d" :marker-end="`url(#result-loop-${index})`" />
        </svg>
      </div>
    </div>
    <div class="actions">
      <button class="primary" type="button" @click="emit('again')">Play again</button>
      <button class="secondary" type="button" @click="copy">{{ copied ? 'Copied' : 'Copy result' }}</button>
    </div>
    <textarea v-if="fallback" readonly :value="shareText" aria-label="Result text"></textarea>
  </section>
</template>
