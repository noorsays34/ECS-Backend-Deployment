FROM nginx:alpine

# Remove default nginx page
RUN rm -rf /usr/share/nginx/html/*

# Copy our HTML
COPY index.html /usr/share/nginx/html/

# Expose port
EXPOSE 80