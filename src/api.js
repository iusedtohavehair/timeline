import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const key = import.meta.env.VITE_SUPABASE_ANON_KEY
const supabase = url && key ? createClient(url, key) : null

export function getGameEvents() {
  if (!supabase) return Promise.reject(new Error('config'))
  return supabase.rpc('get_game_events', { p_n: 10 }).then(({ data, error }) => {
    if (error) throw error
    return data
  })
}

export function submitGame(playerId, demo, placements) {
  if (!supabase) return Promise.reject(new Error('config'))
  return supabase.rpc('submit_game', {
    p_player_id: playerId,
    p_demo: demo,
    p_placements: placements,
  }).then(({ data, error }) => {
    if (error) throw error
    return data
  })
}
