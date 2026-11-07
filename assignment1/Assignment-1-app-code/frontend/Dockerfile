FROM nginx:1.31.3-alpine

# No 'apk add gettext' here: nginx:1.31-alpine's own base layer already
# installs gettext-envsubst (confirmed with 'which envsubst' against the
# unmodified base image), so installing the full gettext package again
# would just duplicate ~17MB that's already present.

COPY nginx.conf /etc/nginx/nginx.conf
COPY public /usr/share/nginx/html
COPY docker-entrypoint.sh /docker-entrypoint.sh

RUN chmod +x /docker-entrypoint.sh \
    && chown -R nginx:nginx /usr/share/nginx/html /var/cache/nginx /etc/nginx

USER nginx
EXPOSE 8080

ENTRYPOINT ["/docker-entrypoint.sh"]
