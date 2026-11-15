# Timeline

A small Vue game: put ten events since 2020 back in order. Dates stay in Supabase until the end.

1. In the Supabase SQL editor, run `db/schema.sql`, then `db/api.sql`.
2. Copy `.env.example` to `.env` and fill in the project URL, publishable key, and contact email.
3. Run `npm install`, then `npm run dev`.

`npm run build` writes a static `dist/` folder for Vercel, Netlify, or Cloudflare Pages.
The publishable key (`sb_publishable_...`) is public on purpose. Never put a secret key in the app.
# timeline
