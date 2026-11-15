<script setup>
import { ref } from 'vue'
import { getGameEvents } from './api.js'

const status = ref('')
const titles = ref([])
const busy = ref(false)

async function check() {
  busy.value = true
  status.value = ''
  titles.value = []
  try {
    const data = await getGameEvents()
    if (!Array.isArray(data)) throw new Error('The database did not return a list.')
    titles.value = data.map((event) => event.title)
    status.value = data.length >= 10
      ? `Got ${data.length} events. No dates in the payload.`
      : `Only ${data.length} events came back. Need 10.`
  } catch (err) {
    status.value = err?.message === 'config'
      ? 'Add VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY to .env, then refresh.'
      : (err?.message || 'The database could not be reached.')
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="wrap">
    <header class="top">
      <h1>Timeline</h1>
    </header>
    <section class="panel">
      <p class="pitch">Since 2020, a lot of years feel like the same year.</p>
      <button class="primary" type="button" :disabled="busy" @click="check">
        {{ busy ? 'Asking the database…' : 'Check events' }}
      </button>
      <p v-if="status" class="hint">{{ status }}</p>
      <ul v-if="titles.length" class="steps">
        <li v-for="title in titles" :key="title">{{ title }}</li>
      </ul>
    </section>
  </div>
</template>
