# =============================================================================
# Dockerfile — Todo App
#
# PDF Requirements satisfied:
#   REQ-02: candidate rebuilt this container image (not pulled from a registry)
#   REQ-15: wizexercise.txt with candidate name is baked into the image
#   REQ-16: file is created via ARG+RUN — validate.sh confirms with kubectl exec
#
# CANDIDATE_NAME is passed as a build arg by deploy.sh:
#   az acr build --build-arg CANDIDATE_NAME="WeberRess" ...
# =============================================================================
FROM node:18-alpine

WORKDIR /app

# Install dependencies first (cached layer — only rebuilds when package.json changes)
COPY package.json .
RUN npm install --production

# Copy application code
COPY index.js .

# REQ-15: bake wizexercise.txt into the image with the candidate's name
# REQ-16: validate.sh runs "kubectl exec <pod> -- cat /app/wizexercise.txt"
ARG CANDIDATE_NAME=unknown
RUN echo "Wiz Technical Exercise v5\nCandidate: ${CANDIDATE_NAME}" > /app/wizexercise.txt

# Install curl for health checks inside the container (used by validate.sh)
RUN apk add --no-cache curl

EXPOSE 3000
CMD ["node", "index.js"]
