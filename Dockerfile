FROM openresty/openresty:alpine

# nginx's default mime.types maps .js but not .mjs; Framer ships ES modules
# as .mjs, which browsers refuse to execute unless served as JavaScript.
RUN sed -i -E 's#(application/javascript[[:space:]]+)js;#\1js mjs;#' /usr/local/openresty/nginx/conf/mime.types

COPY nginx.conf /etc/nginx/conf.d/default.conf

# Bake the mirrored site into the image (self-contained, no runtime volume).
COPY site/ /usr/share/nginx/html/

EXPOSE 80
