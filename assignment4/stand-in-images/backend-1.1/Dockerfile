# Stand-in for sarojsanyasi/dso202-backend:1.1 (which does not exist on
# Docker Hub). Built FROM the local 1.0 image: dependencies, user (app) and
# CMD are unchanged; only the configuration loader is added.
#   docker build -t local/dso202-backend:1.1 backend-1.1
FROM local/dso202-backend:1.0
COPY --chown=app:app src/config.js /app/src/config.js
COPY --chown=app:app src/server.js /app/src/server.js
