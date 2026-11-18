import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY
const secretInBrowser = typeof key === 'string' && key.startsWith('sb_secret_')
const supabase = url && key && !secretInBrowser ? createClient(url, key) : null

function clientReady() {
  if (secretInBrowser) return Promise.reject(new Error('secret'))
  if (!supabase) return Promise.reject(new Error('config'))
  return null
}

export function getGameEvents(level = 1) {
  const blocked = clientReady()
  if (blocked) return blocked
  const picked = [1, 2, 3].includes(Number(level)) ? Number(level) : 1
  return supabase.rpc('get_game_events', { p_n: 50, p_level: picked }).then(({ data, error }) => {
    if (error) throw error
    return data
  })
}

export function checkPlacement(orderedIds, eventId, insertIndex) {
  const blocked = clientReady()
  if (blocked) return blocked
  return supabase.rpc('check_placement', {
    p_ordered: orderedIds,
    p_event_id: eventId,
    p_insert_index: insertIndex,
  }).then(({ data, error }) => {
    if (error) throw error
    return data
  })
}

export function submitGame(playerId, demo, placements) {
  const blocked = clientReady()
  if (blocked) return blocked
  return supabase.rpc('submit_game', {
    p_player_id: playerId,
    p_demo: demo,
    p_placements: placements,
  }).then(({ data, error }) => {
    if (error) throw error
    return data
  })
}
