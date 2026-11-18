<script setup>
import { nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'

const props = defineProps({
  placed: { type: Array, required: true },
  current: { type: Object, default: null },
  busy: { type: Boolean, default: false },
  freshId: { type: [Number, String], default: null },
  verdict: { type: Object, default: null },
  skipsLeft: { type: Number, default: 0 },
  lives: { type: Number, default: 3 },
  levelName: { type: String, default: '' },
})

const emit = defineEmits(['place', 'skip'])

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

const titleEl = ref(null)
const flow = ref(null)
const arrows = ref([])
const dragging = ref(false)
const overIndex = ref(null)
const ghost = ref({ x: 0, y: 0 })

let observer = null
let frame = 0

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

function slotLabel(index) {
  const left = props.placed[index - 1]
  const right = props.placed[index]
  if (left && right) return `Drop between ${left.title} and ${right.title}`
  if (right) return `Drop before ${right.title}`
  if (left) return `Drop after ${left.title}`
  return 'Drop event'
}

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

function slotIndexAt(x, y) {
  const slots = flow.value ? [...flow.value.querySelectorAll('[data-slot]')] : []
  let best = null
  let bestDist = 42
  for (const slot of slots) {
    const rect = slot.getBoundingClientRect()
    const cx = Math.max(rect.left, Math.min(x, rect.right))
    const cy = Math.max(rect.top, Math.min(y, rect.bottom))
    const dist = Math.hypot(x - cx, y - cy)
    if (dist < bestDist) {
      bestDist = dist
      best = Number(slot.dataset.slot)
    }
  }
  return best
}

function startDrag(event) {
  if (!props.current || props.busy) return
  if (event.button != null && event.button !== 0) return
  dragging.value = true
  ghost.value = { x: event.clientX, y: event.clientY }
  overIndex.value = slotIndexAt(event.clientX, event.clientY)
  event.currentTarget.setPointerCapture(event.pointerId)
}

function moveDrag(event) {
  if (!dragging.value) return
  ghost.value = { x: event.clientX, y: event.clientY }
  overIndex.value = slotIndexAt(event.clientX, event.clientY)
}

function endDrag(event) {
  if (!dragging.value) return
  const index = slotIndexAt(event.clientX, event.clientY)
  dragging.value = false
  overIndex.value = null
  if (index != null) emit('place', index)
}

function cancelDrag() {
  dragging.value = false
  overIndex.value = null
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

watch(() => [props.placed.length, props.current && props.current.id, props.busy], async () => {
  await nextTick()
  layoutArrows()
})

watch(() => props.current && props.current.id, async (id) => {
  if (!id) return
  await nextTick()
  titleEl.value?.focus({ preventScroll: true })
}, { immediate: true })
</script>

<template>
  <section class="play">
    <div
      v-if="current"
      class="deal"
      :class="{ 'is-dragging': dragging }"
      aria-live="polite"
      @pointerdown="startDrag"
      @pointermove="moveDrag"
      @pointerup="endDrag"
      @pointercancel="cancelDrag"
    >
      <div class="deal-top">
        <p class="progress">{{ levelName }}</p>
        <p class="lives" :aria-label="lives === 1 ? '1 life left' : lives + ' lives left'">
          <span
            v-for="n in 3"
            :key="n"
            class="heart"
            :class="{ lost: n > lives }"
            aria-hidden="true"
          >♥</span>
        </p>
      </div>
      <p class="tag">{{ label(current.category) }}</p>
      <h2 ref="titleEl" tabindex="-1">{{ current.title }}</h2>
      <p class="desc">{{ current.description }}</p>
      <p v-if="busy" class="hint">One second…</p>
      <p v-else class="hint">
        Drag this card onto a +.
      </p>
    </div>
    <button
      v-if="current && skipsLeft > 0"
      class="secondary skip"
      type="button"
      :disabled="busy"
      @click="emit('skip')"
    >I don't know this event · {{ skipsLeft }} left</button>
    <p v-if="!current && busy" class="hint" aria-live="polite">Saving your timeline…</p>
    <p v-if="verdict" class="verdict" role="status">
      {{ verdict.correct ? 'Right.' : 'Wrong. It belongs here.' }}
    </p>

    <div
      v-if="dragging && current"
      class="ghost"
      :style="{ left: ghost.x + 'px', top: ghost.y + 'px' }"
    >
      <p class="tag">{{ label(current.category) }}</p>
      <strong>{{ current.title }}</strong>
    </div>

    <div class="bleed">
      <div
        ref="flow"
        class="flow"
        aria-label="Timeline. Earlier events come first. A long line continues on the next row."
      >
        <p class="end">← earlier</p>
        <template v-for="(card, i) in placed" :key="card.id">
          <button
            v-if="current"
            type="button"
            class="slot"
            :class="{ 'is-over': overIndex === i }"
            :data-slot="i"
            :aria-label="slotLabel(i)"
            :disabled="busy"
            @click="emit('place', i)"
          ><span aria-hidden="true">+</span></button>
          <article
            :id="'placed-' + card.id"
            class="mini"
            :class="{
              fresh: String(card.id) === String(freshId),
              'was-wrong': verdict && !verdict.correct && String(card.id) === String(verdict.id),
            }"
          >
            <p class="tag">{{ label(card.category) }}</p>
            <h3>{{ card.title }}</h3>
            <p v-if="card.date_text" class="when">{{ formatWhen(card.date_text, card.precision) }}</p>
            <p
              v-if="verdict && String(card.id) === String(verdict.id)"
              class="mark"
            >{{ verdict.correct ? 'Right' : 'Wrong' }}</p>
          </article>
        </template>
        <button
          v-if="current"
          type="button"
          class="slot"
          :class="{ 'is-over': overIndex === placed.length }"
          :data-slot="placed.length"
          :aria-label="slotLabel(placed.length)"
          :disabled="busy"
          @click="emit('place', placed.length)"
        ><span aria-hidden="true">+</span></button>
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
            <marker :id="'loop-' + index" markerWidth="8" markerHeight="8" refX="6" refY="4" orient="auto">
              <path d="M0 0 L8 4 L0 8 Z" fill="currentColor" />
            </marker>
          </defs>
          <path :d="arrow.d" :marker-end="`url(#loop-${index})`" />
        </svg>
      </div>
    </div>
  </section>
</template>
