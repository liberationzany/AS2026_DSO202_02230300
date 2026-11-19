# Stand-in for sarojsanyasi/dso202-frontend:1.1 (which does not exist on
# Docker Hub). Release note: "The page header displays the release number.
# No other change." Built FROM the local 1.0 image with one file replaced.
#   docker build -t local/dso202-frontend:1.1 frontend-1.1
FROM local/dso202-frontend:1.0
COPY --chown=nginx:nginx index.html /usr/share/nginx/html/index.html
