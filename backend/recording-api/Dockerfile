FROM node:20-alpine

# Install build dependencies for better-sqlite3
RUN apk add --no-cache python3 make g++

WORKDIR /app

# Copy package files
COPY package*.json ./

# Install dependencies
RUN npm install --omit=dev

# Copy application code
COPY index.js ./

# Create data directory for SQLite
RUN mkdir -p /data

# Create non-root user and set permissions
RUN addgroup -g 1001 -S nodejs && \
    adduser -S nodejs -u 1001 && \
    chown -R nodejs:nodejs /data /app

USER nodejs

EXPOSE 3001

ENV DB_PATH=/data/recordings.db
ENV PORT=3001

CMD ["node", "index.js"]
