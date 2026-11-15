<script setup>
import { nextTick, ref, watch } from 'vue'

const props = defineProps({
  placed: { type: Array, required: true },
  current: { type: Object, default: null },
  step: { type: Number, required: true },
  total: { type: Number, required: true },
  busy: { type: Boolean, default: false },
  freshId: { type: [Number, String], default: null },
})

const emit = defineEmits(['place'])

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

function label(category) {
  return labels[category] || category
}

function slotLabel(index) {
  const left = props.placed[index - 1]
  const right = props.placed[index]
  if (left && right) return `Place between ${left.title} and ${right.title}`
  if (right) return `Place before ${right.title}`
  if (left) return `Place after ${left.title}`
  return 'Place event'
}

const titleEl = ref(null)

watch(() => props.freshId, async (id) => {
  if (id == null) return
  await nextTick()
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches
  document.getElementById(`placed-${id}`)?.scrollIntoView({
    inline: 'center',
    block: 'nearest',
    behavior: reduced ? 'auto' : 'smooth',
  })
})

watch(() => props.current && props.current.id, async (id) => {
  if (!id) return
  await nextTick()
  titleEl.value?.focus({ preventScroll: true })
}, { immediate: true })
</script>

<template>
  <section class="play">
    <div v-if="current" class="deal" aria-live="polite">
      <p class="progress">{{ step }} / {{ total }}</p>
      <p class="tag">{{ label(current.category) }}</p>
      <h2 ref="titleEl" tabindex="-1">{{ current.title }}</h2>
      <p class="desc">{{ current.description }}</p>
      <p v-if="placed.length === 1" class="hint">
        The first event is your anchor. Tap a + to place this one earlier or later.
      </p>
    </div>
    <p v-else-if="busy" class="hint" aria-live="polite">Checking the real dates…</p>

    <div class="bleed">
      <div class="scroller" tabindex="0" aria-label="Timeline, earlier on the left, later on the right">
        <div class="row">
          <p class="end">← earlier</p>
          <template v-for="(card, i) in placed" :key="card.id">
            <button
              v-if="current"
              type="button"
              class="slot"
              :aria-label="slotLabel(i)"
              :disabled="busy"
              @click="emit('place', i)"
            ><span aria-hidden="true">+</span></button>
            <article
              :id="'placed-' + card.id"
              class="mini"
              :class="{ fresh: String(card.id) === String(freshId) }"
            >
              <p class="tag">{{ label(card.category) }}</p>
              <h3>{{ card.title }}</h3>
            </article>
          </template>
          <button
            v-if="current"
            type="button"
            class="slot"
            :aria-label="slotLabel(placed.length)"
            :disabled="busy"
            @click="emit('place', placed.length)"
          ><span aria-hidden="true">+</span></button>
          <p class="end">later →</p>
        </div>
      </div>
    </div>
  </section>
</template>
