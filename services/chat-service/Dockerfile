#STAGE 1 (BUILDER)
FROM node:22-alpine AS builder

WORKDIR /app


COPY package.json package-lock.json tsconfig.base.json      ./
COPY packages/common/package.json                           ./packages/common/
COPY services/chat-service/package.json                     ./services/chat-service/

#These are the dependencies that are needed to build the project, but not needed to run it.
COPY services/user-service/package.json     ./services/user-service/
COPY services/file-service/package.json     ./services/file-service/
COPY apps/web/package.json                  ./apps/web/

#clean install the dependencies
RUN npm ci

#COPY the code (common and service specific) to the root of the user-service /app directory
COPY packages/common/           ./packages/common/
COPY services/chat-service/     ./services/chat-service/

RUN npm run build -w @nexusdrive/common
RUN npm run build -w @nexusdrive/chat-service

#STAGE 2 (RUNNER)
FROM node:22-alpine AS runner
ENV NODE_ENV=production
WORKDIR /app

#install only the production dependencies, and not the dev dependencies
COPY package.json package-lock.json         ./
COPY packages/common/package.json           ./packages/common/
COPY services/user-service/package.json     ./services/user-service/
COPY services/file-service/package.json     ./services/file-service/
COPY services/chat-service/package.json     ./services/chat-service/
COPY apps/web/package.json                  ./apps/web/

RUN npm ci --omit=dev 
RUN npm cache clean --force

#copy required files from the builder stage to the runner stage
COPY --from=builder /app/packages/common/dist           packages/common/dist
COPY --from=builder /app/services/chat-service/dist     services/chat-service/dist

#runtime settings
USER node
EXPOSE 3002


#RUN node
WORKDIR /app/services/chat-service
CMD ["node", "dist/main.js"]