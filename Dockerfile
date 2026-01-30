FROM node:20-alpine

WORKDIR /app

# Copy package files
COPY package.json ./

# No dependencies to install (using built-in modules only)

# Create necessary directories
RUN mkdir -p /data /app/public

# Copy application files
COPY server.js ./
COPY index.html ./public/

# Expose port
EXPOSE 3000

# Run the server
CMD ["node", "server.js"]