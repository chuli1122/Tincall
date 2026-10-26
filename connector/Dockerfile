FROM node:24-bookworm-slim

WORKDIR /app
COPY --chown=node:node connector/server.mjs connector/store.mjs connector/sqlite-store.mjs ./connector/
COPY --chown=node:node supabase/functions/_shared/tincall/*.mjs ./supabase/functions/_shared/tincall/
COPY --chown=node:node supabase/functions/_shared/tincall/server-version.json ./supabase/functions/_shared/tincall/
RUN mkdir -p /app/connector/data && chown node:node /app/connector/data
USER node
ENV HOST=0.0.0.0 PORT=8787 TINCALL_STORAGE=sqlite TINCALL_SQLITE_PATH=/app/connector/data/tincall.sqlite
EXPOSE 8787
CMD ["node", "connector/server.mjs"]
