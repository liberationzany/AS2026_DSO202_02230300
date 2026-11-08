# dso202-backend:1.1 - Assignment 1's backend image plus one fix in src/db.js
# (a pool 'error' listener, so a database restart no longer kills Node).
#
# Built FROM the existing 1.0 image rather than from node:22-alpine, so only
# the changed file is replaced: dependencies, user and CMD are inherited
# unchanged from 1.0, and no base image has to be downloaded.
#   docker build -t dso202-backend:1.1 assignment2/app-patch/backend
#   kind load docker-image dso202-backend:1.1 --name dso202
FROM dso202-backend:1.0
COPY --chown=app:app src/db.js /app/src/db.js
